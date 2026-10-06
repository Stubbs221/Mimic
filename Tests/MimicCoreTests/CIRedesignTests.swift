//
//  CIRedesignTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
@testable import MimicCore

private func redesignPipeline(_ id: Int, status: String = "success", ref: String = "develop", sha: String? = nil) -> CIPipeline {
    CIPipeline(id: id, status: status, sha: sha ?? "sha-\(id)", ref: ref, webURL: URL(string: "https://gitlab.example.invalid/team/mobile/-/pipelines/\(id)")!, createdAt: Date(timeIntervalSince1970: Double(id)), projectID: 272)
}
private actor RedesignClient: GitLabService {
    var own: [CIPipeline]
    let colleague: [CIPipeline]
    var detailRequests: [Int] = []
    var pipelineRequests: [Int] = []
    var commitRequests: [String] = []
    var pageRequests: [(String?, Int)] = []
    let roots: [Int: CIPipelineDetails]
    let failures: [Int: CIError]
    let commitFailure: CIError?
    init(own: [CIPipeline] = [], colleague: [CIPipeline] = [], roots: [Int: CIPipelineDetails] = [:], failures: [Int: CIError] = [:], commitFailure: CIError? = nil) { self.commitFailure = commitFailure; self.own = own; self.colleague = colleague; self.roots = roots; self.failures = failures }
    func finish(_ id: Int) { self.own = self.own.map { $0.id == id ? redesignPipeline(id, status: "success") : $0 } }
    func project(baseURL _: URL, path: String, token _: String) async throws -> CIProject { CIProject(id: 272, pathWithNamespace: path) }
    func currentUser(connection _: GitLabConnection, token _: String) async throws -> CIUser { CIUser(id: 1, username: "me", name: "Me") }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] { [] }
    func pipelines(connection _: GitLabConnection, branch _: String, token _: String) async throws -> [CIPipeline] { [] }
    func pipelinePage(connection _: GitLabConnection, username: String?, page: Int, perPage _: Int, token _: String) async throws -> CIPipelinePage {
        self.pageRequests.append((username, page))
        let values = username == "me" ? self.own : username == "colleague" ? self.colleague : []
        let start = (page - 1) * 4
        return CIPipelinePage(pipelines: Array(values.dropFirst(start).prefix(4)), nextPage: values.count > start + 4 ? page + 1 : nil)
    }
    func pipeline(connection _: GitLabConnection, id: Int, token _: String) async throws -> CIPipeline {
        self.pipelineRequests.append(id)
        return (self.own + self.colleague).first { $0.id == id } ?? redesignPipeline(id)
    }
    func commit(connection _: GitLabConnection, sha: String, token _: String) async throws -> CICommit { self.commitRequests.append(sha); if let commitFailure { throw commitFailure }; return CICommit(id: sha, title: "Commit " + sha) }
    func details(connection _: GitLabConnection, pipelineID: Int, token _: String) async throws -> CIPipelineDetails {
        self.detailRequests.append(pipelineID)
        if let failure = self.failures[pipelineID] { throw failure }
        return self.roots[pipelineID] ?? CIPipelineDetails(jobs: [], bridges: [])
    }
}
@MainActor private struct RedesignTracking: CITrackingStore {
    func users(connection _: GitLabConnection, owner _: CIUser) -> [CIUser] { [CIUser(id: 2, username: "colleague", name: "Colleague")] }
    func save(_: [CIUser], connection _: GitLabConnection, owner _: CIUser) { }
}
private actor RedesignHTTP: CIHTTPTransport {
    private var responses: [CIHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [CIHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        self.requests.append(request)
        guard !self.responses.isEmpty else { throw CIError.network }
        return self.responses.removeFirst()
    }
}
private func redesignResponse(_ body: String, status: Int = 200, location: String? = nil) -> CIHTTPResponse { CIHTTPResponse(data: Data(body.utf8), status: status, location: location) }
private func redesignContractJSON(_ kind: RemoteCIKind, upload: String = "FALSE") -> String {
    var definitions: [[String: Any]] = [["name": kind.branchParameter, "defaultParameterValue": ["value": "develop"]]]
    switch kind {
    case .uiTests: definitions += [["name": "TEST_PLAN", "choices": UITestPlan.allCases.map(\.rawValue), "defaultParameterValue": ["value": "SMOKE"]]]
    case .qualityGates: definitions += QualityGate.allCases.map { ["name": $0.rawValue, "defaultParameterValue": ["value": $0 != .performance]] }
    case .beta:
        definitions += [["name": "TARGET", "choices": ["movie", "tvos", "atelier", "atelier_tvos"], "defaultParameterValue": ["value": "movie"]],
                        ["name": "REBASE_BRANCH", "defaultParameterValue": ["value": ""]],
                        ["name": "UPLOAD_TO_APP_DISTRIBUTION", "choices": ["FALSE", "TRUE"], "defaultParameterValue": ["value": upload]]]
    }
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["property": [["parameterDefinitions": definitions]]]), as: UTF8.self)
}

