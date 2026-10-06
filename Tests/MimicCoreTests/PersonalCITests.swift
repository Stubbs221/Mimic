//
//  PersonalCITests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
@testable import MimicCore

private func personalPipeline(_ id: Int, ref: String = "develop", projectID: Int = 272) -> CIPipeline {
    CIPipeline(id: id, status: "success", sha: "sha-\(id)", ref: ref,
        webURL: URL(string: "https://gitlab.example.invalid/pipelines/\(id)")!, createdAt: Date(), projectID: projectID)
}

private actor PersonalFixture: GitLabService {
    var initiated: [String: [CIPipeline]]
    var pages: [Int: CIPipelinePage]
    var exact: [Int: CIPipeline]
    private(set) var requests: [(String?, Int)] = []
    private var suspendedUser: String?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var suspended = false
    init(initiated: [String: [CIPipeline]] = [:], pages: [Int: CIPipelinePage] = [:], exact: [Int: CIPipeline] = [:], suspend: String? = nil) {
        self.initiated = initiated; self.pages = pages; self.exact = exact; self.suspendedUser = suspend
    }
    func project(baseURL _: URL, path: String, token _: String) async throws -> CIProject { CIProject(id: 272, pathWithNamespace: path) }
    func currentUser(connection _: GitLabConnection, token: String) async throws -> CIUser {
        CIUser(id: token == "second" ? 2 : 1, username: token == "second" ? "colleague" : "vmaslov", name: "Account")
    }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] {
        [CIUser(id: 1, username: "vmaslov", name: "Me"), CIUser(id: 2, username: "colleague", name: "Константин Александрович Вишневский-Ковальчук")]
    }
    func pipelines(connection _: GitLabConnection, branch _: String, token _: String) async throws -> [CIPipeline] { throw CIError.invalidResponse }
    func pipelinePage(connection _: GitLabConnection, username: String?, page: Int, perPage _: Int, token _: String) async throws -> CIPipelinePage {
        self.requests.append((username, page))
        if let username {
            let values = self.initiated[username] ?? []
            if self.suspendedUser == username {
                self.suspendedUser = nil; self.suspended = true
                await withCheckedContinuation { self.continuation = $0 }
            }
            return CIPipelinePage(pipelines: values)
        }
        return self.pages[page] ?? CIPipelinePage(pipelines: [])
    }
    func pipeline(connection _: GitLabConnection, id: Int, token _: String) async throws -> CIPipeline {
        guard let value = self.exact[id] else { throw CIError.notFound }; return value
    }
    func details(connection _: GitLabConnection, pipelineID _: Int, token _: String) async throws -> CIPipelineDetails { CIPipelineDetails(jobs: [], bridges: []) }
    func release() { self.continuation?.resume(); self.continuation = nil }
}

@MainActor private final class PersonalCredential { var value = "first" }

@MainActor private final class PersonalTracking: CITrackingStore {
    var values: [Int: [CIUser]] = [:]
    func users(connection _: GitLabConnection, owner: CIUser) -> [CIUser] { self.values[owner.id] ?? [] }
    func save(_ users: [CIUser], connection _: GitLabConnection, owner: CIUser) { self.values[owner.id] = users }
}

@MainActor private func personalWait(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CIError.server
}

@MainActor struct PersonalCITests {
    private let connection = GitLabConnection(baseURL: URL(string: "https://gitlab.example.invalid")!, projectID: 272, projectPath: "team/mobile")
    private let colleague = CIUser(id: 2, username: "colleague", name: "Константин Александрович Вишневский-Ковальчук")
    private func context() -> CIContext {
        CIContext(project: ProjectContext(path: "/fixture", branch: "develop", commit: "local"), connection: self.connection)
    }

