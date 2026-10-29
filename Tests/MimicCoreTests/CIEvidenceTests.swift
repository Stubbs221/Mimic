//
//  CIEvidenceTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import Testing
@testable import MimicCore

private actor EvidenceHTTPFixture: CIHTTPTransport {
    var requests: [URLRequest] = []
    let partial: Bool
    init(partial: Bool = false) { self.partial = partial }
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        requests.append(request)
        let path = request.url!.path, query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let page = query.first { $0.name == "page" }?.value
        let body: String, next: String?
        if path.hasSuffix("/jobs") {
            #expect(query.first { $0.name == "include_retried" }?.value == "true")
            if page == "2" { if partial { return .init(data: Data(), status: 403) }; body = #"[{"id":2,"name":"test: [other]","stage":"test","status":"success","allow_failure":false,"web_url":"https://ci.example.invalid/jobs/2"}]"#; next = nil }
            else { body = #"[{"id":1,"name":"test: [original]","stage":"test","status":"failed","allow_failure":false,"failure_reason":"script_failure","web_url":"https://ci.example.invalid/jobs/1","runner_manager":{"version":"fixture-runner","platform":"darwin","architecture":"arm64"}}]"#; next = "2" }
        } else if path.hasSuffix("/test_report_summary") { body = #"{"test_suites":[{"name":"Suite","build_ids":[1]}]}"#; next = nil }
        else if path.hasSuffix("/test_report") { body = #"{"test_suites":[{"name":"Suite","test_cases":[{"name":"testA","classname":"Suite","status":"failed","system_output":"DO-NOT-RETAIN","stack_trace":"DO-NOT-RETAIN"}]}]}"#; next = nil }
        else if path.hasSuffix("/bridges") { body = "[]"; next = nil }
        else { body = #"{"id":7,"project_id":9,"status":"failed","sha":"pinned","ref":"feature/fixture","web_url":"https://ci.example.invalid/pipelines/7"}"#; next = nil }
        return .init(data: Data(body.utf8), status: 200, nextPage: next)
    }
}

/// Independent structured endpoints exercise bounded graph traversal without a GitLab account.
actor EvidenceGraphFixture: CIHTTPTransport {
    enum Mode: String, CaseIterable, Sendable { case child, cycle, ambiguous, rateLimited, empty, depth, budget }
    let mode: Mode
    var requests: [URLRequest] = []
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        requests.append(request)
        let components = request.url!.path.split(separator: "/"), marker = components.firstIndex(of: "pipelines")!
        let pipeline = Int(components[marker + 1])!, endpoint = components.last!
        let job = pipeline * 10 + 1
        let body: Any
        switch endpoint {
        case "jobs":
            body = [["id": job, "name": "matrix: [arm64]", "stage": "test", "status": "failed", "allow_failure": false],
                    ["id": job + 1, "name": "matrix: [arm64]", "stage": "test", "status": "success", "allow_failure": false]]
        case "test_report_summary":
            if mode == .rateLimited { return .init(data: Data(), status: 429) }
            body = ["test_suites": mode == .empty ? [] : mode == .ambiguous ? [["name": "Suite", "build_ids": [job]], ["name": "Suite", "build_ids": [job + 1]]] : [["name": "Suite", "build_ids": [job]]]]
        case "test_report":
            body = ["test_suites": mode == .empty ? [] : [["name": "Suite", "test_cases": [["classname": "Suite", "name": "testFailure", "status": "failed"]]]]]
        case "bridges":
            let children: [Int]
            switch mode {
            case .child: children = pipeline == 7 ? [8] : []
            case .cycle: children = pipeline == 7 ? [8] : [7]
            case .depth: children = [pipeline + 1]
            case .budget: children = pipeline == 7 ? Array(8...60) : []
            default: children = []
            }
            body = children.map { ["id": $0 + 1000, "name": "child", "status": "failed", "allow_failure": false, "downstream_pipeline": ["id": $0, "project_id": 9]] as [String: Any] }
        default:
            body = ["id": pipeline, "project_id": 9, "status": "failed", "sha": pipeline == 7 ? "pinned" : "child-sha", "ref": "feature/fixture", "web_url": "https://ci.example.invalid/pipelines/\(pipeline)"]
        }
        return .init(data: try JSONSerialization.data(withJSONObject: body), status: 200)
    }
}

struct CIEvidenceTests {
    private func snapshot(connection: GitLabConnection) -> CIAnalysisSnapshot {
        let pipeline = CIPipeline(id: 7, status: "failed", sha: "pinned", ref: "feature/fixture", webURL: connection.baseURL, createdAt: nil, projectID: 9)
        let context = CIContext(project: .init(path: "/fixture"), connection: connection)
        return .init(summary: .init(entry: .init(pipeline: pipeline), context: context, accountID: 1, checks: nil, updatedAt: nil, stale: false), connection: connection)
    }
    @Test func paginationAndStructuredReportsRetainProvenanceWithoutLogs() async throws {
        let connection = GitLabConnection(baseURL: URL(string: "https://ci.example.invalid")!, projectID: 9, projectPath: "fixture/app"), transport = EvidenceHTTPFixture()
        let snapshot = snapshot(connection: connection)
        let evidence = try await GitLabClient(transport: transport).evidence(snapshot: snapshot, connection: connection, token: "fixture")
        #expect(evidence.complete && evidence.selectedSHA == "pinned")
        #expect(evidence.items.filter { $0.kind == "job" }.count == 2)
        #expect(evidence.items.filter { $0.kind == "test" }.count == 1)
        #expect(evidence.items.first { $0.kind == "job" }?.facts["retryRelationship"] == .string("unknown"))
        #expect(evidence.items.first { $0.kind == "job" }?.facts["xcode"] == .null)
        let bytes = try JSONEncoder().encode(evidence)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("DO-NOT-RETAIN"))
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" && !$0.url!.path.contains("trace") && !$0.url!.path.contains("retry") && !$0.url!.path.contains("latest") })
    }
    @Test func partialPageKeepsKnownFailureAndCannotClaimCompleteness() async throws {
        let connection = GitLabConnection(baseURL: URL(string: "https://ci.example.invalid")!, projectID: 9, projectPath: "fixture/app"), transport = EvidenceHTTPFixture(partial: true)
        let result = try await GitLabClient(transport: transport).evidence(snapshot: snapshot(connection: connection), connection: connection, token: "fixture")
        #expect(!result.complete && result.sources.contains { $0.error == "forbidden" })
        #expect(result.items.contains { $0.kind == "job" && $0.facts["status"] == .string("failed") })
    }
    @Test func snapshotPersistsOriginalIdentity() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = GitLabConnection(baseURL: URL(string: "https://ci.example.invalid")!, projectID: 9, projectPath: "fixture/app"), store = CIAnalysisSnapshotStore(root: root)
        let value = snapshot(connection: connection); try store.save(value)
        #expect(try store.load(value.taskID).connection == connection)
        #expect(value.prompt(fragment: value.text, comment: "").contains(value.taskID.uuidString))
    }
    @Test(arguments: EvidenceGraphFixture.Mode.allCases) func graphBoundsAndUnknownRelationships(mode: EvidenceGraphFixture.Mode) async throws {
        let connection = GitLabConnection(baseURL: URL(string: "https://ci.example.invalid")!, projectID: 9, projectPath: "fixture/app"), transport = EvidenceGraphFixture(mode)
        let result = try await GitLabClient(transport: transport).evidence(snapshot: snapshot(connection: connection), connection: connection, token: "fixture")
        #expect(result.complete == (mode == .child))
        #expect(result.items.filter { $0.kind == "pipeline" }.count <= 50)
        let job = try #require(result.items.first { $0.kind == "job" })
        #expect(job.facts["status"] == .string("failed") && job.facts["retryRelationship"] == .string("unknown"))
        #expect(job.facts["retryCandidates"] == .array([.number(72)]))
        switch mode {
        case .child: #expect(result.items.contains { $0.pipelineID == 8 && $0.kind == "test" })
        case .cycle, .depth, .budget: #expect(result.sources.contains { $0.error == "graphBudgetOrCycle" })
        case .ambiguous:
            let suite = try #require(result.items.first { $0.kind == "suite" })
            #expect(suite.facts["jobRelationship"] == .string("unknown") && suite.facts["jobCandidates"] == .array([.number(71), .number(72)]))
            #expect(!result.items.contains { $0.kind == "test" })
        case .rateLimited: #expect(result.sources.contains { $0.error == "rateLimited" })
        case .empty: #expect(result.sources.contains { $0.error == "emptyReport" })
        }
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" && !$0.url!.path.contains("latest") && !$0.url!.path.contains("trace") })
    }
}
