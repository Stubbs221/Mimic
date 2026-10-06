//
//  ProfileRemoteTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
@testable import MimicCore

private actor ProfileHTTPFixture: CIHTTPTransport {
    var replies: [CIHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [CIHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw CIError.network }
        return replies.removeFirst()
    }
}

@Suite(.serialized)
@MainActor struct ProfileRemoteTests {
    private func snapshot(_ root: URL) throws -> ProfileSnapshot {
        let json = #"{"schemaVersion":1,"id":"fixture","version":"1","title":"Fixture","requiredFiles":[],"services":{"jenkinsURL":"https://jenkins.example.invalid"},"actions":[{"id":"ci","title":"CI","presentation":"ci","mcpAllowed":true,"requiresXcodeQuit":false,"requiredFiles":[],"requiredTools":[],"steps":[],"remote":{"job":"team/custom","branchParameter":"REF","tracking":"jenkinsOnly"},"parameters":[{"id":"branch","title":"Branch","kind":"branch","defaultValue":"main","required":true},{"id":"FAST","title":"Fast","kind":"boolean","defaultValue":"true","required":true}]}]}"#
        let profile = try JSONDecoder().decode(MimicProfile.self, from: Data(json.utf8))
        return ProfileSnapshot(profile: profile, revision: "fixture", directory: root.path)
    }
    @Test func namedJobPinsQueueAndDoesNotResubmitDuplicateOrUnknownPOST() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"{"property":[{"parameterDefinitions":[{"name":"REF","_class":"hudson.model.StringParameterDefinition","defaultParameterValue":{"value":"main"}},{"name":"FAST","_class":"hudson.model.BooleanParameterDefinition","defaultParameterValue":{"value":true}}]}]}"#
        let http = ProfileHTTPFixture([CIHTTPResponse(data: Data(json.utf8), status: 200), CIHTTPResponse(data: Data(), status: 201, location: "https://jenkins.example.invalid/queue/item/77/")])
        let connection = JenkinsConnection(baseURL: URL(string: "https://jenkins.example.invalid")!, username: "fixture")
        let model = ProfileRemoteCoordinator(directory: root, jenkins: JenkinsClient(transport: http), gitlab: GitLabClient(transport: http), jenkinsToken: { _ in "fixture-token" }, gitlabToken: { _ in "fixture-token" })
        let snapshot = try snapshot(root), execution = ProfileExecution(snapshot: snapshot, actionID: "ci", parameters: ["branch": "main", "FAST": "false"])
        let id = UUID(), project = ProjectContext(path: root.path, branch: "main", commit: "fixture-sha")
        let first = try await model.submit(id: id, checkout: project, execution: execution, jenkins: connection, gitlab: nil, validate: {})
        model.stop()
        let second = try await model.submit(id: id, checkout: project, execution: execution, jenkins: connection, gitlab: nil, validate: {})
        #expect(first.id == second.id); #expect(first.queueURL?.path == "/queue/item/77")
        let requests = await http.requests
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
        let post = try #require(requests.first { $0.httpMethod == "POST" })
        #expect(post.url?.path == "/job/team/job/custom/buildWithParameters")
        #expect(String(decoding: post.httpBody ?? Data(), as: UTF8.self).contains("FAST=false"))
        #expect(String(decoding: post.httpBody ?? Data(), as: UTF8.self).contains("REF=main"))
        #expect(!String(decoding: try Data(contentsOf: root.appendingPathComponent("profile-remote-runs.json")), as: UTF8.self).contains("fixture-token"))
        let unknownHTTP = ProfileHTTPFixture([CIHTTPResponse(data: Data(json.utf8), status: 200)])
        let unknown = ProfileRemoteCoordinator(directory: root.appendingPathComponent("unknown"), jenkins: JenkinsClient(transport: unknownHTTP), gitlab: GitLabClient(transport: unknownHTTP), jenkinsToken: { _ in "fixture-token" }, gitlabToken: { _ in "fixture-token" })
        let result = try await unknown.submit(id: id, checkout: project, execution: execution, jenkins: connection, gitlab: nil, validate: {})
        #expect(result.status == "unknown")
        _ = try await unknown.submit(id: id, checkout: project, execution: execution, jenkins: connection, gitlab: nil, validate: {})
        #expect(await unknownHTTP.requests.count == 2)
    }
    @Test func changedContractAndWrongBuildURLFailBeforeMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshot = try snapshot(root), action = try #require(snapshot.profile.actions.first)
        let contract = ProfileRemoteContract(fields: ["FAST": ProfileRemoteField(defaultValue: "true", choices: [], boolean: true)], gitBranch: false, branchValues: nil)
        #expect(throws: (any Error).self) { try contract.wireParameters(["branch": "main", "FAST": "maybe"], action: action, branch: "main") }
        let http = ProfileHTTPFixture([]), client = JenkinsClient(transport: http)
        let connection = JenkinsConnection(baseURL: URL(string: "https://jenkins.example.invalid")!, username: "fixture")
        await #expect(throws: (any Error).self) { try await client.profileBuild(connection: connection, token: "fixture-token", url: URL(string: "https://jenkins.example.invalid/job/unrelated/7/")!, job: "team/custom") }
        #expect(await http.requests.isEmpty)
    }
    @Test func betaSendsReviewedDefaultsOnceAndRejectsChangedServerDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Mimic11/profile.json")
        let profile = try JSONDecoder().decode(MimicProfile.self, from: Data(contentsOf: fixture))
        let snapshot = ProfileSnapshot(profile: profile, revision: "fixture", directory: root.path)
        let execution = try snapshot.execution(role: .beta, values: [.branch: "main", .target: "App", .rebase: "main", .upload: "FALSE"]), action = try #require(execution.action)
        func reply(upload: String) throws -> CIHTTPResponse {
            let definitions: [[String: Any]] = [["name": "REF", "_class": "hudson.model.StringParameterDefinition", "defaultParameterValue": ["value": "main"]]] + action.parameters.filter { $0.kind != .branch }.map { parameter in
                ["name": parameter.id, "_class": parameter.kind == .choice ? "hudson.model.ChoiceParameterDefinition" : "hudson.model.StringParameterDefinition", "choices": parameter.choices ?? [], "defaultParameterValue": ["value": parameter.id == "input_beta_upload" ? upload : parameter.defaultValue]]
            }
            return CIHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["property": [["parameterDefinitions": definitions]]]), status: 200)
        }
        let connection = JenkinsConnection(baseURL: URL(string: "https://jenkins.example.invalid")!, username: "fixture"), project = ProjectContext(path: root.path, branch: "main")
        let http = ProfileHTTPFixture([try reply(upload: "FALSE"), try reply(upload: "FALSE"), CIHTTPResponse(data: Data(), status: 201, location: "/queue/item/88/")])
        let model = ProfileRemoteCoordinator(directory: root, jenkins: JenkinsClient(transport: http), gitlab: GitLabClient(transport: http), jenkinsToken: { _ in "fixture" }, gitlabToken: { _ in "fixture" })
        let reviewed = try await model.contract(action: action, connection: connection), id = UUID()
        let run = try await model.submit(id: id, checkout: project, execution: execution, jenkins: connection, gitlab: nil, reviewed: reviewed, validate: {}); model.stop()
        #expect(run.status == "queued")
        _ = try await model.submit(id: id, checkout: project, execution: execution, jenkins: connection, gitlab: nil, reviewed: reviewed, validate: {})
        let requests = await http.requests, post = try #require(requests.first { $0.httpMethod == "POST" })
        let body = String(decoding: post.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("input_beta_target=App") && body.contains("input_beta_upload=FALSE") && body.contains("input_beta_rebase=main"))
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
        let changedHTTP = ProfileHTTPFixture([try reply(upload: "TRUE")])
        let changed = ProfileRemoteCoordinator(directory: root.appendingPathComponent("changed"), jenkins: JenkinsClient(transport: changedHTTP), gitlab: GitLabClient(transport: changedHTTP), jenkinsToken: { _ in "fixture" }, gitlabToken: { _ in "fixture" })
        await #expect(throws: JenkinsConnectionError.contractChanged) { try await changed.submit(id: UUID(), checkout: project, execution: execution, jenkins: connection, gitlab: nil, reviewed: reviewed, validate: {}) }
        #expect(changed.runs.isEmpty); #expect(await changedHTTP.requests.allSatisfy { $0.httpMethod != "POST" })
    }
}
