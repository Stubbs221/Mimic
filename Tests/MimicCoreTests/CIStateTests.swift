//
//  CIStateTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation
import Testing
@testable import MimicCore

private func fixturePipeline(_ id: Int) -> CIPipeline {
    CIPipeline(id: id, status: "success", sha: "sha-\(id)", ref: "main", webURL: URL(string: "https://gitlab.example.invalid/pipelines/\(id)")!, createdAt: Date(), projectID: 272)
}

private actor MonitorFixture: GitLabService {
    private var values: [Result<[CIPipeline], CIError>]
    private(set) var calls = 0
    private(set) var detailCalls = 0
    private var shouldSuspend: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ values: [Result<[CIPipeline], CIError>] = [.success([fixturePipeline(1)])], suspendFirst: Bool = false) {
        self.values = values; self.shouldSuspend = suspendFirst
    }

    func currentUser(connection _: GitLabConnection, token _: String) async throws -> CIUser { CIUser(id: 7, username: "fixture", name: "Fixture") }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] { [] }
    func pipeline(connection _: GitLabConnection, id _: Int, token _: String) async throws -> CIPipeline { throw CIError.notFound }
    func pipelinePage(connection: GitLabConnection, username: String?, page _: Int, perPage _: Int, token: String) async throws -> CIPipelinePage {
        if username == nil { return CIPipelinePage(pipelines: []) }
        let values = try await self.pipelines(connection: connection, branch: "main", token: token)
        return CIPipelinePage(pipelines: values.map {
            CIPipeline(id: $0.id, status: $0.status, sha: $0.sha, ref: $0.ref, webURL: $0.webURL, createdAt: $0.createdAt, projectID: connection.projectID)
        })
    }

    func project(baseURL _: URL, path: String, token _: String) async throws -> CIProject { CIProject(id: 272, pathWithNamespace: path) }
    func pipelines(connection _: GitLabConnection, branch _: String, token _: String) async throws -> [CIPipeline] {
        self.calls += 1
        let value = self.values.count > 1 ? self.values.removeFirst() : self.values.first ?? .success([])
        if self.shouldSuspend {
            self.shouldSuspend = false
            await withCheckedContinuation { self.continuation = $0 }
        }
        return try value.get()
    }

    func details(connection _: GitLabConnection, pipelineID _: Int, token _: String) async throws -> CIPipelineDetails {
        self.detailCalls += 1
        return CIPipelineDetails(jobs: [], bridges: [])
    }

    func release() { self.continuation?.resume(); self.continuation = nil }
}

@MainActor
private final class MemoryCredentials: CICredentialStore {
    var values: [UUID: String] = [:]
    func token(for id: UUID, interaction: CICredentialInteraction = .silent) throws -> String { guard let value = values[id] else { throw CIError.credential }; return value }
    func save(_ token: String, for id: UUID) { self.values[id] = token }
    func remove(_ id: UUID) { self.values.removeValue(forKey: id) }
}

@MainActor
private final class MemoryConfiguration: CIConfigurationStore {
    var value = CIConfiguration()
    func load() -> CIConfiguration { self.value }
    func save(_ value: CIConfiguration) { self.value = value }
}

@MainActor
private func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0 ..< 200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CIError.server
}

@MainActor
struct CIStateTests {
    private let connection = GitLabConnection(baseURL: URL(string: "https://gitlab.example.invalid")!, projectID: 272, projectPath: "team/mobile")
    private func context(_ path: String = "/fixture", branch: String = "main") -> CIContext {
        CIContext(project: ProjectContext(path: path, branch: branch, commit: "local-sha"), connection: self.connection)
    }

    @Test
    func onlyVisiblePanelPollsAndCloseCancels() async throws {
        let client = MonitorFixture(), state = CIState(client: client, interval: .milliseconds(20)) { _ in "fixture-token" }
        state.select(self.context()); state.refresh()
        #expect(await client.calls == 0)
        state.setVisible(true)
        try await waitFor { !state.loading && !state.pipelines.isEmpty }
        for _ in 0 ..< 200 {
            if await client.calls >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await client.calls >= 2)
        state.setVisible(false)
        let count = await client.calls
        try await Task.sleep(for: .milliseconds(55))
        #expect(await client.calls == count)
    }

