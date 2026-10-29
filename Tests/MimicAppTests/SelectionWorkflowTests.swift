//
//  SelectionWorkflowTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import os
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct SelectionWorkflowTests {
    @Test func pagedSelectionsAdmitTwoExactOperationsAndExecuteOnlyTwoFixtureCommands() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("SelectionWorkflow-" + UUID().uuidString), checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let suite = UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Fixture"]] { try #require(EnvironmentInspector.capture("/usr/bin/git", arguments, directory: checkout.path).0 == 0) }
        let project = try EnvironmentInspector.project(path: checkout.path, developerDirectory: "/fixture/Developer"), revision = try SourceRevisionReader.capture(path: checkout.path)
        let history = BuildHistoryStore(directory: root.appendingPathComponent("state")), recorder = OSAllocatedUnfairLock(initialState: [[String]]())
        var catalogueRecords: [BuildActivity] = []
        for (index, count) in [332, 818].enumerated() {
            var parameters = BuildParameters(scheme: "Fixture\(index)", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"); parameters.intent = .catalogue
            var record = BuildActivity(project: project, parameters: parameters, source: "Fixture")
            record.status = .succeeded; record.selectedDeveloperDirectory = project.developerDirectory
            var provenance = SourceProvenance(admitted: revision); provenance.started = revision; provenance.observe(revision); record.sourceProvenance = provenance
            record.testCatalogue = .init(project: project, developerDirectory: "/fixture/Developer", parameters: parameters, tests: (0..<count).map { .init(id: "Tests\(index)/Suite/test\($0)()", target: "Tests\(index)", className: "Suite", name: "test\($0)()") })
            catalogueRecords.append(record)
        }
        try history.save(catalogueRecords)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? repo.appendingPathComponent(".build/debug/TaskHost").path)
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let builds = BuildCoordinator(directory: root.appendingPathComponent("state"), helper: helper, defaults: defaults, inspect: { $0 }, resolveDeveloper: { _ in "/fixture/Developer" }, makeCommand: { record, _ in
            recorder.withLock { $0.append(record.parameters.testIdentifiers) }
            return .init(executable: "/bin/bash", arguments: ["-c", "printf 'FIXTURE ONLY\\n'"], directory: checkout.path, environment: ["PATH": "/usr/bin:/bin"])
        }, discover: { _, _, _, _, _ in
            var catalogue = BuildCatalogue(); catalogue.schemes = ["Fixture0", "Fixture1"]; catalogue.configurations = ["Debug"]; catalogue.destinations = [.init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Fixture")]; return catalogue
        })
        let model = TaskCoordinator(directory: root.appendingPathComponent("app"), buildCoordinator: builds, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path; builds.schedule = { }
        defer { model.stopAndExit() }
        let integration = MimicIntegration(model: model, defaults: defaults), context = MimicIntegration.context(project), workflow = UUID().uuidString
        var activities: [UUID] = []
        for catalogue in catalogueRecords {
            let id = UUID()
            _ = try await integration.handle(.init(method: "create_test_selection", parameters: ["context": context, "catalogueID": .string(catalogue.id.uuidString), "requestID": .string(id.uuidString)]))
            let ids = catalogue.testCatalogue!.tests.map(\.id)
            for offset in stride(from: 0, to: ids.count, by: 100) {
                let page: [String: BridgeValue] = ["selectionID": .string(id.uuidString), "requestID": .string(UUID().uuidString), "testIdentifiers": .array(ids.dropFirst(offset).prefix(100).map(BridgeValue.string))]
                _ = try await integration.handle(.init(method: "append_test_selection", parameters: page))
                _ = try await integration.handle(.init(method: "append_test_selection", parameters: page))
            }
            let finalized = try await integration.handle(.init(method: "finalize_test_selection", parameters: ["context": context, "selectionID": .string(id.uuidString)]))
            #expect(finalized["valid"] == .bool(true) && finalized["count"].integer == ids.count)
            let replayed = try await integration.handle(.init(method: "create_test_selection", parameters: ["context": context, "catalogueID": .string(catalogue.id.uuidString), "requestID": .string(id.uuidString)]))
            #expect(replayed["state"] == .string("finalized") && replayed["digest"] == finalized["digest"] && replayed["count"].integer == ids.count)
            let activityID = UUID()
            let result = try await integration.handle(.init(method: "run_verified_tests", parameters: ["context": context, "selectionID": .string(id.uuidString), "requestID": .string(activityID.uuidString), "workflowID": .string(workflow), "enqueue": .bool(!activities.isEmpty)]))
            #expect(result["parameters"]["testCount"].integer == ids.count)
            activities.append(activityID)
        }
        #expect(builds.records.filter { $0.parameters.operation == .test }.count == 2)
        for id in activities {
            builds.start(try #require(builds.activity(id)))
            let deadline = ContinuousClock.now + .seconds(10)
            while builds.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!builds.busy)
        }
        #expect(recorder.withLock { $0.map(\.count) } == [332, 818])
        for (index, ids) in recorder.withLock({ $0 }).enumerated() { #expect(ids == catalogueRecords[index].testCatalogue!.tests.map(\.id).sorted()) }
        let stored = try await builds.result(activities[0])
        #expect(stored.verification?.verdict != "passed")
        let compact = try await integration.buildRequest(.init(method: "get_build_result", parameters: ["activityID": .string(activities[0].uuidString)]))
        #expect(compact["diagnosticText"] == .null && compact["executions"] == .null)
        #expect(compact["verification"]["requestedCount"].integer == 332)
        let expiredArtifact = try await integration.handle(.init(method: "get_test_artifact", parameters: ["artifactID": .string(UUID().uuidString)]))
        #expect(expiredArtifact["availability"] == .string("unavailable") && expiredArtifact["reason"] == .string("artifactExpiredOrUnknown"))
    }
}
