// Created by Василий Маслов on 06.10.2026.
import Foundation
import Testing
@testable import MimicCore

private func compactPipeline(_ id: Int, status: String = "running", branch: String = "feature/me/check", created: Date = Date(timeIntervalSince1970: 1_790_000_000), started: Date? = nil) throws -> CIPipeline {
    let body: [String: Any] = ["id": id, "project_id": 272, "status": status, "sha": "sha-\(id)", "ref": branch,
        "web_url": "https://ci.example.invalid/team/mobile/-/pipelines/\(id)", "created_at": created.ISO8601Format(),
        "started_at": (started ?? created).ISO8601Format(), "duration": 120]
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CIPipeline.self, from: JSONSerialization.data(withJSONObject: body))
}

private actor CompactClient: GitLabService {
    var own: [CIPipeline]
    let colleague: [CIPipeline]
    private(set) var detailRequests: [Int] = []
    private(set) var usersRequested: [String] = []
    var failDetails = false
    var failFeed = false
    init(own: [CIPipeline], colleague: [CIPipeline] = []) { self.own = own; self.colleague = colleague }
    func finish(_ id: Int, status: String = "success") throws {
        self.own = try self.own.map { $0.id == id ? try compactPipeline(id, status: status) : $0 }
    }
    func add(_ value: CIPipeline) { self.own.insert(value, at: 0) }
    func fail() { self.failFeed = true }
    func project(baseURL _: URL, path _: String, token _: String) async throws -> CIProject { throw CIError.notFound }
    func currentUser(connection _: GitLabConnection, token _: String) async throws -> CIUser { CIUser(id: 1, username: "me", name: "Me") }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] { [] }
    func pipelines(connection _: GitLabConnection, branch _: String, token _: String) async throws -> [CIPipeline] { self.own }
    func pipelinePage(connection _: GitLabConnection, username: String?, page _: Int, perPage _: Int, token _: String) async throws -> CIPipelinePage {
        if self.failFeed { throw CIError.network }
        self.usersRequested.append(username ?? "all")
        return CIPipelinePage(pipelines: username == "other" ? self.colleague : self.own)
    }
    func pipeline(connection _: GitLabConnection, id: Int, token _: String) async throws -> CIPipeline {
        try #require((self.own + self.colleague).first { $0.id == id })
    }
    func details(connection: GitLabConnection, pipelineID: Int, token _: String) async throws -> CIPipelineDetails {
        self.detailRequests.append(pipelineID)
        if self.failDetails { throw CIError.network }
        let terminal = self.own.first { $0.id == pipelineID }?.status == "success"
        return CIPipelineDetails(jobs: [
            CIJob(id: 1, name: "check with a very long job name", stage: "test", status: terminal ? "success" : "running", webURL: connection.baseURL, allowFailure: false),
            CIJob(id: 2, name: "finished", stage: "test", status: "success", webURL: connection.baseURL, allowFailure: false),
            CIJob(id: 3, name: "optional", stage: "test", status: "manual", webURL: connection.baseURL, allowFailure: true)
        ], bridges: [])
    }
    func commit(connection _: GitLabConnection, sha: String, token _: String) async throws -> CICommit { CICommit(id: sha, title: "Fixture") }
}

@MainActor private struct CompactTracking: CITrackingStore {
    func users(connection _: GitLabConnection, owner _: CIUser) -> [CIUser] { [CIUser(id: 2, username: "other", name: "Other")] }
    func save(_: [CIUser], connection _: GitLabConnection, owner _: CIUser) { }
}

@MainActor struct CICompactTests {
    private let connection = GitLabConnection(baseURL: URL(string: "https://ci.example.invalid")!, projectID: 272, projectPath: "team/mobile")
    private func context(_ path: String = "/fixture") -> CIContext { CIContext(project: ProjectContext(path: path), connection: self.connection) }
    private func state(_ client: CompactClient, interval: Duration = .seconds(30)) -> CIState {
        let state = CIState(client: client, interval: interval, trackingStore: CompactTracking()) { _ in "fixture" }
        state.select(self.context()); return state
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func twoRunsPreferActivityThenActualStartAndLoadChecksOnce() async throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let client = CompactClient(own: [
            try compactPipeline(4, status: "success", created: base.addingTimeInterval(400)),
            try compactPipeline(3, created: base.addingTimeInterval(300), started: base),
            try compactPipeline(2, created: base, started: base.addingTimeInterval(200))
        ])
        let state = self.state(client); state.setMonitoring(true)
        defer { state.setMonitoring(false) }
        try await self.wait { state.compactSummaries.count == 2 && state.compactSummaries.allSatisfy { $0.completed == 1 } }
        #expect(state.compactSummaries.map(\.pipelineID) == [2, 3])
        #expect(await client.detailRequests == [2, 3])
        state.refresh(); try await self.wait { !state.loading }
        #expect(await client.detailRequests == [2, 3])
        try await client.finish(2); state.refresh()
        try await self.wait { state.compactSummaries.first?.pipelineID == 3 && state.compactSummaries.last?.pipelineID == 4 }
    }

