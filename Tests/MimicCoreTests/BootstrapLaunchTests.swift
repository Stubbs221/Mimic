//
//  BootstrapLaunchTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation
import Testing
@testable import MimicCore

@MainActor
private final class FakeXcodeApplications: XcodeApplicationService {
    enum Behavior { case wait, refuse, timeout }
    var running: Set<Int32> = []
    var hasRunningXcode: Bool { !self.running.isEmpty }
    var behavior = Behavior.wait
    var requests: [Set<Int32>] = []
    var timeout: Duration?
    var activationCount = 0
    private var pending: CheckedContinuation<Bool, Never>?
    func closeXcode(timeout: Duration) async -> Bool {
        self.requests.append(self.running); self.timeout = timeout
        switch self.behavior {
        case .refuse: return false
        case .timeout:
            try? await Task.sleep(for: timeout); return false
        case .wait:
            // Intentionally permits late completion after cancellation to exercise generation guards.
            return await withCheckedContinuation { self.pending = $0 }
        }
    }

    func exit(_ id: Int32) { self.running.remove(id); if self.running.isEmpty { self.finish(true) } }
    func finish(_ closed: Bool) { let saved = self.pending; self.pending = nil; saved?.resume(returning: closed) }
    func activateXcode() { self.activationCount += 1 }
}

@MainActor
private final class PreparationProbe {
    var inspections = 0
    var launches = 0
    var errors: [String] = []
    var onInspect: ((Int) -> String?)?
    var suspendInspection = false
    var pending: CheckedContinuation<Void, Never>?
    func inspect(_ record: TaskRecord) async -> CommandPreparation {
        self.inspections += 1
        if self.suspendInspection { await withCheckedContinuation { self.pending = $0 } }
        if let error = onInspect?(inspections) { return .failed(error) }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Mimic11/profile.json")
        let profile = try! JSONDecoder().decode(MimicProfile.self, from: Data(contentsOf: path))
        let snapshot = ProfileSnapshot(profile: profile, revision: "fixture", directory: "/private/tmp/fixture")
        let role = ProfileToolRole.allCases.first { $0.localAction == record.action }!
        let execution = try! snapshot.execution(role: role, values: role == .bootstrap ? record.options.profileValues : [:])
        return .ready(try! execution.commands(project: record.project)[0])
    }

    func start(_ gate: LaunchPreparation, record: TaskRecord = TaskRecord(action: .bootstrap, project: ProjectContext(path: "/private/tmp/fixture"))) {
        gate.start(record: record, inspect: { [self] in await self.inspect($0) }, launch: { [self] _ in self.launches += 1 }, failure: { [self] in self.errors.append($0) })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct BootstrapLaunchTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }

