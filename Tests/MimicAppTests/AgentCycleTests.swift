//
//  AgentCycleTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct AgentCycleTests {
    @MainActor private struct Fixture {
        let root: URL
        let checkout: URL
        let defaults: UserDefaults
        let suite: String
        let builds: BuildCoordinator
        let model: TaskCoordinator
        let integration: MimicIntegration
        let project: ProjectContext
        var parameters: BuildParameters { .init(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") }
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AgentCycle-" + UUID().uuidString)
            checkout = root.appendingPathComponent("checkout"); suite = "AgentCycle-" + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: suite))
            try FileManager.default.createDirectory(at: checkout.appendingPathComponent("Fixture.xcodeproj"), withIntermediateDirectories: true)
            try Data("one".utf8).write(to: checkout.appendingPathComponent("Source.swift"))
            for args in [["init", "-b", "main"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture"]] {
                try #require(EnvironmentInspector.capture("/usr/bin/git", args, directory: checkout.path).0 == 0)
            }
            project = try EnvironmentInspector.project(path: checkout.path, developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
            let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/arm64-apple-macosx/debug/TaskHost")
            let root = root
            builds = BuildCoordinator(directory: root.appendingPathComponent("support"), helper: helper, defaults: defaults, inspect: { $0 }, resolveDeveloper: { $0.developerDirectory! }, makeCommand: { record, path in
                try Data("called".utf8).write(to: root.appendingPathComponent(record.id.uuidString + ".called"))
                try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path!).deletingPathExtension().path + "-DerivedData", withIntermediateDirectories: true)
                if record.parameters.intent == .catalogue {
                    let base = URL(fileURLWithPath: path!).deletingPathExtension().path
                    try Data(#"{"values":["Tests/Suite/plain()","Tests/Suite/second()","Tests/Suite/check(value:)"]}"#.utf8).write(to: URL(fileURLWithPath: base + ".tests.json"))
                }
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("editDuringRun").path) {
                    return .init(executable: "/usr/bin/python3", arguments: ["-c", "import pathlib,time,sys; pathlib.Path(sys.argv[1]).write_text('during execution'); time.sleep(0.1)", record.project.path + "/Source.swift"], directory: root.path, environment: [:])
                }
                return .init(executable: "/usr/bin/true", arguments: [], directory: root.path, environment: [:])
            }, discover: { _, _, _, _, _ in
                var catalogue = BuildCatalogue(); catalogue.schemes = ["Fixture"]; catalogue.configurations = ["Debug"]; catalogue.destinations = [.init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Fixture")]; return catalogue
            })
            model = TaskCoordinator(directory: root.appendingPathComponent("support"), buildCoordinator: builds, defaults: defaults)
            model.projects = [project]; model.selectedProjectPath = project.path; builds.schedule = { }
            integration = MimicIntegration(model: model, defaults: defaults)
        }
        func cleanup() { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func payload() throws -> BridgeValue { var value = try #require(BridgeValue.encode(parameters).object); value["operation"] = nil; return .object(value) }
        func runCatalogue() async throws -> UUID {
            let id = UUID()
            let reply = try await integration.handle(.init(method: "start_test_catalogue", parameters: ["context": MimicIntegration.context(project), "parameters": try payload(), "requestID": .string(id.uuidString)], helperIdentity: .current))
            #expect(reply["status"] == .string("queued"))
            builds.start(try #require(builds.activity(id))); try await wait(id)
            #expect(builds.activity(id)?.status == .succeeded)
            return id
        }
        func wait(_ id: UUID) async throws {
            for _ in 0..<600 {
                if builds.activity(id)?.status.isPending == false { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Fixture operation did not finish")
        }
        func selection(_ catalogue: UUID) async throws -> String {
            let reply = try await integration.handle(.init(method: "validate_selected_tests", parameters: ["context": MimicIntegration.context(project), "catalogueID": .string(catalogue.uuidString), "scope": .string("method"), "testIdentifiers": .array([.string("Tests/Suite/plain()")])]))
            return try #require(reply["selectionID"].string)
        }
    }
    @Test func compactStateIsScopedBoundedAndNeverEnumerates() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let reply = try await fixture.integration.handle(.init(method: "get_agent_state", clientSessionID: UUID().uuidString, helperIdentity: .current))
        #expect(reply["needsBinding"] == .bool(true) && reply["context"] == .null)
        #expect(reply["delivery"]["compatibility"] == .string("compatible"))
        #expect(try JSONEncoder().encode(reply).count < 8192)
        #expect(reply["actions"] == .null && fixture.builds.records.isEmpty)
    }
    @Test func cataloguePaginationValidationAndSourceChangeAreNative() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let id = try await fixture.runCatalogue()
        let first = try await fixture.integration.handle(.init(method: "get_test_catalogue", parameters: ["catalogueID": .string(id.uuidString), "limit": .number(1)]))
        #expect(first["complete"] == .bool(true) && first["tests"].array?.count == 1)
        let second = try await fixture.integration.handle(.init(method: "get_test_catalogue", parameters: ["catalogueID": .string(id.uuidString), "limit": .number(1), "cursor": first["nextCursor"]]))
        #expect(first["tests"] != second["tests"])
        let selection = try await fixture.selection(id)
        try Data("changed".utf8).write(to: fixture.checkout.appendingPathComponent("Source.swift"))
        await #expect(throws: BuildError.sourceChanged) {
            try await fixture.integration.handle(.init(method: "run_verified_tests", parameters: ["context": MimicIntegration.context(fixture.project), "selectionID": .string(selection), "requestID": .string(UUID().uuidString)]))
        }
        #expect(fixture.builds.records.count == 1)
    }
    @Test func queuedChangePreventsProcessAndDuplicateRetainsOriginalOperation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let catalogue = try await fixture.runCatalogue(), selection = try await fixture.selection(catalogue), id = UUID()
        let request = MimicBridgeRequest(method: "run_verified_tests", parameters: ["context": MimicIntegration.context(fixture.project), "selectionID": .string(selection), "requestID": .string(id.uuidString)])
        _ = try await fixture.integration.handle(request)
        try Data("queued edit".utf8).write(to: fixture.checkout.appendingPathComponent("Source.swift"))
        _ = try await fixture.integration.handle(request)
        fixture.builds.start(try #require(fixture.builds.activity(id))); try await fixture.wait(id)
        #expect(fixture.builds.activity(id)?.errorCode == "sourceChanged")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(id.uuidString + ".called").path))
    }
    @Test func cleanupUsesSharedQueueAndRejectsChangedPreview() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let catalogue = try await fixture.runCatalogue()
        let preview = try await fixture.integration.handle(.init(method: "preview_artifact_cleanup", parameters: ["activityID": .string(catalogue.uuidString)]))
        let id = UUID()
        let reply = try await fixture.integration.handle(.init(method: "cleanup_activity_artifacts", parameters: ["previewID": preview["previewID"], "requestID": .string(id.uuidString)]))
        #expect(reply["status"] == .string("queued"))
        #expect(FileManager.default.fileExists(atPath: fixture.builds.artifactRoot.appendingPathComponent(catalogue.uuidString + ".tests.json").path))
        fixture.builds.start(try #require(fixture.builds.activity(id))); try await fixture.wait(id)
        #expect(fixture.builds.activity(id)?.status == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: fixture.builds.artifactRoot.appendingPathComponent(catalogue.uuidString + ".tests.json").path))
        let again = try await fixture.integration.handle(.init(method: "cleanup_activity_artifacts", parameters: ["previewID": preview["previewID"], "requestID": .string(id.uuidString)]))
        #expect(again["activityID"] == .string(id.uuidString))
    }
    @Test func incompatibleSchemaCannotAdmitAndCatalogueRetryPreservesOperation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let blocked = try await fixture.integration.handle(.init(method: "start_test_catalogue", parameters: [:], helperIdentity: .init(version: "old", build: "1", toolSchemaRevision: 1)))
        #expect(blocked["code"] == .string("incompatibleToolSchema") && fixture.builds.records.isEmpty)
        let id = try await fixture.runCatalogue()
        try Data("new code".utf8).write(to: fixture.checkout.appendingPathComponent("Source.swift"))
        let again = try await fixture.integration.handle(.init(method: "start_test_catalogue", parameters: ["context": MimicIntegration.context(fixture.project), "parameters": try fixture.payload(), "requestID": .string(id.uuidString)]))
        #expect(again["id"] == .string(id.uuidString) && fixture.builds.records.count == 1)
    }
    @Test func exactRevisionReusesDerivedDataAndExecutionChangesRemainHistorical() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let catalogue = try await fixture.runCatalogue(), selection = try await fixture.selection(catalogue), id = UUID()
        _ = try await fixture.integration.handle(.init(method: "run_verified_tests", parameters: ["context": MimicIntegration.context(fixture.project), "selectionID": .string(selection), "requestID": .string(id.uuidString)]))
        let record = try #require(fixture.builds.activity(id)); #expect(record.preparedDerivedDataPath != nil)
        try Data().write(to: fixture.root.appendingPathComponent("editDuringRun"))
        fixture.builds.start(record); try await fixture.wait(id)
        #expect(fixture.builds.activity(id)?.status == .succeeded)
        #expect(fixture.builds.activity(id)?.sourceProvenance?.stability == "changed")
        let reload = BuildCoordinator(directory: fixture.root.appendingPathComponent("support"), helper: URL(fileURLWithPath: "/missing"), defaults: fixture.defaults)
        #expect(reload.activity(id)?.sourceProvenance?.stability == "changed"); reload.stop()
    }
    @Test func changedOrLeasedArtifactsCannotBeDeleted() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let catalogue = try await fixture.runCatalogue()
        fixture.builds.artifactLeases.insert(catalogue)
        await #expect(throws: BuildError.self) { try await fixture.integration.handle(.init(method: "preview_artifact_cleanup", parameters: ["activityID": .string(catalogue.uuidString)])) }
        fixture.builds.artifactLeases.remove(catalogue)
        let preview = try await fixture.integration.handle(.init(method: "preview_artifact_cleanup", parameters: ["activityID": .string(catalogue.uuidString)]))
        let id = UUID()
        _ = try await fixture.integration.handle(.init(method: "cleanup_activity_artifacts", parameters: ["previewID": preview["previewID"], "requestID": .string(id.uuidString)]))
        let artifact = fixture.builds.artifactRoot.appendingPathComponent(catalogue.uuidString + ".tests.json")
        try Data("changed after admission".utf8).write(to: artifact)
        fixture.builds.start(try #require(fixture.builds.activity(id))); try await fixture.wait(id)
        #expect(fixture.builds.activity(id)?.status == .failed && FileManager.default.fileExists(atPath: artifact.path))
    }
    @Test func receiptsRequireSuccessfulPinnedPreparationAndIsolatePlatforms() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var profile = try Profile11Fixture.snapshot(directory: fixture.root).profile
        let action = try #require(profile.actions.first { $0.presentation == .preparation })
        profile.preparation = .init(actionID: action.id, platforms: [.ios], parameters: [:], inputs: ["Source.swift"], required: true, stages: [0])
        let snapshot = ProfileSnapshot(profile: profile, revision: "receipt-fixture", directory: fixture.root.path)
        fixture.model.activeProfile = snapshot; fixture.model.identifyPreparationToolchain = { _ in "toolchain-v1" }
        let before = await fixture.model.preparationState(project: fixture.project, platform: .ios)
        #expect(before["status"] == .string("missing") && before["blocking"] == .bool(true))
        var record = TaskRecord(action: .bootstrap, project: fixture.project, options: .init())
        record.profileExecution = ProfileExecution(snapshot: snapshot, actionID: action.id, parameters: [:]); record.selectedDeveloperDirectory = fixture.project.developerDirectory
        await fixture.model.prepareAgentMetadata(record); record.status = .failed; await fixture.model.finishAgentMetadata(record)
        #expect(fixture.model.preparationReceipts.isEmpty)
        await fixture.model.prepareAgentMetadata(record); record.status = .succeeded; record.exitCode = 0; record.completedProfileSteps = action.steps.count; await fixture.model.finishAgentMetadata(record)
        #expect(await fixture.model.preparationState(project: fixture.project, platform: .ios)["status"] == .string("current"))
        #expect(await fixture.model.preparationState(project: fixture.project, platform: .tvos)["blocking"] == .bool(false))
        try Data("input changed".utf8).write(to: fixture.checkout.appendingPathComponent("Source.swift"))
        #expect(await fixture.model.preparationState(project: fixture.project, platform: .ios)["status"] == .string("stale"))
        fixture.model.identifyPreparationToolchain = { _ in nil }
        #expect(await fixture.model.preparationState(project: fixture.project, platform: .ios)["status"] == .string("unknown"))
    }
    @Test func simulatorProtocolPersistsOnlyMetadataAndRestartsAsInterrupted() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let session = UUID(), id = UUID(), activity = UUID()
        let revision = try SourceRevisionReader.capture(path: fixture.project.path)
        let binding = SimulatorBuildBinding(sessionID: session, deviceID: UUID(), activityID: activity, productID: "fixture-product", sourceRevision: revision, project: fixture.project)
        fixture.integration.simulatorChecks[id] = .init(id: id, owner: nil, workflowID: UUID(), binding: binding)
        var operation = SimulatorActivity(id: UUID(), project: fixture.project, developer: "/fixture", deviceID: binding.deviceID, sessionID: session, kind: .action)
        operation.status = .unknown; operation.observedRevision = 7
        fixture.integration.recordSimulatorOperation(operation)
        try fixture.integration.recordSimulatorObservation(session: session, observation: .object(["revision": .number(8), "image": .string(Data([1,2,3]).base64EncodedString()), "hierarchy": .string("PRIVATE-TYPED-TEXT")]))
        let saved = try String(contentsOf: fixture.root.appendingPathComponent("support/Agent/checks.json"), encoding: .utf8)
        #expect(!saved.contains("PRIVATE-TYPED-TEXT") && saved.contains("action:unknown"))
        let restarted = MimicIntegration(model: fixture.model, defaults: fixture.defaults)
        #expect(restarted.simulatorChecks[id]?.status == "interrupted")
        #expect(restarted.simulatorChecks[id]?.events.first?.revision == 7)
    }

    @Test func compactStateOmitsLargeHistoryAndForeignCheckoutButPreservesQueueCount() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.model.records = (0..<150).map { _ in
            var record = TaskRecord(action: .format, project: fixture.project); record.status = .succeeded; return record
        }
        var foreign = TaskRecord(action: .format, project: .init(path: "/private/tmp/FOREIGN-CHECKOUT")); foreign.status = .running
        fixture.model.records.append(foreign)
        let reply = await fixture.integration.agentState(thread: nil, includeActions: false, helper: .current)
        let bytes = try JSONEncoder().encode(reply)
        #expect(bytes.count < 8192 && reply["active"].array?.isEmpty == true && reply["queue"]["tasks"] == .number(1))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("FOREIGN-CHECKOUT"))
        fixture.model.records = []
    }

}