    @Test func panelInspectionSharesCacheAndRetainsAnEntryWithoutNativeSelection() async throws {
        let client = CompactClient(own: [try compactPipeline(3), try compactPipeline(2, status: "success")])
        let state = self.state(client); state.setMonitoring(true)
        defer { state.setMonitoring(false) }
        try await self.wait { state.compactSummaries.count == 2 && state.compactSummaries.allSatisfy { $0.completed != nil } }
        let entry = try #require(state.inspectPersonalEntry("pipeline.2", viewer: "a"))
        #expect(entry.pipeline?.id == 2 && state.selectedPipelineID == nil)
        #expect(state.inspectPersonalEntry("pipeline.3", viewer: "b")?.pipeline?.id == 3)
        try await client.add(compactPipeline(5)); state.refresh()
        try await self.wait { state.compactSummaries.map(\.pipelineID) == [5, 3] }
        #expect(state.inspectPersonalEntry("pipeline.2", viewer: "a")?.pipeline?.id == 2)
        #expect(state.selectedPipelineID == nil)
        #expect(state.rootChecks(for: 2)?.jobs.count == 3)
        #expect(state.inspectPersonalEntry("pipeline.999", viewer: "a") == nil)
        #expect(await client.detailRequests.filter { $0 == 2 }.count == 1)
    }

    @Test func failedSummaryIdentifiesFirstMandatoryFailure() throws {
        let pipeline = try compactPipeline(7, status: "failed")
        let jobs = [
            CIJob(id: 1, name: "optional", stage: "test", status: "failed", webURL: self.connection.baseURL, allowFailure: true),
            CIJob(id: 3, name: "required-second", stage: "test", status: "failed", webURL: self.connection.baseURL, allowFailure: false),
            CIJob(id: 2, name: "required-first", stage: "test", status: "failed", webURL: self.connection.baseURL, allowFailure: false)
        ]
        let summary = CICompactSummary(entry: CIFeedEntry(pipeline: pipeline), context: self.context(), accountID: 1, checks: CIProgressSummary(jobs: jobs), updatedAt: nil, stale: false)
        #expect(summary.displayID == "#7" && summary.firstFailedJob == "required-first")
    }

    @Test func compactSelectionExcludesSubscriptionsAndPrefersAnOlderActiveRun() async throws {
        let client = CompactClient(own: [try compactPipeline(4, status: "success"), try compactPipeline(3)], colleague: [try compactPipeline(9)])
        let state = self.state(client); state.setFeedPresented(true); state.setVisible(true)
        defer { state.setVisible(false) }
        try await self.wait { !state.loading && state.feedEntries.count == 3 }
        #expect(state.feedEntries.first?.pipeline?.id == 9)
        #expect(state.compactSummary?.pipelineID == 3)
        #expect(state.compactSummary?.branch == "feature/me/check")
    }

    @Test func backgroundPollingLoadsOnlyPersonalSelectionAndFinalChecks() async throws {
        let client = CompactClient(own: [try compactPipeline(3)])
        let state = self.state(client); state.setMonitoring(true)
        defer { state.setMonitoring(false) }
        try await self.wait { state.compactSummary?.completed == 1 }
        #expect(!state.visible && !state.feedPresented && state.selectedPipelineID == nil)
        #expect(state.compactSummary?.total == 2 && state.compactSummary?.fraction == 0.5)
        #expect(await client.usersRequested == ["me"])
        try await client.finish(3); state.refresh()
        try await self.wait { state.compactSummary?.status == "success" && state.compactSummary?.completed == 2 }
        #expect(state.compactSummary?.fraction == 1)
        #expect(await client.detailRequests == [3, 3])
        state.refresh(); try await self.wait { !state.loading }
        #expect(await client.detailRequests == [3, 3])
    }

