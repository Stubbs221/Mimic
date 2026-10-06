//
//  GitLabTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation
import Testing
@testable import MimicCore

private actor HTTPFixture: CIHTTPTransport {
    private var responses: [CIHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [CIHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        self.requests.append(request)
        guard !self.responses.isEmpty else { throw CIError.network }
        return self.responses.removeFirst()
    }
}

private func http(_ body: String, status: Int = 200, nextPage: String? = nil) -> CIHTTPResponse {
    CIHTTPResponse(data: Data(body.utf8), status: status, nextPage: nextPage, retryAfter: status == 429 ? 120 : nil)
}

struct GitLabTests {
    private let connection = GitLabConnection(baseURL: URL(string: "https://gitlab.example.invalid")!, projectID: 272, projectPath: "team/mobile")
    private let pipelineJSON = """
        [{"id":1,"status":"success","sha":"other-sha","ref":"feature/a&b#c","web_url":"https://gitlab.example.invalid/team/mobile/-/pipelines/1","created_at":"2026-10-02T10:00:00.123Z"}]
        """

    @Test
    func branchEncodingAndHeaderOnlyToken() async throws {
        let fixture = HTTPFixture([http(pipelineJSON)]), client = GitLabClient(transport: fixture)
        let result = try await client.pipelines(connection: self.connection, branch: "feature/a&b#c", token: "fixture-token")
        #expect(result.first?.status == "success")
        #expect(result.first?.sha == "other-sha")
        #expect(result.first?.createdAt != nil)
        let request = try #require(await fixture.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "fixture-token")
        #expect(request.url?.absoluteString.contains("fixture-token") == false)
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "ref" }?.value == "feature/a&b#c")
        #expect(query.first { $0.name == "per_page" }?.value == "5")
    }

    @Test func commitRetainsOnlyTitleAndRequiresExactSHA() async throws {
        let fixture = HTTPFixture([http(#"{"id":"exact-sha","title":"Commit title","message":"private full message","author_email":"private@example.invalid"}"#), http(#"{"id":"different","title":"Wrong commit"}"#)])
        let client = GitLabClient(transport: fixture)
        let commit = try await client.commit(connection: self.connection, sha: "exact-sha", token: "fixture-token")
        #expect(commit.id == "exact-sha" && commit.title == "Commit title")
        await #expect(throws: CIError.invalidResponse) { try await client.commit(connection: self.connection, sha: "exact-sha", token: "fixture-token") }
        let requests = await fixture.requests
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && $0.url?.path.hasSuffix("repository/commits/exact-sha") == true })
        #expect(requests.first?.url?.query == "stats=false")
    }

    @Test
    func projectPathIsOneEncodedSegment() async throws {
        let fixture = HTTPFixture([http("{\"id\":272,\"path_with_namespace\":\"team/mobile\"}")])
        let project = try await GitLabClient(transport: fixture).project(baseURL: self.connection.baseURL, path: "team/mobile", token: "fixture-token")
        #expect(project.id == 272)
        let request = try #require(await fixture.requests.first)
        #expect(request.url?.absoluteString.contains("projects/ios%2Fios") == true)
    }

    @Test
    func paginatedJobsAndChildStatusAreKeptSeparate() async throws {
        let job = "{\"id\":1,\"name\":\"unit-tests\",\"stage\":\"test\",\"status\":\"manual\",\"allow_failure\":true,\"web_url\":\"https://gitlab.example.invalid/jobs/1\"}"
        let bridge = """
            [{"id":4,"name":"performance","status":"success","web_url":"https://gitlab.example.invalid/jobs/4","downstream_pipeline":{"id":5,"status":"failed","sha":"child-sha","ref":"main","web_url":"https://gitlab.example.invalid/pipelines/5"}}]
            """
        let fixture = HTTPFixture([http("[\(job)]", nextPage: "2"), http("[]"), http(bridge)])
        let details = try await GitLabClient(transport: fixture).details(connection: self.connection, pipelineID: 1, token: "fixture-token")
        #expect(details.jobs.count == 1)
        #expect(details.jobs.first?.status == "manual")
        #expect(details.jobs.first?.allowFailure == true)
        #expect(details.bridges.first?.status == "success")
        #expect(details.bridges.first?.downstreamPipeline?.status == "failed")
        #expect(details.bridgeError == nil)
        #expect(await fixture.requests.count == 3)
    }

    @Test
    func unavailableBridgesPreserveJobsAndShowError() async throws {
        let fixture = HTTPFixture([http("[]"), http("{}", status: 403)])
        let details = try await GitLabClient(transport: fixture).details(connection: self.connection, pipelineID: 1, token: "fixture-token")
        #expect(details.bridgeError == .forbidden)
        #expect(details.bridges.isEmpty)
    }

    @Test
    func bridgeRouteSupportsNewAndOlderGitLab() async throws {
        let fixture = HTTPFixture([http("[]"), http("{}", status: 404), http("[]")])
        let details = try await GitLabClient(transport: fixture).details(connection: self.connection, pipelineID: 1, token: "fixture-token")
        #expect(details.bridgeError == nil)
        #expect(await fixture.requests.last?.url?.path.hasSuffix("/trigger_jobs") == true)
    }

    @Test(arguments: [301, 401, 403, 404, 429, 500])
    func errorsDoNotDecodeAsSuccess(status: Int) async {
        let fixture = HTTPFixture([http("secret-looking-error-body", status: status)])
        let expected: CIError = switch status {
        case 301,
             401: .authentication
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited(120)
        default: .server
        }
        await #expect(throws: expected) { try await GitLabClient(transport: fixture).pipelines(connection: connection, branch: "main", token: "fixture-token") }
    }

    @Test
    func networkMalformedResponseAndEmptyHistory() async throws {
        await #expect(throws: CIError.network) { try await GitLabClient(transport: HTTPFixture([])).pipelines(connection: connection, branch: "main", token: "fixture-token") }
        await #expect(throws: CIError.invalidResponse) { try await GitLabClient(transport: HTTPFixture([http("<html>login</html>")])).pipelines(connection: connection, branch: "main", token: "fixture-token") }
        let empty = try await GitLabClient(transport: HTTPFixture([http("[]")])).pipelines(connection: self.connection, branch: "main", token: "fixture-token")
        #expect(empty.isEmpty)
    }

    @Test(arguments: ["http://gitlab.example.invalid", "https://user:pass@gitlab.example.invalid", "https://gitlab.example.invalid?token=x", "https://gitlab.example.invalid#fragment", "bad url"])
    func configurationRejectsCredentialURLs(address: String) {
        #expect(throws: CIError.invalidConfiguration) { try GitLabClient.baseURL(address) }
    }

    @Test
    func unknownStatusAndWholeSecondDatesRemainReadable() async throws {
        let value = self.pipelineJSON.replacingOccurrences(of: "success", with: "future_status").replacingOccurrences(of: ".123", with: "")
        let result = try await GitLabClient(transport: HTTPFixture([http(value)])).pipelines(connection: self.connection, branch: "main", token: "fixture-token")
        #expect(result.first?.status == "future_status")
        #expect(result.first?.createdAt != nil)
    }

    @Test
    func cyclicPaginationCannotHangOrShowPartialSuccess() async {
        let fixture = HTTPFixture([http("[]", nextPage: "1")])
        await #expect(throws: CIError.invalidResponse) { try await GitLabClient(transport: fixture).details(connection: connection, pipelineID: 1, token: "fixture-token") }
    }
}