@MainActor struct CIRedesignTests {
    let connection = GitLabConnection(baseURL: URL(string: "https://gitlab.example.invalid")!, projectID: 272, projectPath: "team/mobile")
    let jenkins = JenkinsConnection(baseURL: URL(string: "https://jenkins.example.invalid")!, username: "me")
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CIError.server
    }

    @Test func combinedHistoryPagesThreeAtATimeAndPreservesPersonalFooter() async throws {
        let own = stride(from: 20, through: 2, by: -2).map { redesignPipeline($0) }
        let others = stride(from: 19, through: 1, by: -2).map { redesignPipeline($0) }
        let client = RedesignClient(own: own, colleague: others)
        let state = CIState(client: client, trackingStore: RedesignTracking()) { _ in "fixture" }
        state.select(CIContext(project: ProjectContext(path: "/fixture"), connection: self.connection))
        state.setVisible(true); defer { state.setVisible(false) }
        try await self.wait { !state.loading }
        #expect(state.visibleEntries.compactMap { $0.pipeline?.id } == [20, 19, 18])
        #expect(state.pipelines.first?.id == 20 && state.canShowMore)
        state.showMore(); try await self.wait { !state.loading }
        #expect(state.visibleEntries.count == 6 && state.historyLimit == 6)
        state.refresh(manual: true); try await self.wait { !state.loading }
        #expect(state.visibleEntries.count == 6)
        state.showMore(); try await self.wait { !state.loading }
        #expect(state.visibleEntries.count == 9)
        while state.canShowMore { state.showMore(); try await self.wait { !state.loading } }
        #expect(state.feedEntries.count == 20 && state.visibleEntries.count == 20)
        #expect(Set(state.feedEntries.map(\.id)).count == 20)
        #expect(await client.pageRequests.contains { $0.0 == "colleague" && $0.1 == 3 })
        state.setVisible(false); #expect(state.historyLimit == 3)
    }

    @Test func queuedRunUsesOneStableIdentityWhenLinkedAndPreferencesDoNotFilterHistory() async throws {
        let client = RedesignClient(own: [redesignPipeline(10)])
        let state = CIState(client: client) { _ in "fixture" }
        state.select(CIContext(project: ProjectContext(path: "/fixture"), connection: self.connection))
        var run = RemoteTestRun(requestID: UUID(), checkout: ProjectContext(path: "/fixture"), branch: "develop", plan: .smoke, jenkins: self.jenkins, gitlab: self.connection)
        run.parameters = .beta(target: "movie", rebase: "", upload: "FALSE"); run.status = "queued"
        state.setJenkinsRuns([run], connection: self.jenkins)
        state.setVisible(true); defer { state.setVisible(false) }; try await self.wait { !state.loading }
        let identity = try #require(state.visibleEntries.first?.id)
        run.pipelineID = 10; run.sha = "sha-10"
        state.setJenkinsRuns([run], connection: self.jenkins); try await self.wait { !state.loading }
        #expect(state.feedEntries.count == 1 && state.feedEntries.first?.id == identity)
        #expect(state.feedEntries.first?.run?.kind == .beta)
    }

    @Test func enrichmentOnlyLoadsVisibleCardsAndSharesExpandedDetails() async throws {
        let client = RedesignClient(own: (1 ... 8).reversed().map { redesignPipeline($0) })
        let state = CIState(client: client) { _ in "fixture" }
        state.select(CIContext(project: ProjectContext(path: "/fixture"), connection: self.connection))
        state.setFeedPresented(true); state.setVisible(true); defer { state.setVisible(false) }
        try await self.wait { state.metadataStates.count == 3 && state.metadataStates.values.allSatisfy { $0 == .loaded } }
        #expect(await client.detailRequests.isEmpty)
        #expect(state.checkStates.isEmpty)
        state.loadDetails(8); state.loadDetails(8)
        try await self.wait { state.details != nil && state.checkStates[8] == .loaded }
        #expect(await client.detailRequests == [8])
        state.clearDetails(); state.loadDetails(8)
        #expect(!state.loadingDetails && state.details != nil)
        #expect(await client.detailRequests == [8])
        state.setFeedPresented(false); #expect(state.historyLimit == 3 && state.selectedPipelineID == nil)
    }

    @Test func sharedCommitCacheAndTerminalMetadataSurviveAutomaticRefresh() async throws {
        let client = RedesignClient(own: [redesignPipeline(3, sha: "common"), redesignPipeline(2, sha: "common"), redesignPipeline(1, sha: "common")])
        let state = CIState(client: client) { _ in "fixture" }
        state.select(CIContext(project: ProjectContext(path: "/fixture"), connection: self.connection))
        state.setFeedPresented(true); state.setVisible(true); defer { state.setVisible(false) }
        try await self.wait { state.metadataStates.count == 3 && state.metadataStates.values.allSatisfy { $0 == .loaded } }
        #expect(await client.commitRequests == ["common"])
        #expect(await client.detailRequests.isEmpty)
        state.refresh(); try await self.wait { !state.loading }
        #expect(await client.pipelineRequests == [3, 2, 1])
        state.loadDetails(2); try await self.wait { state.checkStates[2] == .loaded }
        state.clearDetails(); state.loadDetails(2)
        #expect(await client.detailRequests == [2])
    }

    @Test(arguments: [CIError.forbidden, .notFound, .network]) func optionalCommitFailurePreservesStatusAndAllowsDisclosure(failure: CIError) async throws {
        let client = RedesignClient(own: [redesignPipeline(3)], commitFailure: failure)
        let state = CIState(client: client) { _ in "fixture" }
        state.select(CIContext(project: ProjectContext(path: "/fixture"), connection: self.connection))
        state.setFeedPresented(true); state.setVisible(true); defer { state.setVisible(false) }
        try await self.wait { state.metadataStates[3] == .partial }
        #expect(state.visibleEntries.first?.status == "success" && !state.pollingPaused && state.error == nil)
        state.loadDetails(3); try await self.wait { state.checkStates[3] == .loaded }
        #expect(await client.detailRequests == [3])
        state.refresh(); try await self.wait { !state.loading }
        #expect(await client.commitRequests == ["sha-3"])
    }

    @Test func terminalCheckFailureWaitsForExplicitRetry() async throws {
        let client = RedesignClient(own: [redesignPipeline(3)], failures: [3: .network])
        let state = CIState(client: client) { _ in "fixture" }
        state.select(CIContext(project: ProjectContext(path: "/fixture"), connection: self.connection))
        state.setFeedPresented(true); state.setVisible(true); defer { state.setVisible(false) }
        try await self.wait { state.metadataStates[3] == .loaded }
        state.loadDetails(3); try await self.wait { state.checkStates[3] == .failed }
        state.clearDetails(); state.loadDetails(3); state.refresh()
        try await self.wait { !state.loading }
        #expect(await client.detailRequests == [3])
        state.retryDetails(3); try await self.wait { state.checkStates[3] == .failed }
        #expect(await client.detailRequests == [3, 3])
    }

    @Test func terminalTransitionLoadsFinalMetadataWithoutChecks() async throws {
        let client = RedesignClient(own: [redesignPipeline(3, status: "running")])
        let state = CIState(client: client) { _ in "fixture" }
        state.select(CIContext(project: ProjectContext(path: "/fixture"), connection: self.connection))
        state.setFeedPresented(true); state.setVisible(true); defer { state.setVisible(false) }
        try await self.wait { state.checkStates[3] == .loaded }
        await client.finish(3); state.refresh()
        try await self.wait { !state.loading && state.enrichedPipelines[3]?.status == "success" }
        #expect(state.visibleEntries.first?.status == "success")
        #expect(await client.detailRequests == [3])
        #expect(await client.pipelineRequests == [3, 3])
    }

    @Test func progressCountsFailuresAndSkipsButNotOptionalManualChecks() {
        func job(_ id: Int, _ status: String, optional: Bool = false) -> CIJob {
            CIJob(id: id, name: "Check", stage: "test", status: status, webURL: self.connection.baseURL, allowFailure: optional)
        }
        let summary = CIProgressSummary(jobs: [job(1, "success"), job(2, "failed", optional: true), job(3, "skipped"), job(4, "manual", optional: true), job(5, "manual"), job(6, "running"), job(7, "canceled")])
        #expect(summary.total == 6 && summary.completed == 4)
        #expect(summary.running.count == 1 && summary.failed.isEmpty && summary.waitingForManual)
    }

    @Test func childTraversalReplacesBridgeAndMarksMissingChildrenIncomplete() async throws {
        let child = redesignPipeline(2)
        let bridge = CIBridge(id: 11, name: "child", status: "running", webURL: self.connection.baseURL, downstreamPipeline: child)
        let missing = CIBridge(id: 12, name: "missing", status: "running", webURL: self.connection.baseURL, downstreamPipeline: redesignPipeline(3))
        let job = CIJob(id: 22, name: "Child test", stage: "test", status: "running", webURL: self.connection.baseURL, allowFailure: false)
        let root = CIPipelineDetails(jobs: [], bridges: [bridge, bridge, missing])
        let client = RedesignClient(roots: [1: root, 2: CIPipelineDetails(jobs: [job], bridges: []), 3: CIPipelineDetails(jobs: [], bridges: [], bridgeError: .network)])
        let summary = try await client.progress(connection: self.connection, pipelineID: 1, token: "fixture")
        #expect(summary.total == 1 && summary.running.first?.id == 22 && !summary.complete)
        #expect(await client.detailRequests == [1, 2, 3])
    }

    @Test func forbiddenChildIsPartialRatherThanAnAccountFailure() async throws {
        let bridge = CIBridge(id: 10, name: "Restricted child", status: "running", webURL: self.connection.baseURL, downstreamPipeline: redesignPipeline(2))
        let client = RedesignClient(roots: [1: CIPipelineDetails(jobs: [], bridges: [bridge])], failures: [2: .forbidden])
        let summary = try await client.progress(connection: self.connection, pipelineID: 1, token: "fixture")
        #expect(!summary.complete && summary.bridges.first?.id == 10)
    }

    @Test func launchPreferencesPersistAndDefaultToUITestsOnly() throws {
        let suite = "CIPreferences-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CILaunchPreferences(defaults: defaults)
        #expect(preferences.kinds == [.uiTests])
        preferences.qualityGates = true; preferences.beta = true
        #expect(CILaunchPreferences(defaults: defaults).kinds == [.uiTests, .qualityGates, .beta])
        preferences.qualityGates = false
        #expect(CILaunchPreferences(defaults: defaults).kinds == [.uiTests, .beta])
    }

    @Test func childTraversalHasHardDepthAndCountBounds() async throws {
        func bridge(_ id: Int) -> CIBridge { CIBridge(id: id + 100, name: "Child", status: "running", webURL: self.connection.baseURL, downstreamPipeline: redesignPipeline(id)) }
        let countClient = RedesignClient(roots: [1: CIPipelineDetails(jobs: [], bridges: (2 ... 22).map(bridge))])
        let count = try await countClient.progress(connection: self.connection, pipelineID: 1, token: "fixture")
        #expect(!count.complete && count.bridges.count == 1)
        #expect(await countClient.detailRequests.count == 21)
        let depthClient = RedesignClient(roots: Dictionary(uniqueKeysWithValues: (1 ... 5).map { ($0, CIPipelineDetails(jobs: [], bridges: [bridge($0 + 1)])) }))
        let depth = try await depthClient.progress(connection: self.connection, pipelineID: 1, token: "fixture")
        #expect(!depth.complete && depth.bridges.first?.downstreamPipeline?.id == 5)
        #expect(await depthClient.detailRequests == [1, 2, 3, 4])
    }

    @Test(arguments: RemoteCIKind.allCases) func contractsAndSubmissionUseOnlySelectedJob(kind: RemoteCIKind) async throws {
        let http = RedesignHTTP([redesignResponse(redesignContractJSON(kind)), redesignResponse("", status: 201, location: "/queue/item/99/")])
        let client = JenkinsClient(transport: http)
        let contract = try await client.contract(connection: self.jenkins, token: "fixture", kind: kind)
        let parameters = contract.parameters()
        #expect(contract.validates(parameters))
        let queue = try await client.submit(connection: self.jenkins, token: "fixture", branch: "feature/a+b&c", parameters: parameters)
        #expect(queue.path == "/queue/item/99")
        let requests = await http.requests
        #expect(requests.map { $0.url!.path } == ["/job/\(kind.job)/api/json", "/job/\(kind.job)/buildWithParameters"])
        let body = String(decoding: try #require(requests.last?.httpBody), as: UTF8.self)
        #expect(body.contains(kind.branchParameter + "=feature/a%2Bb%26c"))
        if kind == .qualityGates { #expect(body.contains("QG_UNIT_TESTS_TVOS=true") && body.contains("QG_VIEW_RENDERING_PERFORMANCE=false")) }
        if kind == .beta { #expect(body.contains("TARGET=movie") && body.contains("UPLOAD_TO_APP_DISTRIBUTION=FALSE") && body.contains("REBASE_BRANCH=")) }
    }

    @Test func changedBetaDefaultsPreventPOSTAndLegacyRunsStillDecode() async throws {
        let initial = JenkinsClient(transport: RedesignHTTP([redesignResponse(redesignContractJSON(.beta))]))
        let contract = try await initial.contract(connection: self.jenkins, token: "fixture", kind: .beta)
        let http = RedesignHTTP([redesignResponse(#"{"name":"develop"}"#), redesignResponse(redesignContractJSON(.beta, upload: "TRUE"))])
        let directory = URL(fileURLWithPath: "/private/tmp/CIRedesign-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = RemoteTestCoordinator(directory: directory, jenkins: JenkinsClient(transport: http), gitlab: GitLabClient(transport: http), jenkinsToken: { _ in "fixture" }, gitlabToken: { _ in "fixture" })
        await #expect(throws: JenkinsConnectionError.contractChanged) {
            try await owner.submit(requestID: UUID(), checkout: ProjectContext(path: "/fixture"), branch: "develop", parameters: contract.parameters(), jenkins: self.jenkins, gitlab: self.connection, reviewedContract: contract)
        }
        #expect(await http.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(owner.runs.isEmpty)
        let legacy = RemoteTestRun(requestID: UUID(), checkout: ProjectContext(path: "/fixture"), branch: "develop", plan: .functional, jenkins: self.jenkins, gitlab: self.connection)
        let decoded = try JSONDecoder().decode(RemoteTestRun.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.kind == .uiTests && decoded.resolvedParameters == .uiTests(.functional))
    }

    @Test func betaBuildDescriptionLinksExactPipelineAndRejectsForeignLinks() async throws {
        let url = "https://gitlab.example.invalid/team/mobile/-/pipelines/123"
        #expect(JenkinsClient.betaPipelineURL(description: "<a href='\(url)'>GitLab build 123</a>", connection: self.connection)?.absoluteString == url)
        #expect(JenkinsClient.betaPipelineURL(description: "<a href='https://foreign.invalid/team/mobile/-/pipelines/123'>123</a>", connection: self.connection) == nil)
        let directory = URL(fileURLWithPath: "/private/tmp/CIBetaLink-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var run = RemoteTestRun(requestID: UUID(), checkout: ProjectContext(path: "/fixture"), branch: "develop", plan: .smoke, jenkins: self.jenkins, gitlab: self.connection)
        run.parameters = .beta(target: "movie", rebase: "", upload: "FALSE"); run.status = "triggering"; run.buildURL = self.jenkins.baseURL.appendingPathComponent("job/ios_beta/9/")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([run]).write(to: directory.appendingPathComponent("remote-runs.json"))
        let build = try JSONSerialization.data(withJSONObject: ["building": false, "result": "SUCCESS", "description": "<a href='\(url)'>GitLab build 123</a>"])
        let http = RedesignHTTP([CIHTTPResponse(data: build, status: 200), redesignResponse(#"{"id":123,"project_id":272,"ref":"develop","sha":"remote-sha","status":"running","web_url":"https://gitlab.example.invalid/team/mobile/-/pipelines/123"}"#)])
        let owner = RemoteTestCoordinator(directory: directory, jenkins: JenkinsClient(transport: http), gitlab: GitLabClient(transport: http), jenkinsToken: { _ in "fixture" }, gitlabToken: { _ in "fixture" })
        try await owner.refreshOnce(run.id)
        #expect(owner.runs.first?.pipelineID == 123 && owner.runs.first?.status == "running")
        #expect(await http.requests.count == 2)
    }
}
