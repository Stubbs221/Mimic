//
//  BuildAgentWorkflowTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct BuildAgentWorkflowTests {
    @MainActor private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildAgentWorkflow-" + UUID().uuidString)
        let suite = "BuildAgentWorkflow-" + UUID().uuidString
        let defaults: UserDefaults
        let builds: BuildCoordinator
        let model: TaskCoordinator
        let integration: MimicIntegration
        let project: ProjectContext
        var parameters: BuildParameters { .init(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") }
        func payload(_ parameters: BuildParameters) throws -> BridgeValue {
            var fields = try #require(BridgeValue.encode(parameters).object)
            fields["operation"] = nil
            return .object(fields)
        }

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Fixture"]] {
                try #require(EnvironmentInspector.capture("/usr/bin/git", arguments, directory: root.path).0 == 0)
            }
            project = try EnvironmentInspector.project(path: root.path, developerDirectory: "/fixture/Developer")
            builds = BuildCoordinator(directory: root.appendingPathComponent("storage"), helper: URL(fileURLWithPath: "/missing"), defaults: defaults, inspect: { $0 }, resolveDeveloper: { $0.developerDirectory! })
            model = TaskCoordinator(directory: root.appendingPathComponent("storage"), buildCoordinator: builds, defaults: defaults)
            model.projects = [project]; model.selectedProjectPath = project.path
            model.builds.schedule = { }
            let discovery = BuildDiscovery(inspect: { _, _, _ in
                var catalogue = BuildCatalogue(); catalogue.schemes = ["Fixture"]; catalogue.configurations = ["Debug"]
                catalogue.destinations = [.init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Fixture")]
                return catalogue
            })
            integration = MimicIntegration(model: model, defaults: defaults, discovery: discovery)
        }
        func cleanup() {
            model.stopAndExit(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func connectionBindingIsTransientAndCannotBorrowDesktopOrHostOwnership() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = UUID().uuidString, b = UUID().uuidString
        let unbound = try await fixture.integration.handle(.init(method: "get_state", clientSessionID: a))
        #expect(unbound["needsBinding"] == .bool(true) && unbound["context"] == .null)
        #expect(unbound["capabilities"]["buildWorkflowVersion"].integer == 1)
        let bound = try await fixture.integration.handle(.init(method: "bind_project", parameters: ["checkout": .string(fixture.root.path)], clientSessionID: a))
        #expect(bound["context"]["checkoutId"].string == fixture.root.path)
        #expect(fixture.model.selectedProjectPath == fixture.root.path)
        #expect(fixture.defaults.data(forKey: "panelWorkspaces") == nil)
        let other = try await fixture.integration.handle(.init(method: "get_state", clientSessionID: b))
        #expect(other["context"] == .null)
        await #expect(throws: MimicIntegration.IntegrationError.self) {
            try await fixture.integration.handle(.init(method: "claim_branch_switch", parameters: ["operationID": .string(UUID().uuidString)], clientSessionID: a))
        }
        _ = try await fixture.integration.handle(.init(method: "release_client_session", clientSessionID: a))
        let released = try await fixture.integration.handle(.init(method: "get_state", clientSessionID: a))
        #expect(released["context"] == .null)
        _ = try await fixture.integration.handle(.init(method: "bind_project", parameters: ["checkout": .string(fixture.root.path)], threadID: "host-chat"))
        #expect(PanelWorkspaceStore(defaults: fixture.defaults).load("host-chat").checkout == fixture.root.path)
    }

    @Test func readinessUsesMatchingDiscoveryAndNeverAdmitsWork() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = MimicIntegration.context(fixture.project)
        var arguments: [String: BridgeValue] = ["context": context, "operation": .string("build"), "parameters": try fixture.payload(fixture.parameters), "simulatorConfirmed": .bool(false)]
        #expect(try await fixture.integration.buildRequest(.init(method: "get_build_readiness", parameters: arguments))["status"] == .string("discoveryRequired"))
        let start = try await fixture.integration.buildRequest(.init(method: "start_build_configuration", parameters: ["context": context, "scheme": .string("Fixture"), "includeTestPlans": .bool(false)]))
        arguments["configurationQueryID"] = start["queryID"]
        for _ in 0..<100 {
            let status = try await fixture.integration.buildRequest(.init(method: "get_build_readiness", parameters: arguments))["status"]
            if status == .string("ready") { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(try await fixture.integration.buildRequest(.init(method: "get_build_readiness", parameters: arguments))["status"] == .string("ready"))
        #expect(fixture.builds.records.isEmpty)
        var parameters = fixture.parameters; parameters.configuration = "Unknown"
        arguments["parameters"] = try fixture.payload(parameters)
        #expect(try await fixture.integration.buildRequest(.init(method: "get_build_readiness", parameters: arguments))["status"] == .string("blocked"))
        fixture.model.projects[0].commit = "changed"
        #expect(try await fixture.integration.buildRequest(.init(method: "get_build_readiness", parameters: arguments))["blockers"].array?.first?["code"] == .string("context"))
        #expect(fixture.builds.records.isEmpty)
    }

    @Test func workflowIdempotencyWaitTimeoutAndObserverCancellationAreIndependent() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let id = UUID(), workflow = UUID().uuidString
        let context = MimicIntegration.context(fixture.project)
        let arguments: [String: BridgeValue] = ["context": context, "requestID": .string(id.uuidString), "parameters": try fixture.payload(fixture.parameters), "simulatorConfirmed": .bool(false), "workflowID": .string(workflow)]
        let request = MimicBridgeRequest(method: "build_project", parameters: arguments, clientName: "Claude Code")
        let first = try await fixture.integration.buildRequest(request)
        let second = try await fixture.integration.buildRequest(request)
        #expect(first["id"] == second["id"] && first["workflowID"] == .string(workflow))
        #expect(first["source"] == .string("Claude Code") && fixture.builds.records.count == 1)
        var changed = arguments; changed["workflowID"] = .string(UUID().uuidString)
        await #expect(throws: BuildError.duplicate) { try await fixture.integration.buildRequest(.init(method: "build_project", parameters: changed)) }
        let timeout = try await fixture.integration.buildRequest(.init(method: "wait_build_activity", parameters: ["activityID": .string(id.uuidString), "timeoutMs": .number(0)]))
        #expect(timeout["timedOut"] == .bool(true) && fixture.builds.records.first?.status == .queued)
        let observer = Task { try await fixture.builds.waitForActivity(id, afterRevision: first["revision"].integer, timeoutMs: 25_000) }
        observer.cancel()
        await #expect(throws: CancellationError.self) { try await observer.value }
        #expect(fixture.builds.records.first?.status == .queued)
        fixture.builds.cancel(id)
        let completed = try await fixture.builds.waitForActivity(id, afterRevision: first["revision"].integer, timeoutMs: 25_000)
        #expect(completed.activity.status == .cancelled && !completed.timedOut)
        #expect((completed.activity.stateRevision ?? 0) > (first["revision"].integer ?? 0))
        let result = try await fixture.integration.buildRequest(.init(method: "get_build_result", parameters: ["activityID": .string(id.uuidString)]))
        #expect(result["activity"]["status"] == .string("cancelled") && result["outputUnavailable"] == .bool(true))
    }
}