    @Test func hiddenSettingsPagePausesFeedWithoutResettingSelectionAndDepth() async throws {
        let client = MonitorFixture([.success((1...6).map(fixturePipeline))])
        let state = CIState(client: client) { _ in "fixture-token" }
        state.select(self.context()); state.setVisible(true)
        defer { state.setVisible(false) }
        try await waitFor { !state.loading && !state.pipelines.isEmpty }
        state.setFeedPresented(true); state.showMore()
        try await waitFor { !state.loading }
        state.loadDetails(1)
        #expect(state.selectedPipelineID == 1 && state.historyLimit == 6)
        state.setFeedPresented(false, preserveSelection: true)
        #expect(!state.feedPresented && state.selectedPipelineID == 1 && state.historyLimit == 6)
        state.setFeedPresented(true)
        #expect(state.selectedPipelineID == 1 && state.historyLimit == 6)
        state.setFeedPresented(false, preserveSelection: true)
        state.setFeedPresented(false)
        #expect(state.selectedPipelineID == nil && state.historyLimit == 3)
    }

    @Test
    func oldCheckoutAndBranchResponseCannotOverwriteNewContext() async throws {
        let client = MonitorFixture([.success([fixturePipeline(1)]), .success([fixturePipeline(2)])], suspendFirst: true)
        let state = CIState(client: client) { _ in "fixture-token" }
        state.select(self.context()); state.setVisible(true)
        for _ in 0 ..< 100 {
            if await client.calls == 1 { break }; await Task.yield()
        }
        #expect(await client.calls == 1)
        state.select(self.context("/other", branch: "feature/new"))
        try await waitFor { state.pipelines.first?.id == 2 }
        await client.release()
        try await Task.sleep(for: .milliseconds(10))
        #expect(state.pipelines.first?.id == 2)
        #expect(state.context?.branch == "feature/new")
        state.setVisible(false)
    }

    @Test
    func changedConnectionDropsOldResponse() async throws {
        let client = MonitorFixture([.success([fixturePipeline(1)]), .success([fixturePipeline(2)])], suspendFirst: true)
        let state = CIState(client: client) { _ in "fixture-token" }
        state.select(self.context()); state.setVisible(true)
        for _ in 0 ..< 100 {
            if await client.calls == 1 { break }; await Task.yield()
        }
        let other = GitLabConnection(baseURL: connection.baseURL, projectID: 300, projectPath: "other/project")
        state.select(CIContext(project: ProjectContext(path: "/fixture", branch: "main"), connection: other))
        try await waitFor { state.pipelines.first?.id == 2 }
        await client.release(); try await Task.sleep(for: .milliseconds(10))
        #expect(state.context?.connection.id == other.id)
        #expect(state.pipelines.first?.id == 2)
        state.setVisible(false)
    }

    @Test
    func errorsPreserveTimestampAndLastGoodResult() async throws {
        let state = CIState(client: MonitorFixture([.success([fixturePipeline(1)]), .failure(.network)])) { _ in "fixture-token" }
        state.select(self.context()); state.setVisible(true)
        try await waitFor { !state.loading }
        let date = state.loadedAt
        state.refresh(manual: true); try await waitFor { !state.loading }
        #expect(state.error == .network)
        #expect(state.loadedAt == date)
        #expect(state.pipelines.first?.id == 1)
        #expect(state.pipelines.first?.sha != state.context?.commit)
        state.setVisible(false)
    }

    @Test(arguments: [CIError.authentication, .forbidden, .credential])
    func credentialFailuresPauseUntilExplicitRetry(error: CIError) async throws {
        let client = MonitorFixture([.failure(error), .success([fixturePipeline(2)])])
        let state = CIState(client: client, interval: .milliseconds(20)) { _ in "fixture-token" }
        state.select(self.context()); state.setVisible(true); try await waitFor { !state.loading }
        #expect(state.pollingPaused)
        try await Task.sleep(for: .milliseconds(55)); #expect(await client.calls == 1)
        state.setVisible(false); state.setVisible(true)
        #expect(await client.calls == 1)
        state.refresh(manual: true); try await waitFor { state.pipelines.first?.id == 2 }
        #expect(!state.pollingPaused)
        state.setVisible(false)
    }