// MARK: - Personal CI REST contracts

extension GitLabTests {
    @Test func currentUserAndMemberSearchUseHeaderOnlyCredentials() async throws {
        let fixture = HTTPFixture([http("{\"id\":7,\"username\":\"vmaslov\",\"name\":\"Василий Маслов\",\"email\":\"private@example.invalid\"}"),
            http("[{\"id\":8,\"username\":\"colleague\",\"name\":\"Коллега\"}]")])
        let client = GitLabClient(transport: fixture)
        let owner = try await client.currentUser(connection: self.connection, token: "fixture-token")
        let users = try await client.users(connection: self.connection, search: "Коллега & name", token: "fixture-token")
        #expect(owner.id == 7 && users.first?.id == 8)
        let requests = await fixture.requests
        #expect(requests[0].url?.path.hasSuffix("/user") == true)
        #expect(requests[1].url?.path.hasSuffix("/projects/272/users") == true)
        let searchURL = try #require(requests[1].url)
        #expect(URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "search" }?.value == "Коллега & name")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "fixture-token" && $0.url?.absoluteString.contains("fixture-token") == false })
        #expect(!String(decoding: try JSONEncoder().encode(owner), as: UTF8.self).contains("private@example.invalid"))
    }

    @Test func projectPageEncodesInitiatorAndExplicitContinuation() async throws {
        let fixture = HTTPFixture([http(self.pipelineJSON, nextPage: "3"), http("[]")])
        let client = GitLabClient(transport: fixture)
        let page = try await client.pipelinePage(connection: self.connection, username: "name.with+symbols", page: 2, perPage: 5, token: "fixture-token")
        #expect(page.nextPage == 3)
        _ = try await client.pipelinePage(connection: self.connection, username: nil, page: 3, perPage: 100, token: "fixture-token")
        let requests = await fixture.requests
        let firstURL = try #require(requests[0].url)
        let query = try #require(URLComponents(url: firstURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "username" }?.value == "name.with+symbols")
        #expect(!query.contains { $0.name == "ref" })
        #expect(query.first { $0.name == "page" }?.value == "2")
        #expect(query.first { $0.name == "order_by" }?.value == "id")
        let unfilteredURL = try #require(requests[1].url)
        #expect(URLComponents(url: unfilteredURL, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "username" } == false)
    }

    @Test(arguments: ["1", "bad", "0"])
    func personalPageRejectsInvalidContinuation(next: String) async {
        let fixture = HTTPFixture([http("[]", nextPage: next)])
        await #expect(throws: CIError.invalidResponse) {
            try await GitLabClient(transport: fixture).pipelinePage(connection: self.connection, username: nil, page: 1, perPage: 100, token: "fixture-token")
        }
    }

    @Test(arguments: [401, 403, 429])
    func personalIdentityAndFeedKeepAuthorizationAndRateErrors(status: Int) async {
        let expected: CIError = status == 401 ? .authentication : status == 403 ? .forbidden : .rateLimited(120)
        await #expect(throws: expected) { try await GitLabClient(transport: HTTPFixture([http("{}", status: status)])).currentUser(connection: self.connection, token: "fixture-token") }
        await #expect(throws: expected) { try await GitLabClient(transport: HTTPFixture([http("{}", status: status)])).pipelinePage(connection: self.connection, username: "vmaslov", page: 1, perPage: 5, token: "fixture-token") }
    }
}