    @Test func queueIdentitySurvivesPipelineLinking() async throws {
        let client = CompactClient(own: [try compactPipeline(3)])
        let state = self.state(client)
        let jenkins = JenkinsConnection(baseURL: URL(string: "https://jenkins.example.invalid")!, username: "me")
        var run = RemoteTestRun(requestID: UUID(), checkout: ProjectContext(path: "/fixture"), branch: "feature/me/check", plan: .smoke, jenkins: jenkins, gitlab: self.connection)
        run.status = "queued"; state.setJenkinsRuns([run], connection: jenkins)
        state.setMonitoring(true); defer { state.setMonitoring(false) }
        try await self.wait { state.user != nil && !state.loading }
        let before = try #require(state.compactSummary)
        #expect(before.startedAt == nil && before.duration == nil && before.fraction == nil)
        run.pipelineID = 3; run.sha = "sha-3"; state.setJenkinsRuns([run], connection: jenkins)
        try await self.wait { state.compactSummary?.pipelineID == 3 && state.compactSummary?.completed == 1 }
        #expect(state.compactSummary?.identity == before.identity)
    }

    @Test func incompleteChecksAndNetworkFailureDoNotInventProgress() async throws {
        let pipeline = try compactPipeline(3)
        let job = CIJob(id: 1, name: "check", stage: "test", status: "success", webURL: self.connection.baseURL, allowFailure: false)
        let partial = CICompactSummary(entry: CIFeedEntry(pipeline: pipeline), context: self.context(), accountID: 1, checks: CIProgressSummary(jobs: [job], complete: false), updatedAt: nil, stale: false)
        #expect(partial.completed == 1 && partial.fraction == nil)
        let client = CompactClient(own: [pipeline]), state = self.state(client)
        state.setMonitoring(true); defer { state.setMonitoring(false) }
        try await self.wait { state.compactSummary?.completed == 1 }
        await client.fail(); state.refresh(); try await self.wait { !state.loading && state.error != nil }
        #expect(state.compactSummary?.stale == true && state.compactSummary?.completed == 1)
    }

    @Test func leasesShareRequestsRetainDisplayedRunAndDismissOnlyItsIdentity() async throws {
        let client = CompactClient(own: [try compactPipeline(3)])
        var now = Date()
        let monitor = CIActivityMonitor(now: { now }) { _ in CIState(client: client, trackingStore: CompactTracking()) { _ in "fixture" } }
        defer { monitor.stop() }
        _ = monitor.heartbeat(threadID: "a", context: self.context("/checkout-a"))
        _ = monitor.heartbeat(threadID: "b", context: self.context("/checkout-b"))
        try await self.wait { monitor.overlay?.pipelineID == 3 }
        #expect(await client.usersRequested == ["me"])
        let a = try #require(monitor.heartbeat(threadID: "a", context: self.context("/checkout-a")))
        let b = try #require(monitor.heartbeat(threadID: "b", context: self.context("/checkout-b")))
        #expect(a.checkout == "/checkout-a" && b.checkout == "/checkout-b" && a.scopeID == b.scopeID)
        let state = try #require(monitor.state(for: a))
        now = now.addingTimeInterval(31); monitor.reconcile()
        #expect(state.monitoring)
        monitor.hideCI(); #expect(monitor.overlay == nil && !state.monitoring)
        _ = monitor.heartbeat(threadID: "a", context: self.context()); monitor.reconcile()
        #expect(monitor.overlay == nil)
        try await client.add(compactPipeline(5, created: Date(timeIntervalSince1970: 1_790_000_100)))
        state.refresh(); try await self.wait { monitor.overlay?.pipelineID == 5 }
    }

    @Test func historicalCompletionDoesNotOpenOverlayAndSameAccountKeepsDismissal() async throws {
        let client = CompactClient(own: [try compactPipeline(3, status: "success")])
        let monitor = CIActivityMonitor { _ in CIState(client: client, trackingStore: CompactTracking()) { _ in "fixture" } }
        monitor.setDesktop(self.context()); defer { monitor.stop() }
        let state = try #require(monitor.desktopState)
        try await self.wait { state.compactSummary?.completed == 2 }
        #expect(monitor.overlay == nil)
        try await client.add(compactPipeline(4, created: Date(timeIntervalSince1970: 1_790_000_100)))
        state.refresh(); try await self.wait { monitor.overlay?.pipelineID == 4 }
        monitor.hideCI(); monitor.credentialsChanged()
        try await self.wait { !state.loading && state.user != nil }
        monitor.reconcile(); #expect(monitor.overlay == nil)
    }

