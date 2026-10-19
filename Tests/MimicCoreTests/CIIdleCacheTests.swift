//
//  CIIdleCacheTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 12.10.2026.
import Foundation
import Testing
@testable import MimicCore

@MainActor private final class IdleWeakState {
    weak var value: CIState?
    init(_ value: CIState) { self.value = value }
}

@MainActor private final class IdleTracking: CITrackingStore {
    var saved = [CIUser(id: 2, username: "colleague", name: "Colleague")]
    func users(connection _: GitLabConnection, owner _: CIUser) -> [CIUser] { self.saved }
    func save(_ users: [CIUser], connection _: GitLabConnection, owner _: CIUser) { self.saved = users }
}

private actor IdleClient: GitLabService {
    var pipelineID = 3
    private var status = "success"
    private(set) var accountRequests = 0
    private var holdAccount = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var suspended = false
    func hold() { self.holdAccount = true }
    func release() { self.continuation?.resume(); self.continuation = nil }
    func replacePipeline() { self.pipelineID = 4 }
    func setStatus(_ status: String) { self.status = status }
    func project(baseURL _: URL, path _: String, token _: String) async throws -> CIProject { throw CIError.notFound }
    func currentUser(connection _: GitLabConnection, token _: String) async throws -> CIUser {
        self.accountRequests += 1
        if self.holdAccount {
            self.holdAccount = false; self.suspended = true
            await withCheckedContinuation { self.continuation = $0 }
        }
        return CIUser(id: 1, username: "me", name: "Me")
    }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] { [] }
    func pipelines(connection _: GitLabConnection, branch _: String, token _: String) async throws -> [CIPipeline] { [] }
    func pipelinePage(connection: GitLabConnection, username _: String?, page _: Int, perPage _: Int, token _: String) async throws -> CIPipelinePage {
        CIPipelinePage(pipelines: [self.value(connection)])
    }
    func pipeline(connection: GitLabConnection, id _: Int, token _: String) async throws -> CIPipeline { self.value(connection) }
    func details(connection _: GitLabConnection, pipelineID _: Int, token _: String) async throws -> CIPipelineDetails { CIPipelineDetails(jobs: [], bridges: []) }
    private func value(_ connection: GitLabConnection) -> CIPipeline {
        CIPipeline(id: self.pipelineID, status: self.status, sha: "sha-\(self.pipelineID)", ref: "main",
            webURL: connection.baseURL, createdAt: Date(timeIntervalSince1970: 1_790_000_000), projectID: connection.projectID)
    }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CIIdleCacheTests {
    private func context(_ project: Int = 1, checkout: String = "/fixture") -> CIContext {
        let connection = GitLabConnection(baseURL: URL(string: "https://ci.example.invalid")!, projectID: project, projectPath: "fixture/\(project)")
        return CIContext(project: ProjectContext(path: checkout), connection: connection)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test(arguments: [1, 2, 3]) func idleReleasesOneHundredContextsWithoutReleasingOwner(repeat _: Int) async throws {
        var now = Date(), states: [IdleWeakState] = []
        let monitor = CIActivityMonitor(now: { now }) { _ in
            let state = CIState { _ in throw CIError.notFound }; states.append(IdleWeakState(state)); return state
        }
        defer { monitor.stop() }
        for id in 1...100 { _ = monitor.heartbeat(threadID: "switching", context: self.context(id)) }
        _ = monitor.heartbeat(threadID: "switching", context: nil)
        #expect(monitor.cacheLifetime.entries == 100 && monitor.cacheLifetime.timerRunning)
        now += 59; monitor.reconcile()
        #expect(monitor.cacheLifetime.entries == 100)
        now += 2; monitor.reconcile()
        try await self.wait { states.allSatisfy { $0.value == nil } }
        #expect(monitor.cacheLifetime.entries == 0 && !monitor.cacheLifetime.timerRunning)
    }

    @Test func renewedAndSharedLeasesDesktopAndNativeInspectionProtectTheirStates() async throws {
        var now = Date()
        let client = IdleClient()
        let monitor = CIActivityMonitor(now: { now }) { _ in CIState(client: client, interval: .seconds(600), trackingStore: IdleTracking()) { _ in "fixture" } }
        defer { monitor.stop() }
        let shared = self.context(), desktop = self.context(2), inspection = self.context(3)
        _ = monitor.heartbeat(threadID: "a", context: shared); _ = monitor.heartbeat(threadID: "b", context: shared)
        monitor.setDesktop(desktop)
        _ = monitor.heartbeat(threadID: "inspection", context: inspection)
        try await self.wait { monitor.heartbeat(threadID: "inspection", context: inspection) != nil }
        let summary = try #require(monitor.heartbeat(threadID: "inspection", context: inspection))
        let visible = try #require(monitor.state(for: summary)); visible.setVisible(true)
        _ = monitor.heartbeat(threadID: "inspection", context: nil)
        _ = monitor.heartbeat(threadID: "a", context: nil)
        now += 20; _ = monitor.heartbeat(threadID: "b", context: shared)
        now += 20; monitor.reconcile()
        #expect(monitor.cacheLifetime.entries == 3)
        now += 11; monitor.reconcile() // Last shared lease has expired; start its idle grace.
        now += 61; monitor.reconcile()
        #expect(monitor.cacheLifetime.entries == 2 && monitor.desktopState != nil)
        #expect(monitor.state(for: summary) === visible && visible.visible)
        visible.setVisible(false); monitor.setDesktop(nil); monitor.reconcile()
        now += 61; monitor.reconcile()
        #expect(monitor.cacheLifetime.entries == 0 && !monitor.cacheLifetime.timerRunning)
    }

    @Test func reactivationReusesGraceThenReloadsEvictedStateAndDurableTracking() async throws {
        var now = Date(), states: [IdleWeakState] = []
        let client = IdleClient(), tracking = IdleTracking(), context = self.context()
        let monitor = CIActivityMonitor(now: { now }) { _ in
            let state = CIState(client: client, interval: .seconds(600), trackingStore: tracking) { _ in "fixture" }
            states.append(IdleWeakState(state)); return state
        }
        defer { monitor.stop() }
        _ = monitor.heartbeat(threadID: "chat", context: context)
        try await self.wait { states.first?.value?.compactSummary?.pipelineID == 3 }
        _ = monitor.heartbeat(threadID: "chat", context: nil)
        now += 59; _ = monitor.heartbeat(threadID: "chat", context: context)
        #expect(states.count == 1 && monitor.cacheLifetime.entries == 1)
        _ = monitor.heartbeat(threadID: "chat", context: nil)
        now += 61; monitor.reconcile()
        try await self.wait { states.first?.value == nil }
        await client.replacePipeline()
        _ = monitor.heartbeat(threadID: "chat", context: context)
        try await self.wait { states.last?.value?.compactSummary?.pipelineID == 4 }
        #expect(states.count == 2 && monitor.cacheLifetime.timerRunning)
        let state = try #require(states.last?.value)
        #expect(state.trackedUsers.map(\.user) == tracking.saved && state.user?.id == 1)
        #expect(monitor.heartbeat(threadID: "chat", context: context)?.pipelineID == 4)
        #expect(await client.accountRequests == 2)
    }

    @Test func activeAndFailedOverlayOutliveLeasesUntilDismissal() async throws {
        var now = Date()
        let client = IdleClient(); await client.setStatus("running")
        let monitor = CIActivityMonitor(now: { now }) { _ in CIState(client: client, interval: .seconds(600), trackingStore: IdleTracking()) { _ in "fixture" } }
        defer { monitor.stop() }
        _ = monitor.heartbeat(threadID: "chat", context: self.context())
        try await self.wait { monitor.overlay?.status == "running" }
        let summary = try #require(monitor.overlay), state = try #require(monitor.state(for: summary))
        now += 31; monitor.reconcile(); now += 121; monitor.reconcile()
        #expect(monitor.cacheLifetime.entries == 1 && state.monitoring)
        await client.setStatus("failed"); state.refresh()
        try await self.wait { monitor.overlay?.status == "failed" }
        now += 121; monitor.reconcile()
        #expect(monitor.cacheLifetime.entries == 1 && !state.monitoring && monitor.overlay?.status == "failed")
        monitor.hideCI(); now += 61; monitor.reconcile()
        #expect(monitor.cacheLifetime.entries == 0 && monitor.overlay == nil && !monitor.cacheLifetime.timerRunning)
    }

    @Test func stopDropsOwnershipAndRejectsLateRefreshAndNewInterests() async throws {
        let client = IdleClient(); await client.hold()
        var states: [IdleWeakState] = []
        let monitor = CIActivityMonitor { _ in
            let state = CIState(client: client, trackingStore: IdleTracking()) { _ in "fixture" }
            states.append(IdleWeakState(state)); return state
        }
        monitor.setDesktop(self.context())
        for _ in 0..<400 { if await client.suspended { break }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(await client.suspended)
        monitor.stop()
        #expect(monitor.desktopState == nil && monitor.overlay == nil)
        #expect(monitor.cacheLifetime.entries == 0 && !monitor.cacheLifetime.timerRunning)
        monitor.setDesktop(self.context(2)); _ = monitor.heartbeat(threadID: "new", context: self.context(3))
        #expect(states.count == 1)
        await client.release()
        try await self.wait { states.allSatisfy { $0.value == nil } }
        #expect(monitor.desktopState == nil && monitor.overlay == nil)
    }
}