    @Test
    func absentXcodeLaunchesAfterFreshPreflight() async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe()
        let gate = LaunchPreparation(applications: apps)
        probe.start(gate)
        try await self.waitUntil { probe.launches == 1 }
        #expect(apps.requests.isEmpty); #expect(probe.inspections == 2); #expect(gate.state == .idle)
    }

    @Test
    func everyXcodeInstanceMustExitBeforeLaunch() async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe(); apps.running = [1, 2]
        let gate = LaunchPreparation(applications: apps)
        probe.start(gate)
        try await self.waitUntil { apps.requests.count == 1 }
        let id = try #require(gate.state.taskID)
        #expect(gate.state == .closingXcode(id)); #expect(apps.requests == [[1, 2]])
        apps.exit(1)
        #expect(probe.launches == 0); #expect(probe.inspections == 1)
        apps.exit(2)
        try await self.waitUntil { probe.launches == 1 }
        #expect(apps.timeout == .seconds(30)); #expect(probe.inspections == 2)
    }

    @Test(arguments: [false, true])
    func refusalOrTimeoutBlocksWithoutStarting(timeout: Bool) async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe(); apps.running = [1]; apps.behavior = timeout ? .timeout : .refuse
        let gate = LaunchPreparation(applications: apps, timeout: .milliseconds(10))
        probe.start(gate)
        let id = try #require(gate.state.taskID)
        try await self.waitUntil { gate.state == .blockedByXcode(id) }
        #expect(probe.launches == 0); #expect(probe.errors.isEmpty); #expect(gate.state.holdsQueue)
    }

    @Test
    func acceptedQuitRequestIsNotActualExit() async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe(); apps.running = [1]
        let gate = LaunchPreparation(applications: apps)
        probe.start(gate); try await self.waitUntil { apps.requests.count == 1 }
        apps.finish(true) // Another instance is still alive despite a successful request/result.
        let id = try #require(gate.state.taskID)
        try await self.waitUntil { gate.state == .blockedByXcode(id) }
        #expect(probe.launches == 0)
    }

    @Test
    func manualExitNeedsExplicitRetryAndRepeatedClicksDoNotOverlap() async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe(); apps.running = [1]; apps.behavior = .refuse
        let gate = LaunchPreparation(applications: apps)
        let record = TaskRecord(action: .bootstrap, project: ProjectContext(path: "/private/tmp/fixture"))
        probe.start(gate, record: record)
        try await self.waitUntil { gate.state == .blockedByXcode(record.id) }
        let accepted = gate.start(record: record, inspect: { _ in .failed("unexpected") }, launch: { _ in Issue.record("Unexpected launch") }, failure: { _ in })
        #expect(!accepted)
        gate.activateXcode(); #expect(apps.activationCount == 1)
        apps.running = []
        await Task.yield(); #expect(probe.launches == 0); #expect(gate.state == .blockedByXcode(record.id))
        gate.retry(id: record.id); gate.retry(id: record.id)
        try await self.waitUntil { probe.launches == 1 }
        #expect(probe.inspections == 3); #expect(apps.requests.count == 1)
    }

    @Test
    func newInstanceDuringFreshPreflightBlocksLaunch() async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe(); apps.running = [1]
        probe.onInspect = { count in if count == 2 { apps.running = [99] }; return nil }
        let gate = LaunchPreparation(applications: apps)
        probe.start(gate); try await self.waitUntil { apps.requests.count == 1 }
        let id = try #require(gate.state.taskID)
        apps.exit(1)
        try await self.waitUntil { gate.state == .blockedByXcode(id) }
        #expect(probe.launches == 0); #expect(apps.running == [99])
    }

    @Test(arguments: [MimicAction.fullCleanup, .derivedDataCleanup])
    func cleanupWaitsForXcodeAndRevalidatesBeforeLaunching(_ action: MimicAction) async throws {
        let apps = FakeXcodeApplications(); apps.running = [1]
        let gate = LaunchPreparation(applications: apps)
        let record = TaskRecord(action: action, project: ProjectContext(path: "/fixture"))
        let probe = PreparationProbe()
        probe.start(gate, record: record)
        try await self.waitUntil { apps.requests.count == 1 }
        #expect(probe.launches == 0)
        apps.exit(1)
        try await self.waitUntil { probe.launches == 1 }
        #expect(probe.inspections == 2)
    }

    @Test(arguments: ["project.invalid", "checkout.changed", "missing: ruby"])
    func invalidPreflightNeverRequestsQuit(_ reason: String) async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe(); apps.running = [1]
        probe.onInspect = { _ in reason }
        let gate = LaunchPreparation(applications: apps)
        probe.start(gate); try await self.waitUntil { !probe.errors.isEmpty }
        #expect(apps.requests.isEmpty); #expect(probe.errors == [reason]); #expect(probe.launches == 0)
    }

    @Test
    func checkoutChangedWhileClosingDoesNotLaunch() async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe(); apps.running = [1]
        probe.onInspect = { $0 == 2 ? "checkout.changed" : nil }
        let gate = LaunchPreparation(applications: apps)
        probe.start(gate); try await self.waitUntil { apps.requests.count == 1 }; apps.exit(1)
        try await self.waitUntil { !probe.errors.isEmpty }
        #expect(probe.errors == ["checkout.changed"]); #expect(probe.launches == 0)
    }

    @Test
    func cancellingPreflightIgnoresLateInspection() async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe(); apps.running = [1]; probe.suspendInspection = true
        let gate = LaunchPreparation(applications: apps)
        probe.start(gate); try await self.waitUntil { probe.pending != nil }
        let id = try #require(gate.state.taskID); gate.cancel(id: id)
        probe.pending?.resume(); probe.pending = nil
        await Task.yield(); await Task.yield()
        #expect(gate.state == .idle); #expect(apps.requests.isEmpty); #expect(probe.launches == 0)
    }

    @Test
    func cancellationAndExitIgnoreLateQuitAndPermitNextAction() async throws {
        let apps = FakeXcodeApplications(), probe = PreparationProbe(); apps.running = [1]
        let gate = LaunchPreparation(applications: apps)
        probe.start(gate); try await self.waitUntil { apps.requests.count == 1 }
        gate.cancelAll(); apps.exit(1)
        let next = TaskRecord(action: .format, project: ProjectContext(path: "/private/tmp/fixture"))
        probe.start(gate, record: next)
        try await self.waitUntil { probe.launches == 1 }
        #expect(probe.inspections == 2); #expect(apps.requests.count == 1)
    }

    @Test
    func blockedBootstrapHoldsGlobalQueueUntilCancellation() async throws {
        let apps = FakeXcodeApplications(); apps.running = [1]; apps.behavior = .refuse
        let gate = LaunchPreparation(applications: apps)
        var records = [TaskRecord(action: .bootstrap, project: ProjectContext(path: "/private/tmp/fixture")), TaskRecord(action: .format, project: ProjectContext(path: "/private/tmp/fixture"))]
        let probe = PreparationProbe()
        probe.start(gate, record: records[0]); try await self.waitUntil { gate.state == .blockedByXcode(records[0].id) }
        #expect(QueuePolicy.next(in: records)?.id == records[0].id)
        #expect(records[0].startedAt == nil); #expect(records[0].status == .queued)
        let accepted = gate.start(record: records[1], inspect: { _ in .failed("unexpected") }, launch: { _ in Issue.record("Queue escaped") }, failure: { _ in })
        #expect(!accepted)
        records[0].status = .cancelled; gate.cancel(id: records[0].id)
        let next = try #require(QueuePolicy.next(in: records)); probe.start(gate, record: next)
        try await self.waitUntil { probe.launches == 1 }
        #expect(apps.hasRunningXcode); #expect(apps.requests.count == 1)
    }
}