    @Test
    func rateLimitDefersAutomaticAndManualRequests() async throws {
        let client = MonitorFixture([.failure(.rateLimited(120))])
        let state = CIState(client: client, interval: .milliseconds(20)) { _ in "fixture-token" }
        state.select(self.context()); state.setVisible(true); try await waitFor { !state.loading }
        state.refresh(manual: true); try await Task.sleep(for: .milliseconds(55))
        #expect(await client.calls == 1)
        state.loadDetails(1); await Task.yield()
        #expect(await client.detailCalls == 0)
        state.setVisible(false)
    }

    @Test
    func replacedCredentialInvalidatesOldResponseWithoutChangingConnection() async throws {
        let client = MonitorFixture([.failure(.authentication), .success([fixturePipeline(2)])], suspendFirst: true)
        let state = CIState(client: client) { _ in "fixture-token" }
        state.select(self.context()); state.setVisible(true)
        for _ in 0 ..< 100 {
            if await client.calls == 1 { break }; await Task.yield()
        }
        #expect(await client.calls == 1)
        state.credentialsChanged()
        try await waitFor { state.pipelines.first?.id == 2 }
        await client.release(); try await Task.sleep(for: .milliseconds(10))
        #expect(!state.pollingPaused); #expect(state.error == nil)
        #expect(state.pipelines.first?.id == 2)
        state.setVisible(false)
    }

    @Test
    func disconnectDuringRequestClearsStateWithoutLateResult() async throws {
        let client = MonitorFixture(suspendFirst: true), state = CIState(client: client) { _ in "fixture-token" }
        state.select(self.context()); state.setVisible(true)
        for _ in 0 ..< 100 {
            if await client.calls == 1 { break }; await Task.yield()
        }
        state.select(nil); await client.release(); try await Task.sleep(for: .milliseconds(10))
        #expect(state.pipelines.isEmpty); #expect(state.context == nil); #expect(!state.loading)
        state.setVisible(false)
    }

    @Test
    func verifiedSettingsPersistOnlyReferenceAndKeychainCredential() async throws {
        let credentials = MemoryCredentials(), store = MemoryConfiguration()
        let settings = CISettingsModel(credentials: credentials, store: store, client: MonitorFixture())
        settings.selectCheckout("/fixture"); settings.enteredToken = "fixture-token"
        settings.save(); #expect(store.value.connections.isEmpty)
        settings.check(); try await waitFor { settings.verified }
        settings.save()
        let connection = try #require(settings.connection)
        #expect(try credentials.token(for: connection.id) == "fixture-token")
        #expect(settings.enteredToken.isEmpty)
        let persisted = try String(decoding: JSONEncoder().encode(store.value), as: UTF8.self)
        #expect(!persisted.contains("fixture-token"))
        #expect(store.value.checkouts["/fixture"] == connection.id)
        settings.check(); try await waitFor { settings.verified }
        settings.projectPath = "other/project"
        #expect(!settings.verified)
        settings.disconnect()
        #expect(credentials.values.isEmpty); #expect(store.value.connections.isEmpty); #expect(settings.connection == nil)
    }

    @Test
    func changedHostRequiresNewTokenAndCheckoutDoesNotReuseCredential() async throws {
        let credentials = MemoryCredentials(), store = MemoryConfiguration()
        store.value.connections = [self.connection]; store.value.checkouts["/fixture"] = self.connection.id
        credentials.values[self.connection.id] = "fixture-token"
        let settings = CISettingsModel(credentials: credentials, store: store, client: MonitorFixture())
        settings.selectCheckout("/fixture")
        #expect(settings.enteredToken.isEmpty)
        settings.address = "https://different.example.invalid"; settings.check()
        #expect(settings.error == .invalidConfiguration)
        settings.selectCheckout("/another"); settings.check()
        #expect(settings.error == .invalidConfiguration)
        #expect(settings.connection == nil)
    }
}
