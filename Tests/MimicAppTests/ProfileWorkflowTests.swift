//
//  ProfileWorkflowTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 06.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ProfileWorkflowTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    @Test func familiarGeneratorsUseReviewedProfilePreviewAndRejectStaleInputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileWorkflow-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ProfileWorkflow-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"]] {
            try #require(EnvironmentInspector.capture("/usr/bin/git", args, directory: root.path).0 == 0)
        }
        let storage = root.appendingPathComponent("Storage"), snapshot = try Profile11Fixture.install(directory: storage)
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TaskHost")
        let model = TaskCoordinator(directory: storage, helperURL: helper, defaults: defaults), project = try EnvironmentInspector.project(path: root.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        for kind in GeneratorKind.allCases {
            model.generatorKind = kind; model.generatorName = "Header"; model.checkReadiness()
            model.previewGeneration(); try await wait { !model.planningGeneration }
            let plan = try #require(model.generationPlan), preview = try #require(model.records.last)
            #expect(preview.action == .generation); #expect(preview.generation?.kind == kind); #expect(plan.canGenerate)
            let execution = try model.profileExecution(.generation, generation: GenerationRequest(kind: kind, name: "Header", digest: plan.digest))
            model.generatorName = "Changed"
            var rejected: TaskRecord?
            model.requestProfile(execution: execution) { rejected = $0 }
            #expect(rejected == nil); #expect(model.records.count == 1)
            model.generatorName = "Header"; model.previewGeneration(); try await wait { !model.planningGeneration }
            let count = model.records.count; model.generateFromPreview()
            try await wait { model.records.count > count && !model.busy && model.pendingCount == 0 }
            let generated = try #require(model.records.last)
            #expect(generated.action == .generation); #expect(generated.generation?.kind == kind); #expect(generated.profileExecution?.snapshot == snapshot)
            #expect(generated.status == .succeeded); #expect(generated.logPath != nil)
            model.records = []
        }
        model.stopAndExit()
    }
    @Test func mandatoryImportAndRestoredPanelRenderAtOriginalWidth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileUI-" + UUID().uuidString)
        let suite = "ProfileUI-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = TaskCoordinator(directory: root, defaults: defaults)
        #expect(!model.hasCompatibleProfile); #expect(!model.canRequestQuickBootstrap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/acceptance/mimic11")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for state in ["setup", "ready", "expanded"] {
            if state != "setup" {
                model.activeProfile = try Profile11Fixture.snapshot(directory: root)
                let project = ProjectContext(path: "/private/tmp/fixture", branch: "feature/team/subscription-management-profile-header-navigation", commit: "fixture")
                model.projects = [project]; model.selectedProjectPath = project.path
                model.readiness = Dictionary(uniqueKeysWithValues: MimicAction.allCases.map { ($0, []) })
                if state == "expanded" { model.expandedSection = .tool(.generation); model.generatorName = "SubscriptionManagementProfileHeader" }
            }
            let view = NSHostingView(rootView: MimicPanel(model: model).frame(height: 660))
            view.frame = NSRect(x: 0, y: 0, width: 440, height: 660); view.layoutSubtreeIfNeeded()
            #expect(view.bounds.width == 440)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(state + ".png"))
        }
    }
}
