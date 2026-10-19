// Created by Василий Маслов on 16.10.2026.
import Foundation
import Testing
@testable import MimicCore

private actor ServiceTransportProbe {
    var requests: [URLRequest] = []
    var active = 0
    var maximumActive = 0
    func send(_ request: URLRequest) async throws -> (Data, Int, String) {
        active += 1; maximumActive = max(active, maximumActive); requests.append(request)
        try await Task.sleep(for: .milliseconds(20)); active -= 1
        if request.url?.path == "/failure" { return (Data(#"{"success":false,"error":"rejected"}"#.utf8), 200, "application/json") }
        if request.url?.path == "/lost" { throw URLError(.networkConnectionLost) }
        return (Data(#"{"uid":"123","email":"fixture@example.test","password":"fixture-password","session":"fixture-session","code":"fixture-code"}"#.utf8), 200, "application/json")
    }
    func count() -> Int { requests.count }
    func maximum() -> Int { maximumActive }
    func first() -> URLRequest? { requests.first }
}

@MainActor @Suite(.serialized) struct ServiceToolTests {
    private let context = ServiceToolContext(checkout: "/fixture", profileRevision: "revision", namespace: "testing", appVersion: "456", sourceRevision: "confirmed")
    private func definition(path: String = "/create", method: String = "POST", usesUID: Bool = false, returnsUID: Bool = true) throws -> ServiceTool {
        try JSONDecoder().decode(ServiceTool.self, from: JSONSerialization.data(withJSONObject: [
            "id": "service", "title": "Service", "requiredFiles": ["marker"], "baseURLTemplate": "http://api.{namespace}.example.test",
            "source": ["panelID": "settings", "namespaceField": "target", "appVersionField": "version"], "mcpAllowed": true,
            "actions": [["id": "action", "title": "Action", "hint": "", "usesUID": usesUID, "returnsUID": returnsUID,
                         "variants": [["id": "default", "title": "Default", "method": method, "path": path, "fields": [
                            ["id": "email", "title": "Email", "kind": "text", "required": false, "defaultValue": "", "advanced": false, "secret": false],
                            ["id": "app_version", "title": "Version", "kind": "integer", "required": true, "defaultValue": "", "advanced": true, "secret": false, "source": "appVersion"],
                            ["id": "password", "title": "Password", "kind": "text", "required": false, "defaultValue": "", "advanced": true, "secret": true]
                         ]]]]]
        ]))
    }
    private func fixture(_ probe: ServiceTransportProbe) throws -> (ServiceToolCoordinator, UserDefaults, URL, String) {
        let suite = "ServiceToolTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        return (ServiceToolCoordinator(defaults: defaults, directory: directory, transport: { try await probe.send($0) }), defaults, directory, suite)
    }
    private func finish(_ coordinator: ServiceToolCoordinator, scope: String, id: UUID) async throws -> BridgeValue {
        for _ in 0..<300 {
            let result = coordinator.result(scope: scope, requestID: id)
            if result["phase"] != .string("pending") { return result }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Service request did not finish"); return .null
    }
    @Test func formEncodingSourceVersionAndFullEphemeralResult() async throws {
        let probe = ServiceTransportProbe(), (coordinator, defaults, directory, suite) = try fixture(probe)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let tool = try definition(), id = UUID(), scope = ServiceToolCoordinator.scope(owner: "chat", tool: tool.id, context: context)
        try tool.validate()
        _ = try coordinator.start(owner: "chat", tool: tool, context: context, actionID: "action", variantID: "default", uid: "", values: ["email": "a+b&x=1@example.test", "password": "p+&=value"], requestID: id, stillCurrent: { true })
        let result = try await finish(coordinator, scope: scope, id: id)
        #expect(result["phase"] == .string("success")); #expect(result["data"]["session"] == .string("fixture-session"))
        let request = try #require(await probe.first()), body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("app_version=456")); #expect(body.contains("%2B")); #expect(body.contains("%26")); #expect(body.contains("%3D"))
        #expect(coordinator.state(scope: scope)["uid"] == .string("123"))
        let stored = defaults.dictionaryRepresentation().values.compactMap { ($0 as? Data).map { String(decoding: $0, as: UTF8.self) } }.joined()
        #expect(!stored.contains("fixture-session")); #expect(!stored.contains("fixture-password")); #expect(!stored.contains("fixture-code"))
        let receipts = String(decoding: try Data(contentsOf: directory.appendingPathComponent("receipts.json")), as: UTF8.self)
        #expect(!receipts.contains("p+&=value")); #expect(!receipts.contains("email"))
    }
    @Test func duplicateAndRestartNeverReplayAndOtherOwnerCannotRead() async throws {
        let probe = ServiceTransportProbe(), (coordinator, defaults, directory, suite) = try fixture(probe)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let tool = try definition(), id = UUID(), scope = ServiceToolCoordinator.scope(owner: "chat", tool: tool.id, context: context)
        for _ in 0..<2 { _ = try coordinator.start(owner: "chat", tool: tool, context: context, actionID: "action", variantID: "default", uid: "", values: [:], requestID: id, stillCurrent: { true }) }
        _ = try await finish(coordinator, scope: scope, id: id)
        #expect(await probe.count() == 1)
        #expect(throws: ServiceToolError.duplicate) { try coordinator.start(owner: "other", tool: tool, context: context, actionID: "action", variantID: "default", uid: "", values: [:], requestID: id, stillCurrent: { true }) }
        #expect(coordinator.result(scope: "foreign", requestID: id)["phase"] == .string("unavailable"))
        let restored = ServiceToolCoordinator(defaults: defaults, directory: directory, transport: { try await probe.send($0) })
        #expect(try restored.start(owner: "chat", tool: tool, context: context, actionID: "action", variantID: "default", uid: "", values: [:], requestID: id, stillCurrent: { true })["phase"] == .string("unknown"))
        #expect(await probe.count() == 1)
    }
    @Test func sameUserSerializesAcrossChatsAndBusinessFailureIsNotSuccess() async throws {
        let probe = ServiceTransportProbe(), (coordinator, defaults, directory, suite) = try fixture(probe)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let tool = try definition(path: "/failure", usesUID: true, returnsUID: false)
        let a = UUID(), b = UUID()
        _ = try coordinator.start(owner: "a", tool: tool, context: context, actionID: "action", variantID: "default", uid: "123", values: [:], requestID: a, stillCurrent: { true })
        _ = try coordinator.start(owner: "b", tool: tool, context: context, actionID: "action", variantID: "default", uid: "123", values: [:], requestID: b, stillCurrent: { true })
        let result = try await finish(coordinator, scope: ServiceToolCoordinator.scope(owner: "b", tool: tool.id, context: context), id: b)
        #expect(result["phase"] == .string("failed")); #expect(await probe.maximum() == 1)
    }
    @Test func unknownOutcomeIsNotRetriedAndNamespaceChangeDoesNotSelectUID() async throws {
        let probe = ServiceTransportProbe(), (coordinator, defaults, directory, suite) = try fixture(probe)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let tool = try definition(path: "/lost"), id = UUID(), scope = ServiceToolCoordinator.scope(owner: "chat", tool: tool.id, context: context)
        _ = try coordinator.start(owner: "chat", tool: tool, context: context, actionID: "action", variantID: "default", uid: "", values: [:], requestID: id, stillCurrent: { true })
        #expect(try await finish(coordinator, scope: scope, id: id)["phase"] == .string("unknown")); #expect(await probe.count() == 1)
        let next = try definition(), newID = UUID(); var current = true
        _ = try coordinator.start(owner: "new", tool: next, context: context, actionID: "action", variantID: "default", uid: "", values: [:], requestID: newID, stillCurrent: { current })
        current = false
        let otherScope = ServiceToolCoordinator.scope(owner: "new", tool: next.id, context: context)
        _ = try await finish(coordinator, scope: otherScope, id: newID)
        #expect(coordinator.state(scope: otherScope)["uid"] == .null)
    }
    @Test func draftsAndRecentAreOwnerScopedWithoutPersistedSecrets() throws {
        let probe = ServiceTransportProbe(), (coordinator, defaults, directory, suite) = try fixture(probe)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let tool = try definition(), scope = ServiceToolCoordinator.scope(owner: "a", tool: tool.id, context: context)
        try coordinator.save(scope: scope, tool: tool, uid: "123", drafts: ["action:default": ["email": "fixture@example.test", "password": "only-memory"]])
        #expect(coordinator.state(scope: scope)["drafts"]["action:default"]["password"] == .string("only-memory"))
        let restored = ServiceToolCoordinator(defaults: defaults, directory: directory)
        #expect(restored.state(scope: scope)["drafts"]["action:default"]["password"] == .null)
        #expect(restored.state(scope: ServiceToolCoordinator.scope(owner: "b", tool: tool.id, context: context))["uid"] == .null)
        #expect(throws: ServiceToolError.arguments) { try coordinator.save(scope: scope, tool: tool, uid: "123", drafts: ["action:default": ["arbitrary": "value"]]) }
    }
    @Test func activationRejectsTraversalAndConfigurationDoesNotExportRoutes() throws {
        let tool = try definition(); try tool.validate()
        #expect(tool.catalog["baseURLTemplate"] == .null)
        #expect(tool.catalog["actions"].array?.first?["variants"].array?.first?["path"] == .null)
        #expect(throws: (any Error).self) { try definition(path: "/../escape").validate() }
        #expect(throws: ServiceToolError.namespace) { try tool.endpoint(namespace: "bad.host") }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_SERVICE_PROFILE"] != nil)) func privateProfileHasEightActionsAndCompatibleSettings() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MIMIC_SERVICE_PROFILE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try ProfileStore(directory: directory).importArchive(URL(fileURLWithPath: path), requireInterface: true)
        #expect(snapshot.profile.serviceTools?.first?.actions.count == 8)
        #expect(snapshot.profile.panels?.first?.fields.count == 3)
    }
}
