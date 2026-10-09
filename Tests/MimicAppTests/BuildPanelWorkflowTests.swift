// Created by Василий Маслов on 09.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor private struct PanelBuildFixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let project: ProjectContext
    let builds: BuildCoordinator
    var parameters: BuildParameters { var value = BuildParameters(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"); value.intent = .run; return value }
    init(failure: BuildStage? = nil, multiple: Bool = false, delay: BuildStage? = nil, plans: [String] = []) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildPanelWorkflow-" + UUID().uuidString)
        self.root = root; suite = "BuildPanelWorkflow-" + UUID().uuidString; defaults = try #require(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fixture.xcodeproj"), withIntermediateDirectories: true)
        project = ProjectContext(path: root.path, branch: "main", commit: "one", developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/arm64-apple-macosx/debug/TaskHost")
        @Sendable func command(_ script: String, _ arguments: [String] = []) -> CommandSpec { .init(executable: "/bin/bash", arguments: ["-c", script, "fixture"] + arguments, directory: root.path, environment: ["PATH": "/usr/bin:/bin"]) }
        builds = BuildCoordinator(directory: root, helper: helper, defaults: defaults, inspect: { $0 }, resolveDeveloper: { $0.developerDirectory! }, makeCommand: { record, resultPath in
            let base = URL(fileURLWithPath: resultPath!).deletingPathExtension().path
            let directory = URL(fileURLWithPath: base + "-DerivedData").appendingPathComponent("Build/Products/Debug-iphonesimulator")
            var targets: [[String: Any]] = []
            for index in 1...(multiple ? 2 : 1) {
                let app = directory.appendingPathComponent("App\(index).app")
                try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "fixture.app\(index)"], format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
                targets.append(["target": "App\(index)", "buildSettings": ["WRAPPER_EXTENSION": "app", "TARGET_BUILD_DIR": directory.path, "FULL_PRODUCT_NAME": app.lastPathComponent, "PRODUCT_BUNDLE_IDENTIFIER": "fixture.app\(index)", "PLATFORM_NAME": "iphonesimulator"]])
            }
            try JSONSerialization.data(withJSONObject: targets).write(to: root.appendingPathComponent("settings.json"))
            try Data(#"{"values":[{"name":"Plan","children":[{"name":"FixtureTests","children":[{"name":"Checkout","children":[{"name":"testOne()"},{"name":"testTwo()"}]}]}]}]}"#.utf8).write(to: URL(fileURLWithPath: base + ".tests.json"))
            return command((delay == .compilation ? "sleep 30; " : "") + "printf 'FIXTURE BUILD\\n'; exit $1", [failure == .compilation || failure == .catalogue && record.parameters.intent == .catalogue ? "7" : "0"])
        }, makeStageCommand: { _, stage, original in
            if failure == .products { return command("exit 7") }
            if stage == .products { return .init(executable: "/bin/cat", arguments: [root.appendingPathComponent("settings.json").path], directory: root.path, environment: [:]) }
            let operation = original.arguments.dropFirst().first ?? "unknown"
            return command("printf '%s\\n' \"$1\" >> \"$2\"; " + (delay == stage ? "sleep 30; " : "") + "exit $3", [operation, root.appendingPathComponent("calls").path, failure == stage ? "7" : "0"])
        }, discover: { _, _, _, _, _ in
            var catalogue = BuildCatalogue(); catalogue.schemes = ["Fixture"]; catalogue.configurations = ["Debug"]
            catalogue.testPlans = plans
            catalogue.destinations = [.init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Fixture iPhone")]; return catalogue
        })
        let project = project; builds.currentProject = { project }
    }
    func cleanup() { builds.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw BuildError.unavailable
    }
    func run(_ value: BuildParameters? = nil) async throws -> UUID {
        let record = try await builds.submit(id: UUID(), project: project, parameters: value ?? parameters, source: "fixture")
        builds.start(record); return record.id
    }
    var calls: [String] { ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty } }
}

@Suite(.serialized, .timeLimit(.minutes(3))) @MainActor struct BuildPanelWorkflowTests {
    @Test func completeRunKeepsQueueOwnershipAndOpensSimulatorAfterLaunch() async throws {
        let fixture = try PanelBuildFixture(); defer { fixture.cleanup() }
        var opened = false; fixture.builds.showSimulator = { _ in opened = true }
        _ = try await fixture.run(); try await fixture.wait { !fixture.builds.busy }
        #expect(fixture.calls == ["boot", "bootstatus", "install", "launch"])
        #expect(fixture.builds.records.last?.status == .succeeded); #expect(fixture.builds.records.last?.completedStages == 3); #expect(opened)
    }
    @Test(arguments: [BuildStage.compilation, .products, .installation, .launch]) func eachStageFailsSeparately(stage: BuildStage) async throws {
        let fixture = try PanelBuildFixture(failure: stage); defer { fixture.cleanup() }
        _ = try await fixture.run(); try await fixture.wait { !fixture.builds.busy }
        #expect(fixture.builds.records.last?.status == .failed)
        #expect(fixture.builds.records.last?.errorCode == "stage." + stage.rawValue)
        if stage != .launch { #expect(!fixture.calls.contains("launch")) }
    }
    @Test func ambiguousProductIsChosenWithoutReleasingQueue() async throws {
        let fixture = try PanelBuildFixture(multiple: true); defer { fixture.cleanup() }
        let id = try await fixture.run(); try await fixture.wait { fixture.builds.active?.products?.count == 2 }
        #expect(fixture.builds.busy); #expect(fixture.calls.isEmpty)
        let product = try #require(fixture.builds.active?.products?.last)
        try fixture.builds.chooseProduct(product.id, activityID: id)
        try await fixture.wait { !fixture.builds.busy }
        #expect(fixture.builds.records.last?.selectedProductID == product.id); #expect(fixture.builds.records.last?.status == .succeeded)
        #expect(throws: BuildError.context) { try fixture.builds.chooseProduct(product.id, activityID: id) }
    }
    @Test func cancellationWhileChoosingProductAndChangedRevisionRejectLaunch() async throws {
        for cancel in [true, false] {
            let fixture = try PanelBuildFixture(multiple: true); defer { fixture.cleanup() }
            let id = try await fixture.run(); try await fixture.wait { fixture.builds.active?.products?.count == 2 }
            if cancel { fixture.builds.cancel(id) }
            else { var project = fixture.project; project.commit = "two"; fixture.builds.currentProject = { project }; try fixture.builds.chooseProduct(fixture.builds.active!.products![0].id, activityID: id) }
            try await fixture.wait { !fixture.builds.busy }
            #expect(fixture.calls.isEmpty); #expect(fixture.builds.records.last?.status == (cancel ? .cancelled : .failed))
        }
    }
    @Test(arguments: [BuildStage.compilation, .installation, .launch]) func cancellationStopsOwnedChild(stage: BuildStage) async throws {
        let fixture = try PanelBuildFixture(delay: stage); defer { fixture.cleanup() }
        let id = try await fixture.run(); try await fixture.wait { fixture.builds.active?.stage == stage && fixture.builds.active?.status == .running }
        fixture.builds.cancel(id); try await fixture.wait { !fixture.builds.busy }
        #expect(fixture.builds.records.last?.status == .cancelled)
    }
    @Test(arguments: [false, true]) func cataloguePreparationDoesNotInstallOrExecuteTests(failed: Bool) async throws {
        let fixture = try PanelBuildFixture(failure: failed ? .catalogue : nil); defer { fixture.cleanup() }
        var parameters = fixture.parameters; parameters.intent = .catalogue
        _ = try await fixture.run(parameters); try await fixture.wait { !fixture.builds.busy }
        #expect(fixture.calls.isEmpty); #expect(fixture.builds.records.last?.status == (failed ? .failed : .succeeded))
        if failed { #expect(fixture.builds.records.last?.testCatalogue == nil) }
        else { #expect(fixture.builds.records.last?.testCatalogue?.tests.count == 2) }
    }
    @Test func doubleCompactPressAndSavedSelectionAreShared() async throws {
        let fixture = try PanelBuildFixture(); defer { fixture.cleanup() }
        await fixture.builds.restoreDraft(project: fixture.project)
        await fixture.builds.refreshCatalogue(project: fixture.project)
        fixture.builds.draft = fixture.parameters; fixture.builds.draft.intent = nil
        fixture.builds.perform(); fixture.builds.perform()
        try await fixture.wait { !fixture.builds.manualSubmitting }
        #expect(fixture.builds.records.count == 1)
        fixture.builds.draft.testIdentifiers = ["FixtureTests/Checkout/testOne()"]
        fixture.builds.saveDraft(project: fixture.project)
        #expect(fixture.builds.panelDraft(project: fixture.project, developer: "/fixture/Developer").testIdentifiers.count == 1)
        var changed = fixture.project; changed.commit = "two"
        #expect(fixture.builds.panelDraft(project: changed, developer: "/fixture/Developer").testIdentifiers.isEmpty)
    }
    @Test func privatePanelKeepsSharedDraftExactSelectionAndRequestIdentity() async throws {
        let fixture = try PanelBuildFixture(); defer { fixture.cleanup() }
        let model = TaskCoordinator(directory: fixture.root, buildCoordinator: fixture.builds, defaults: fixture.defaults)
        defer { model.stopAndExit() }
        model.projects = [fixture.project]; model.selectedProjectPath = fixture.project.path; fixture.builds.schedule = { }
        try PanelWorkspaceStore(defaults: fixture.defaults).save(.init(checkout: fixture.project.path), for: "fixture-chat")
        let integration = MimicIntegration(model: model, defaults: fixture.defaults)
        let context = MimicIntegration.context(fixture.project)
        var parameters = fixture.parameters; parameters.intent = nil; parameters.testIdentifiers = ["FixtureTests/Checkout/testTwo()"]
        var fields = try #require(BridgeValue.encode(parameters).object); fields["developerDirectory"] = .string("/fixture/Developer")
        var payload: [String: BridgeValue] = ["context": context, "operation": .string("save"), "parameters": .object(fields), "requestID": .string(""), "activityID": .string(""), "productID": .string("")]
        func call() async throws -> BridgeValue { try await integration.handle(.init(method: "panel_build_control", parameters: payload, threadID: "fixture-chat")) }
        _ = try await call(); payload["operation"] = .string("get"); payload["parameters"] = .object([:])
        let saved = try await call(); #expect(saved["draft"]["testIdentifiers"] == .array([.string("FixtureTests/Checkout/testTwo()")]))
        let id = UUID(); payload["parameters"] = .object(fields); payload["operation"] = .string("tests"); payload["requestID"] = .string(id.uuidString)
        _ = try await call(); _ = try await call()
        #expect(fixture.builds.records.count == 1); #expect(fixture.builds.records[0].parameters.testIdentifiers == parameters.testIdentifiers)
        payload["requestID"] = .string(UUID().uuidString)
        await #expect(throws: BuildError.capacity) { try await call() }
        fixture.builds.cancel(id)
        fields["developerDirectory"] = .string("/stale/Developer"); payload["parameters"] = .object(fields)
        await #expect(throws: BuildError.context) { try await call() }
        #expect(fixture.builds.records.count == 1)
    }
    @Test func compatibleTestPlanAndMarksSurviveOpeningBuildCard() async throws {
        let fixture = try PanelBuildFixture(plans: ["Selected", "Other"]); defer { fixture.cleanup() }
        var parameters = fixture.parameters; parameters.intent = nil; parameters.testPlan = "Selected"; parameters.testIdentifiers = ["FixtureTests/Checkout/testOne()"]
        fixture.builds.savePanelDraft(parameters, project: fixture.project, developer: "/fixture/Developer")
        await fixture.builds.restoreDraft(project: fixture.project); await fixture.builds.refreshCatalogue(project: fixture.project)
        #expect(fixture.builds.draft.testPlan == "Selected"); #expect(fixture.builds.draft.testIdentifiers == parameters.testIdentifiers)
        #expect(fixture.builds.testsCompatible)
        fixture.builds.draft.testPlan = ""; #expect(!fixture.builds.testsCompatible)
    }
    @Test func unverifiedPreparationIsNeverReused() async throws {
        let fixture = try PanelBuildFixture(); defer { fixture.cleanup() }
        var parameters = fixture.parameters; parameters.intent = .catalogue
        _ = try await fixture.run(parameters); try await fixture.wait { !fixture.builds.busy }
        parameters.intent = nil; parameters.operation = .test; parameters.testIdentifiers = ["FixtureTests/Checkout/testTwo()"]
        let record = try await fixture.builds.submit(id: UUID(), project: fixture.project, parameters: parameters, source: "fixture")
        #expect(record.preparedDerivedDataPath == nil)
        let command = try parameters.command(project: fixture.project, derivedDataPath: record.preparedDerivedDataPath)
        #expect(!command.arguments.contains("-derivedDataPath")); #expect(command.arguments.filter { $0.hasPrefix("-only-testing:") } == ["-only-testing:FixtureTests/Checkout/testTwo()"])
    }
}