    @Test func completionDeadlineThenResumesRemainingActiveAndFailureStays() async throws {
        let client = CompactClient(own: [try compactPipeline(4, created: Date(timeIntervalSince1970: 1_790_000_100)), try compactPipeline(3)])
        var now = Date()
        let monitor = CIActivityMonitor(now: { now }) { _ in CIState(client: client, trackingStore: CompactTracking()) { _ in "fixture" } }
        monitor.setDesktop(self.context()); defer { monitor.stop() }
        try await self.wait { monitor.overlay?.pipelineID == 4 }
        let state = try #require(monitor.desktopState)
        try await client.finish(4); state.refresh(); try await self.wait { monitor.overlay?.status == "success" }
        now = now.addingTimeInterval(4); monitor.reconcile(); #expect(monitor.overlay?.pipelineID == 4)
        now = now.addingTimeInterval(2); monitor.reconcile(); #expect(monitor.overlay?.pipelineID == 3)
        try await client.finish(3, status: "failed"); state.refresh(); try await self.wait { monitor.overlay?.status == "failed" }
        now = now.addingTimeInterval(100); monitor.reconcile(); #expect(monitor.overlay?.status == "failed")
    }

    @Test func sharedRemoteProjectKeepsDesktopAndChatCheckoutContextsDistinct() async throws {
        let client = CompactClient(own: [try compactPipeline(3)])
        var statesCreated = 0
        let monitor = CIActivityMonitor { _ in
            statesCreated += 1
            return CIState(client: client, trackingStore: CompactTracking()) { _ in "fixture" }
        }
        defer { monitor.stop() }
        _ = monitor.heartbeat(threadID: "chat", context: self.context("/chat"))
        try await self.wait { monitor.overlay != nil }
        let overlay = try #require(monitor.overlay)
        let chatState = try #require(monitor.state(for: overlay))
        chatState.setVisible(true); chatState.setFeedPresented(true); chatState.revealPipeline(3)
        monitor.setDesktop(self.context("/desktop"))
        try await self.wait { monitor.desktopState?.compactSummary?.checkout == "/desktop" }
        #expect(statesCreated == 1)
        #expect(monitor.heartbeat(threadID: "chat", context: self.context("/chat"))?.checkout == "/chat")
        #expect(monitor.desktopState?.context?.checkout == "/desktop")
        #expect(monitor.desktopState?.selectedPipelineID == 3)
        #expect(monitor.overlay?.checkout == "/chat")
    }

    @Test func backgroundTimersContinueAfterFullPanelHidesAndStopWithoutInterest() async throws {
        let client = CompactClient(own: [try compactPipeline(3)])
        let state = CIState(client: client, interval: .milliseconds(160), enrichmentInterval: .milliseconds(80), trackingStore: CompactTracking()) { _ in "fixture" }
        state.select(self.context()); state.setMonitoring(true)
        defer { state.setVisible(false); state.setMonitoring(false) }
        try await self.wait { state.compactSummary?.completed == 1 }
        state.setVisible(true); state.setFeedPresented(true)
        try await self.wait { !state.loading }
        state.setVisible(false)
        let feedCount = await client.usersRequested.count, checkCount = await client.detailRequests.count
        for _ in 0..<100 {
            let feed = await client.usersRequested.count, checks = await client.detailRequests.count
            if feed > feedCount && checks > checkCount { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let liveFeed = await client.usersRequested.count, liveChecks = await client.detailRequests.count
        #expect(liveFeed > feedCount && liveChecks > checkCount)
        state.setMonitoring(false)
        let stoppedFeed = await client.usersRequested.count, stoppedChecks = await client.detailRequests.count
        try await Task.sleep(for: .milliseconds(240))
        let finalFeed = await client.usersRequested.count, finalChecks = await client.detailRequests.count
        #expect(finalFeed == stoppedFeed && finalChecks == stoppedChecks)
    }
}