    @Test(arguments: ["feature/vmaslov/task", "bugfix/vmaslov/task/more"])
    func exactOwnerSegmentMatches(ref: String) { #expect(CIPersonalSelection.owns(ref: ref, username: "vmaslov", pattern: "^[^/]+/{username}/.+$")) }

    @Test(arguments: ["feature/vmaslov2/task", "feature/other/vmaslov", "vmaslov/task", "develop", "feature/vmaslov/", "/vmaslov/task"])
    func similarOrMissingSegmentsDoNotMatch(ref: String) { #expect(!CIPersonalSelection.owns(ref: ref, username: "vmaslov", pattern: "^[^/]+/{username}/.+$")) }

    @Test func sourcesMergeWithoutDuplicatesAndIgnoreUnrelatedProject() async throws {
        let own = personalPipeline(90), branch = personalPipeline(80, ref: "feature/vmaslov/task"), launched = personalPipeline(100)
        let fixture = PersonalFixture(initiated: ["vmaslov": [own, personalPipeline(200, projectID: 999)]],
            pages: [1: CIPipelinePage(pipelines: [personalPipeline(120, ref: "feature/vmaslov2/task"), branch])], exact: [100: launched, 90: own])
        let state = CIState(client: fixture, trackingStore: PersonalTracking()) { _ in "first" }
        state.branchOwnerPattern = "^[^/]+/{username}/.+$"
        state.select(self.context())
        let jenkins = JenkinsConnection(baseURL: URL(string: "https://jenkins.example.invalid")!, username: "personal")
        func run(_ id: Int, username: String = "personal") -> RemoteTestRun {
            var run = RemoteTestRun(requestID: UUID(), checkout: ProjectContext(path: "/fixture", branch: "develop", commit: "local"), branch: "develop", plan: .smoke,
                jenkins: JenkinsConnection(baseURL: jenkins.baseURL, username: username), gitlab: self.connection)
            run.pipelineID = id; run.sha = "sha-\(id)"; return run
        }
        state.setJenkinsRuns([run(100), run(90), run(150, username: "other")], connection: jenkins)
        state.setVisible(true); defer { state.setVisible(false) }
        try await personalWait { !state.loading }
        #expect(state.pipelines.map(\.id) == [100, 90, 80])
        #expect(state.reasons[90] == [.initiator, .jenkins])
        #expect(state.reasons[80] == [.branch])
        state.setJenkinsRuns([], connection: nil)
        #expect(!state.pipelines.contains { $0.id == 100 })
        try await personalWait { !state.loading }
        #expect(state.pipelines.map(\.id) == [90, 80])
    }

    @Test func sparseHistoryContinuesAfterTwentyPages() async throws {
        var pages: [Int: CIPipelinePage] = [:]
        for index in 1 ... 20 { pages[index] = CIPipelinePage(pipelines: [personalPipeline(2000 - index)], nextPage: index + 1) }
        pages[21] = CIPipelinePage(pipelines: [personalPipeline(10, ref: "feature/vmaslov/old-task")])
        let fixture = PersonalFixture(pages: pages), state = CIState(client: fixture, trackingStore: PersonalTracking()) { _ in "first" }
        state.branchOwnerPattern = "^[^/]+/{username}/.+$"
        state.select(self.context()); state.setVisible(true); defer { state.setVisible(false) }
        try await personalWait { !state.loading }
        #expect(state.historyIncomplete && state.pipelines.isEmpty)
        #expect(await fixture.requests.filter { $0.0 == nil }.count == 20)
        state.continueHistorySearch(); try await personalWait { !state.loading }
        #expect(!state.historyIncomplete)
        #expect(state.pipelines.map(\.id) == [10])
        #expect(await fixture.requests.last?.1 == 21)
    }

    @Test func branchMatchesStopScanAndPresentationOwnsVisibleLimit() async throws {
        let branchValues = (10 ... 14).map { personalPipeline($0, ref: "feature/vmaslov/task") }
        let fixture = PersonalFixture(initiated: ["vmaslov": [personalPipeline(20), personalPipeline(12, ref: "feature/vmaslov/task")]],
            pages: [1: CIPipelinePage(pipelines: branchValues, nextPage: 2)])
        let state = CIState(client: fixture, trackingStore: PersonalTracking()) { _ in "first" }
        state.branchOwnerPattern = "^[^/]+/{username}/.+$"
        state.select(self.context()); state.setVisible(true); defer { state.setVisible(false) }
        try await personalWait { !state.loading }
        #expect(state.pipelines.map(\.id) == [20, 14, 13, 12, 11, 10])
        #expect(state.visibleEntries.count == 3)
        #expect(!state.historyIncomplete)
        #expect(await fixture.requests.filter { $0.0 == nil }.count == 1)
    }

    @Test func subscriptionsRestoreAndNeverChangePersonalLatest() async throws {
        let store = PersonalTracking(), fixture = PersonalFixture(initiated: ["vmaslov": [personalPipeline(20)], "colleague": [personalPipeline(100)]],
            pages: [1: CIPipelinePage(pipelines: [personalPipeline(200, ref: "feature/colleague/task")])])
        let state = CIState(client: fixture, trackingStore: store) { _ in "first" }
        state.branchOwnerPattern = "^[^/]+/{username}/.+$"
        state.select(self.context()); state.setVisible(true); defer { state.setVisible(false) }
        try await personalWait { !state.loading }
        state.track(try #require(state.user)); #expect(state.trackedUsers.isEmpty)
        state.track(self.colleague); state.track(self.colleague)
        try await personalWait { !state.loading }
        #expect(state.trackedUsers.count == 1 && state.trackedUsers.first?.pipelines.map(\.id) == [100])
        #expect(state.pipelines.first?.id == 20)
        state.loadDetails(100); try await personalWait { !state.loadingDetails }
        state.untrack(2); #expect(state.selectedPipelineID == nil)
        try await personalWait { !state.loading }
        state.track(self.colleague); try await personalWait { !state.loading }
        let restored = CIState(client: fixture, trackingStore: store) { _ in "first" }
        restored.branchOwnerPattern = "^[^/]+/{username}/.+$"
        restored.select(self.context()); restored.setVisible(true); defer { restored.setVisible(false) }
        try await personalWait { !restored.loading }
        #expect(restored.trackedUsers.first?.user == self.colleague)
    }

    @Test func accountReplacementImmediatelyClearsOldFeedAndSubscriptions() async throws {
        let fixture = PersonalFixture(initiated: ["vmaslov": [personalPipeline(20)], "colleague": [personalPipeline(100)]])
        let credential = PersonalCredential()
        let state = CIState(client: fixture, trackingStore: PersonalTracking()) { _ in credential.value }
        state.branchOwnerPattern = "^[^/]+/{username}/.+$"
        state.select(self.context()); state.setVisible(true); defer { state.setVisible(false) }
        try await personalWait { !state.loading }; state.track(self.colleague); try await personalWait { !state.loading }
        credential.value = "second"; state.credentialsChanged()
        #expect(state.pipelines.isEmpty && state.trackedUsers.isEmpty && state.user == nil)
        try await personalWait { !state.loading }
        #expect(state.user?.id == 2 && state.pipelines.first?.id == 100 && state.trackedUsers.isEmpty)
    }

    @Test func unsubscribeRejectsLateResponse() async throws {
        let fixture = PersonalFixture(initiated: ["colleague": [personalPipeline(100)]], suspend: "colleague")
        let state = CIState(client: fixture, trackingStore: PersonalTracking()) { _ in "first" }
        state.branchOwnerPattern = "^[^/]+/{username}/.+$"
        state.select(self.context()); state.setVisible(true); defer { state.setVisible(false) }
        try await personalWait { !state.loading }; state.track(self.colleague)
        for _ in 0 ..< 300 { if await fixture.suspended { break }; await Task.yield() }
        #expect(await fixture.suspended)
        state.untrack(2); await fixture.release(); try await personalWait { !state.loading }
        #expect(state.trackedUsers.isEmpty && state.pipelines.isEmpty)
    }

    @Test func searchExcludesSelfAndAlreadyTrackedUsers() async throws {
        let state = CIState(client: PersonalFixture(), trackingStore: PersonalTracking()) { _ in "first" }
        state.branchOwnerPattern = "^[^/]+/{username}/.+$"
        state.select(self.context()); state.setVisible(true); defer { state.setVisible(false) }
        try await personalWait { !state.loading }
        state.searchUsers("Константин"); try await personalWait { !state.searching }
        #expect(state.searchResults.map(\.id) == [2])
        state.track(self.colleague); try await personalWait { !state.loading }
        state.searchUsers("Константин"); try await personalWait { !state.searching }
        #expect(state.searchResults.isEmpty)
    }

    @Test func defaultsSubscriptionsAreAccountAndProjectScoped() throws {
        let suite = "PersonalCI-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = CIUser(id: 1, username: "vmaslov", name: "Me"), store = DefaultsCITrackingStore(defaults: defaults)
        #expect(store.users(connection: self.connection, owner: owner).isEmpty)
        store.save([self.colleague], connection: self.connection, owner: owner)
        #expect(DefaultsCITrackingStore(defaults: defaults).users(connection: self.connection, owner: owner) == [self.colleague])
        #expect(store.users(connection: self.connection, owner: self.colleague).isEmpty)
        let project = GitLabConnection(baseURL: self.connection.baseURL, projectID: 999, projectPath: "other")
        #expect(store.users(connection: project, owner: owner).isEmpty)
        let host = GitLabConnection(baseURL: URL(string: "https://other.example.invalid")!, projectID: 272, projectPath: "team/mobile")
        #expect(store.users(connection: host, owner: owner).isEmpty)
    }
}
