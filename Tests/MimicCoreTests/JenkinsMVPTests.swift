//
//  JenkinsMVPTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation
import Testing
@testable import MimicCore

private actor JenkinsHTTPFixture: CIHTTPTransport {
    var responses: [CIHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [CIHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        self.requests.append(request)
        guard !self.responses.isEmpty else { throw CIError.network }
        return self.responses.removeFirst()
    }
}
private func response(_ value: String, status: Int = 200, location: String? = nil, textSize: Int? = nil) -> CIHTTPResponse { .init(data: Data(value.utf8), status: status, location: location, textSize: textSize) }
private let jenkins = JenkinsConnection(baseURL: URL(string: "https://jenkins.example.invalid")!, username: "fixture-user")
private let gitlab = GitLabConnection(baseURL: URL(string: "https://gitlab.example.invalid")!, projectID: 272, projectPath: "team/mobile")
private let trigger = #"{"id":123,"project_id":272,"ref":"feature/a+b&c","sha":"original-sha","web_url":"https://gitlab.example.invalid/team/mobile/-/pipelines/123"}"#

private func gitParameterContract(values: [String], legacy: Bool = false, errors: [String] = []) throws -> String {
    let items = values.map { ["value": $0] }
    let definition: [String: Any] = ["name": "BRANCH", "_class": "net.uaznia.lukanus.hudson.plugins.gitparameter.GitParameterDefinition",
                                   "allValueItems": legacy ? items : ["values": items, "errors": errors]]
    let plans: [String: Any] = ["name": "TEST_PLAN", "choices": UITestPlan.allCases.map(\.rawValue)]
    return String(decoding: try JSONSerialization.data(withJSONObject: ["property": [["parameterDefinitions": [definition, plans]]]]), as: UTF8.self)
}

@MainActor
private struct JenkinsCheckCredentials: CICredentialStore {
    func token(for _: UUID, interaction: CICredentialInteraction = .silent) throws -> String { throw CIError.credential }
    func save(_: String, for _: UUID) { }
    func remove(_: UUID) { }
}

struct JenkinsMVPTests {
    @Test func submitEncodesOnlyBranchAndPlanAndRejectsForeignQueue() async throws {
        let http = JenkinsHTTPFixture([response("", status: 201, location: "https://jenkins.example.invalid/queue/item/7/")])
        let url = try await JenkinsClient(transport: http).submit(connection: jenkins, token: "fixture-token", branch: "feature/a+b&c", plan: .smoke)
        #expect(url.path == "/queue/item/7")
        let request = try #require(await http.requests.first)
        #expect(request.httpMethod == "POST")
        let encoded = try #require(request.httpBody)
        let items = try #require(URLComponents(string: "?" + String(decoding: encoded, as: UTF8.self))?.queryItems)
        #expect(items.count == 2)
        #expect(items.first { $0.name == "BRANCH" }?.value == "feature/a+b&c")
        #expect(items.first { $0.name == "TEST_PLAN" }?.value == "SMOKE")
        #expect(request.url?.absoluteString.contains("fixture-token") == false)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        let foreign = JenkinsHTTPFixture([response("", status: 201, location: "https://other.example.invalid/queue/item/7/")])
        await #expect(throws: CIError.invalidResponse) { try await JenkinsClient(transport: foreign).submit(connection: jenkins, token: "fixture-token", branch: "develop", plan: .smoke) }
    }
    @Test func triggerParserHandlesStageBracesAndPinsIdentity() {
        let data = Data(("[Pipeline] { (Stage)\nsecret must stay internal\n" + trigger + "\n[Pipeline] }").utf8)
        let pipeline = JenkinsClient.pipeline(in: data, connection: gitlab, branch: "feature/a+b&c")
        #expect(pipeline?.id == 123)
        #expect(pipeline?.sha == "original-sha")
        #expect(JenkinsClient.pipeline(in: data, connection: gitlab, branch: "other") == nil)
        let foreign = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "gitlab.example.invalid", with: "foreign.example.invalid").utf8)
        #expect(JenkinsClient.pipeline(in: foreign, connection: gitlab, branch: "feature/a+b&c") == nil)
    }
    @Test @MainActor func ambiguousSubmissionIsPersistedAndNeverRepeated() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/MimicRun-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = JenkinsHTTPFixture([response(#"{"name":"feature/a+b&c"}"#), response(try gitParameterContract(values: ["origin/feature/a+b&c"]))])
        let coordinator = RemoteTestCoordinator(directory: directory, jenkins: JenkinsClient(transport: http), gitlab: GitLabClient(transport: http), jenkinsToken: { _ in "fixture-j" }, gitlabToken: { _ in "fixture-g" })
        let requestID = UUID(), checkout = ProjectContext(path: "/private/tmp/fixture", branch: "local", commit: "local-sha")
        let first = try await coordinator.submit(requestID: requestID, checkout: checkout, branch: "feature/a+b&c", plan: .smoke, jenkins: jenkins, gitlab: gitlab)
        #expect(first.status == "unknown")
        let second = try await coordinator.submit(requestID: requestID, checkout: checkout, branch: "feature/a+b&c", plan: .smoke, jenkins: jenkins, gitlab: gitlab)
        #expect(second.id == first.id)
        #expect(await http.requests.filter { $0.httpMethod == "POST" }.count == 1)
        let resumed = RemoteTestCoordinator(directory: directory, jenkinsToken: { _ in "fixture-j" }, gitlabToken: { _ in "fixture-g" })
        #expect(resumed.runs.first?.id == first.id)
        #expect(resumed.runs.first?.status == "unknown")
        let disk = try String(contentsOf: directory.appendingPathComponent("remote-runs.json"), encoding: .utf8)
        #expect(!disk.contains("fixture-j")); #expect(!disk.contains("fixture-g"))
        await #expect(throws: CIError.invalidConfiguration) { try await coordinator.submit(requestID: requestID, checkout: checkout, branch: "other", plan: .smoke, jenkins: jenkins, gitlab: gitlab) }
    }
    @Test @MainActor func followsExactPipelineAndKeepsAllowedFailureVisible() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/MimicRun-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = RemoteTestRun(requestID: UUID(), checkout: ProjectContext(path: "/tmp/fixture"), branch: "feature/a+b&c", plan: .smoke, jenkins: jenkins, gitlab: gitlab)
        var saved = run; saved.status = "triggering"; saved.buildURL = URL(string: "https://jenkins.example.invalid/job/ios_ui_tests_simulator/9/")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([saved]).write(to: directory.appendingPathComponent("remote-runs.json"))
        let pipelineJSON = #"{"id":123,"status":"success","sha":"original-sha","ref":"feature/a+b&c","web_url":"https://gitlab.example.invalid/team/mobile/-/pipelines/123","created_at":"2026-10-04T12:00:00Z"}"#
        let jobs = #"[{"id":4,"name":"UI tests","stage":"test","status":"failed","web_url":"https://gitlab.example.invalid/team/mobile/-/jobs/4","allow_failure":true}]"#
        let http = JenkinsHTTPFixture([response(#"{"building":false,"result":"SUCCESS"}"#), response(trigger, textSize: trigger.utf8.count), response(pipelineJSON), response(jobs), response("[]"), response("456")])
        let coordinator = RemoteTestCoordinator(directory: directory, jenkins: JenkinsClient(transport: http), gitlab: GitLabClient(transport: http), jenkinsToken: { _ in "fixture-j" }, gitlabToken: { _ in "fixture-g" })
        try await coordinator.refreshOnce(run.id)
        #expect(coordinator.runs.first?.status == "pending")
        #expect(coordinator.runs.first?.pipelineID == 123)
        try await coordinator.refreshOnce(run.id)
        #expect(coordinator.runs.first?.status == "success")
        #expect(coordinator.runs.first?.jobs.first?.status == "failed")
        #expect(coordinator.runs.first?.jobs.first?.allowFailure == true)
        #expect(coordinator.runs.first?.allureURL?.absoluteString == "https://reports.example.com/launch/456")
        let requests = await http.requests
        #expect(requests.contains { $0.url?.path.hasSuffix("/pipelines/123") == true })
        #expect(!requests.contains { $0.url?.query?.contains("ref=") == true })
    }
}

// MARK: - Submission regression coverage

extension JenkinsMVPTests {
    @Test(arguments: [false, true])
    func gitParameterUsesAdvertisedWireValueWithoutChangingReviewedContract(legacy: Bool) async throws {
        let body = try gitParameterContract(values: ["feature/a+b&c", "origin/feature/a+b&c"], legacy: legacy)
        let http = JenkinsHTTPFixture([response(body), response(body), response(try gitParameterContract(values: ["origin/other"], legacy: legacy))])
        let client = JenkinsClient(transport: http)
        let reviewed = try await client.contract(connection: jenkins, token: "fixture", kind: .uiTests)
        #expect(throws: JenkinsConnectionError.branchValuesUnavailable) { try reviewed.branchValue(for: "feature/a+b&c") }
        let current = try await client.contract(connection: jenkins, token: "fixture", kind: .uiTests, includeBranchValues: true)
        #expect(try current.branchValue(for: "feature/a+b&c") == "origin/feature/a+b&c")
        #expect(current == reviewed)
        let changedList = try await client.contract(connection: jenkins, token: "fixture", kind: .uiTests, includeBranchValues: true)
        #expect(changedList == reviewed)
        #expect(throws: JenkinsConnectionError.branchUnavailable) { try changedList.branchValue(for: "feature/a+b&c") }
        let tree = URLComponents(url: try #require(await http.requests[1].url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tree" }?.value
        #expect(tree?.contains("allValueItems[value,values[value],errors]") == true)
    }

    @Test(arguments: [false, true]) @MainActor
    func nativeAndMCPAdmissionKeepGitLabBranchButPOSTQualifiedValue(reviewed: Bool) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/MimicRun-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = try gitParameterContract(values: ["origin/feature/a+b&c"])
        let http = JenkinsHTTPFixture((reviewed ? [response(body)] : []) + [response(#"{"name":"feature/a+b&c"}"#), response(body), response("", status: 303, location: "/queue/item/7/")])
        let client = JenkinsClient(transport: http)
        let contract = reviewed ? try await client.contract(connection: jenkins, token: "fixture", kind: .uiTests) : nil
        let owner = RemoteTestCoordinator(directory: directory, jenkins: client, gitlab: GitLabClient(transport: http), jenkinsToken: { _ in "fixture-j" }, gitlabToken: { _ in "fixture-g" })
        defer { owner.stop() }
        let requestID = UUID(), checkout = ProjectContext(path: "/private/tmp/fixture")
        let run = try await owner.submit(requestID: requestID, checkout: checkout, branch: "feature/a+b&c", parameters: .uiTests(.functional), jenkins: jenkins, gitlab: gitlab, reviewedContract: contract)
        #expect(run.status == "queued" && run.queueURL?.path == "/queue/item/7")
        #expect(run.branch == "feature/a+b&c")
        let repeated = try await owner.submit(requestID: requestID, checkout: checkout, branch: "feature/a+b&c", plan: .functional, jenkins: jenkins, gitlab: gitlab)
        #expect(repeated.id == run.id)
        let requests = await http.requests
        let post = try #require(requests.first { $0.httpMethod == "POST" })
        let items = URLComponents(string: "?" + String(decoding: try #require(post.httpBody), as: UTF8.self))?.queryItems
        #expect(items?.first { $0.name == "BRANCH" }?.value == "origin/feature/a+b&c")
        #expect(items?.first { $0.name == "TEST_PLAN" }?.value == "FUNCTIONAL")
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(requests.first { $0.url?.path.contains("repository/branches/") == true }?.url?.absoluteString.contains("branches/feature%2Fa%2Bb%26c") == true)
    }

    @Test(arguments: ["missing", "errors", "empty"]) @MainActor
    func invalidGitParameterValuesFailBeforeAdmissionAndPOST(scenario: String) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/MimicRun-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = try gitParameterContract(values: scenario == "empty" ? [] : ["origin/other"], errors: scenario == "errors" ? ["raw secret server error"] : [])
        let http = JenkinsHTTPFixture([response(#"{"name":"feature/a+b&c"}"#), response(body)])
        let owner = RemoteTestCoordinator(directory: directory, jenkins: JenkinsClient(transport: http), gitlab: GitLabClient(transport: http), jenkinsToken: { _ in "fixture" }, gitlabToken: { _ in "fixture" })
        let error: JenkinsConnectionError = scenario == "missing" ? .branchUnavailable : .branchValuesUnavailable
        await #expect(throws: error) {
            try await owner.submit(requestID: UUID(), checkout: ProjectContext(path: "/fixture"), branch: "feature/a+b&c", plan: .smoke, jenkins: jenkins, gitlab: gitlab)
        }
        #expect(owner.runs.isEmpty)
        #expect(await http.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("remote-runs.json").path))
    }

    @Test(arguments: [400, 422, 500]) @MainActor
    func submissionResponseKeepsSafeStatusAndNeverRetries(status: Int) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/MimicRun-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = JenkinsHTTPFixture([response(#"{"name":"feature/a+b&c"}"#), response(try gitParameterContract(values: ["origin/feature/a+b&c"])), response("raw secret server error", status: status)])
        let owner = RemoteTestCoordinator(directory: directory, jenkins: JenkinsClient(transport: http), gitlab: GitLabClient(transport: http), jenkinsToken: { _ in "fixture-j" }, gitlabToken: { _ in "fixture-g" })
        let requestID = UUID(), checkout = ProjectContext(path: "/fixture")
        let run = try await owner.submit(requestID: requestID, checkout: checkout, branch: "feature/a+b&c", plan: .smoke, jenkins: jenkins, gitlab: gitlab)
        #expect(run.status == (status == 500 ? "unknown" : "submissionFailed"))
        #expect(run.submissionHTTPStatus == status && run.updatedAt != nil)
        #expect(run.error == (status == 500 ? "mcp.submit.serverUnknown" : "jenkins.error.submissionRejected"))
        _ = try await owner.submit(requestID: requestID, checkout: checkout, branch: "feature/a+b&c", plan: .smoke, jenkins: jenkins, gitlab: gitlab)
        #expect(await http.requests.filter { $0.httpMethod == "POST" }.count == 1)
        let resumed = RemoteTestCoordinator(directory: directory, jenkinsToken: { _ in "fixture" }, gitlabToken: { _ in "fixture" })
        #expect(resumed.runs.first?.submissionHTTPStatus == status)
        resumed.resume(); resumed.stop()
        let disk = try String(contentsOf: directory.appendingPathComponent("remote-runs.json"), encoding: .utf8)
        #expect(!disk.contains("raw secret") && !disk.contains("fixture-j") && !disk.contains("fixture-g"))
    }

    @Test(arguments: ["/login", "https://foreign.example.invalid/queue/item/7/", "/arbitrary/item/7/", "/queue/item/0/", "/queue/item/7/?token=secret"])
    func reusedQueueRedirectRequiresExactLocalQueue(location: String) async throws {
        let http = JenkinsHTTPFixture([response("", status: 303, location: location)])
        await #expect(throws: CIError.invalidResponse) {
            try await JenkinsClient(transport: http).submit(connection: jenkins, token: "fixture", branch: "origin/develop", plan: .smoke)
        }
    }
}

extension JenkinsMVPTests {
    @Test func expiredQueueRecoversByQueueIDAndNeverLatestBuild() async throws {
        let body = #"{"builds":[{"number":10,"url":"https://jenkins.example.invalid/job/ios_ui_tests_simulator/10/","queueId":8},{"number":9,"url":"https://jenkins.example.invalid/job/ios_ui_tests_simulator/9/","queueId":7}]}"#
        let http = JenkinsHTTPFixture([response(body)])
        let url = try await JenkinsClient(transport: http).buildURL(connection: jenkins, token: "fixture-token", queueURL: URL(string: "https://jenkins.example.invalid/queue/item/7/")!)
        #expect(url?.path.hasSuffix("/9") == true)
    }
}

// MARK: - Native connection check

extension JenkinsMVPTests {
    @Test(arguments: ["actions", "property"])
    func connectionCheckAcceptsBothParameterLayouts(section: String) async throws {
        let body = "{\"\(section)\":[{\"parameterDefinitions\":[{\"name\":\"BRANCH\"},{\"name\":\"TEST_PLAN\",\"choices\":[\"FULL\",\"FUNCTIONAL\",\"SMOKE\",\"STATS\"]}]}]}"
        let http = JenkinsHTTPFixture([response(body)])
        try await JenkinsClient(transport: http).check(connection: jenkins, token: "fixture-token")
        let request = try #require(await http.requests.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "tree" }?.value == "actions[parameterDefinitions[name,choices]],property[parameterDefinitions[name,choices]]")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
    }

    @Test func connectionCheckDistinguishesSchemaFromAuthentication() async throws {
        let missing = JenkinsHTTPFixture([response(#"{"actions":[{}]}"#)])
        await #expect(throws: JenkinsConnectionError.missingParameters) { try await JenkinsClient(transport: missing).check(connection: jenkins, token: "fixture-token") }
        let choices = JenkinsHTTPFixture([response(#"{"property":[{"parameterDefinitions":[{"name":"BRANCH"},{"name":"TEST_PLAN","choices":["SMOKE"]}]}]}"#)])
        await #expect(throws: JenkinsConnectionError.unsupportedPlans) { try await JenkinsClient(transport: choices).check(connection: jenkins, token: "fixture-token") }
        let forbidden = JenkinsHTTPFixture([response("", status: 403)])
        await #expect(throws: CIError.forbidden) { try await JenkinsClient(transport: forbidden).check(connection: jenkins, token: "fixture-token") }
        let malformed = JenkinsHTTPFixture([response("<html>Login</html>")])
        await #expect(throws: CIError.invalidResponse) { try await JenkinsClient(transport: malformed).check(connection: jenkins, token: "fixture-token") }
    }

    @Test @MainActor func nativeConnectionCheckTrimsPastedTokenAndUsesJenkinsErrors() async throws {
        let suite = "MimicJenkinsCheck-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let body = #"{"property":[{"parameterDefinitions":[{"name":"BRANCH"},{"name":"TEST_PLAN","choices":["SMOKE","FUNCTIONAL","STATS","FULL"]}]}]}"#
        let http = JenkinsHTTPFixture([response(body), response("", status: 403)])
        let settings = JenkinsSettings(defaults: defaults, credentials: JenkinsCheckCredentials(), client: JenkinsClient(transport: http))
        settings.username = " fixture-user "
        settings.enteredToken = " fixture-token\n"
        settings.check()
        for _ in 0 ..< 200 {
            if !settings.checking { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(settings.verified)
        let request = try #require(await http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("fixture-user:fixture-token".utf8).base64EncodedString())
        #expect(defaults.data(forKey: "jenkinsConnection") == nil)
        settings.check()
        for _ in 0 ..< 200 {
            if !settings.checking { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!settings.verified)
        #expect(settings.error == .transport(.forbidden))
        #expect(settings.error?.localizationKey == "jenkins.error.forbidden")
        #expect(JenkinsConnectionError.missingParameters.localizationKey == "jenkins.error.parameters")
    }
}


extension JenkinsMVPTests {
    @Test func remoteBranchUsesExactEncodedEndpointAndLiteralSearch() async throws {
        let http = JenkinsHTTPFixture([response(#"{"name":"feature/a+b&c"}"#), response(#"[{"name":"feature/a+b&c"}]"#)])
        let client = GitLabClient(transport: http)
        #expect(try await client.branchExists(connection: gitlab, branch: "feature/a+b&c", token: "fixture-token"))
        _ = try await client.branches(connection: gitlab, search: "a+b&c", token: "fixture-token")
        let requests = await http.requests
        #expect(requests[0].url?.absoluteString.contains("repository/branches/feature%2Fa%2Bb%26c") == true)
        let items = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "search" }?.value == "a+b&c")
    }
}
