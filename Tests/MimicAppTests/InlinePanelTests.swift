//
//  InlinePanelTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor
private struct InlineFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InlinePanel-" + UUID().uuidString)
    let suite = "InlinePanel-" + UUID().uuidString
    let defaults: UserDefaults
    let model: TaskCoordinator
    let project = ProjectContext(path: "/private/tmp/Inline-panel-fixture", branch: "feature/long-branch-for-inline-history", commit: "fixture-sha")

    init(helperURL: URL? = nil) throws {
        self.defaults = try #require(UserDefaults(suiteName: self.suite))
        self.model = TaskCoordinator(directory: self.directory, helperURL: helperURL, defaults: self.defaults)
        self.model.projects = [self.project]; self.model.selectedProjectPath = self.project.path
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: self.directory)
        self.defaults.removePersistentDomain(forName: self.suite)
    }

    func plan() throws -> GenerationPlan {
        try JSONDecoder().decode(GenerationPlan.self, from: Data(#"{"files":[{"path":"Frameworks/Component/Sources/Feature/VeryLongButRealisticComponentConfiguration.swift","exists":false}],"digest":"fixture-digest"}"#.utf8))
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct InlinePanelTests {
    @Test
    func onlyOneAreaOpensAndCollapsePreservesDraftsAndPreview() throws {
        let fixture = try InlineFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        model.generatorName = "ProfileHeader"; model.generatorKind = .module
        model.generationPlan = try fixture.plan()
        model.branchSearch = "feature/"; model.simulatorSearch = "iOS 26"
        model.taskSearch = "Profile"; model.taskFilter = .failed
        model.ciSettings.address = "https://gitlab.example.test"
        for section in [PanelSection.tool(.generation), .tool(.localization), .tool(.proto), .tool(.format), .simulators, .branches, .ci, .usage, .tasks] {
            model.toggleSection(section)
            #expect(model.expandedSection == section)
            #expect(model.panelScrollTarget == section.scrollID)
        }
        model.toggleSection(.tasks)
        #expect(model.expandedSection == nil)
        model.openTool(.generation)
        #expect(model.generatorName == "ProfileHeader" && model.generatorKind == .module)
        #expect(model.generationPlan?.digest == "fixture-digest")
        #expect(model.branchSearch == "feature/" && model.simulatorSearch == "iOS 26")
        #expect(model.taskSearch == "Profile" && model.taskFilter == .failed)
        #expect(model.ciSettings.address == "https://gitlab.example.test")
        model.openTool(.bootstrap)
        #expect(model.expandedSection == nil && model.generationPlan != nil)
        #expect(model.panelScrollTarget == "section.bootstrap")
    }

    @Test
    func hiddenGeneratorChangesInvalidateThePreview() throws {
        let fixture = try InlineFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        model.generatorName = "ProfileHeader"; model.generationPlan = try fixture.plan()
        model.openSettings()
        model.generatorName = "ProfileFooter"
        #expect(model.generationPlan == nil)
        model.generationPlan = try fixture.plan(); model.generatorKind = .feature
        #expect(model.generationPlan == nil)
    }

    @Test
    func historySelectsTheRequestedTaskAndMakesItVisibleThroughFilters() throws {
        let fixture = try InlineFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        var failed = TaskRecord(action: .localization, project: fixture.project); failed.status = .failed
        var running = TaskRecord(action: .format, project: fixture.project); running.status = .running
        model.records = [failed, running]; model.taskFilter = .failed; model.taskSearch = "no results"
        var opens = 0; model.showPanel = { opens += 1 }
        model.unreadFailure = true
        model.showHistory(id: running.id)
        #expect(model.expandedSection == .tasks && model.selectedTaskID == running.id)
        #expect(model.taskFilter == .all && model.taskSearch.isEmpty)
        #expect(model.filteredTaskRecords.map(\.id) == [running.id, failed.id])
        #expect(!model.unreadFailure && model.terminalFocusTaskID == nil && opens == 1)
        model.showHistory(id: running.id, focusTerminal: true)
        #expect(model.terminalFocusTaskID == running.id)
        #expect(model.panelScrollTarget == "terminal." + running.id.uuidString)
        model.toggleTask(failed.id)
        #expect(model.selectedTaskID == failed.id && model.terminalFocusTaskID == nil)
        model.toggleTask(failed.id); #expect(model.selectedTaskID == nil)
        model.showHistory(id: failed.id, focusTerminal: true)
        #expect(model.terminalFocusTaskID == nil)
        #expect(model.panelScrollTarget == "task." + failed.id.uuidString)
    }

    @Test
    func reopeningHistoryPreservesSearchAndFilterIncludingNoResults() throws {
        let fixture = try InlineFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        var failed = TaskRecord(action: .localization, project: fixture.project); failed.status = .failed
        var success = TaskRecord(action: .format, project: fixture.project); success.status = .succeeded
        model.records = [failed, success]; model.taskFilter = .failed; model.taskSearch = fixture.project.branch
        model.toggleHistory()
        #expect(model.selectedTaskID == failed.id && model.taskFilter == .failed)
        model.toggleHistory(); model.toggleHistory()
        #expect(model.selectedTaskID == failed.id && model.taskSearch == fixture.project.branch)
        model.taskSearch = "no matching fixture"
        model.toggleHistory(); model.toggleHistory()
        #expect(model.selectedTaskID == nil && model.taskFilter == .failed)
        #expect(model.taskSearch == "no matching fixture" && model.filteredTaskRecords.isEmpty)
    }

    @Test
    func repeatGenerationRequiresANewPlanEvenForIdenticalParameters() throws {
        let fixture = try InlineFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        model.generatorName = "ProfileHeader"; model.generatorKind = .module
        model.generationPlan = try fixture.plan()
        var record = TaskRecord(action: .generation, project: fixture.project, generation: GenerationRequest(kind: .module, name: "ProfileHeader", digest: "fixture-digest"))
        record.status = .succeeded; model.records = [record]
        model.repeatTask(record)
        #expect(model.expandedSection == .tool(.generation))
        #expect(model.generatorName == "ProfileHeader" && model.generatorKind == .module)
        #expect(model.generationPlan == nil && !model.generationError.isEmpty)
        #expect(model.records.count == 1)
    }

    @Test
    func collapseAndPanelClosePreserveOriginalAnalysisAndSelection() throws {
        let fixture = try InlineFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        var record = TaskRecord(action: .bootstrap, project: fixture.project); record.status = .failed
        record.error = "Fixture failure"; model.records = [record]
        model.prepareAnalysis(record)
        model.analysis.edit(id: record.id, fragment: "Edited fixture", comment: "Original task")
        let prompt = try #require(model.analysis.sessions[record.id]?.prompt)
        model.toggleSection(.tasks); model.panelVisibilityChanged(false)
        #expect(model.analysis.sessions[record.id]?.prompt == prompt)
        #expect(model.selectedTaskID == record.id)
        #expect(model.analysisEditorFocusTaskID == nil)
        model.revealSection(.tasks)
        #expect(model.expandedAnalysisIDs.contains(record.id))
        #expect(model.analysis.sessions[record.id]?.snapshot.taskID == record.id)
    }

    @Test
    func staleTerminalDismantleDoesNotRemoveTheNewSubscription() throws {
        let fixture = try InlineFixture(); defer { fixture.cleanUp() }
        let model = fixture.model, old = UUID(), new = UUID(), task = UUID()
        var received = Data()
        model.attachTerminal(owner: old) { _, _ in Issue.record("Detached subscription received output") }
        model.attachTerminal(owner: new) { _, data in received.append(data) }
        model.detachTerminal(owner: old)
        model.terminalOutput?(task, Data("Fixture output".utf8))
        #expect(String(decoding: received, as: UTF8.self) == "Fixture output")
        model.detachTerminal(owner: new)
        #expect(model.terminalOutput == nil)
    }

    @Test
    func appRestartStartsCollapsedWithoutPersistingPanelState() throws {
        let fixture = try InlineFixture(); defer { fixture.cleanUp() }
        fixture.model.openSettings(); fixture.model.taskSearch = "fixture"
        let restarted = TaskCoordinator(directory: fixture.directory, defaults: fixture.defaults)
        #expect(restarted.expandedSection == nil && restarted.taskSearch.isEmpty)
    }

    /// Runs only a disposable shell fixture through the real task host, never a checkout CLI.
    @Test
    func terminalInputResizeReplayAndCancellationSurvivePanelChanges() async throws {
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
        let fixture = try InlineFixture(helperURL: helper); defer { fixture.cleanUp() }
        let root = fixture.directory.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/App.xcworkspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".gem/bin"), withIntermediateDirectories: true)
        try "#!/bin/bash\nexit 1\n".write(to: root.appendingPathComponent("bootstrap.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\nprintf 'fixture ready\\n'\nIFS= read -r answer\nprintf 'fixture input received\\n'\nstty size\n".write(to: root.appendingPathComponent("utils.sh"), atomically: true, encoding: .utf8)
        let mint = root.appendingPathComponent(".gem/bin/mint")
        try "#!/bin/bash\nexit 0\n".write(to: mint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mint.path)
        for args in [["init", "-q", root.path], ["-C", root.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-qm", "Fixture"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", args).0 == 0)
        }
        let project = try EnvironmentInspector.project(path: root.path)
        let model = fixture.model
        model.projects = [project]; model.selectedProjectPath = project.path
        model.request(.format)
        try await self.waitUntil(diagnostic: { model.records.map { $0.status.rawValue + ": " + ($0.error ?? "no error") + " / " + String(decoding: model.replay(id: $0.id), as: UTF8.self) }.joined(separator: " | ") }) { model.activeRecord != nil && String(decoding: model.replay(id: model.records.last!.id), as: UTF8.self).contains("fixture ready") }
        let id = try #require(model.activeRecord?.id)
        #expect(model.expandedSection == .tasks && model.selectedTaskID == id)
        model.openSettings(); model.panelVisibilityChanged(false)
        #expect(model.activeRecord?.id == id)
        model.resize(id: id, columns: 40, rows: 12)
        model.input(id: id, data: Data("Fixture input\n".utf8))
        try await self.waitUntil(diagnostic: { model.records.map { $0.status.rawValue + ": " + ($0.error ?? "no error") + " / " + String(decoding: model.replay(id: $0.id), as: UTF8.self) }.joined(separator: " | ") }) { model.records.first(where: { $0.id == id })?.status == .succeeded }
        let replay = String(decoding: model.replay(id: id), as: UTF8.self)
        #expect(replay.contains("fixture input received") && replay.contains("12 40"))
        model.showHistory(id: id)
        #expect(String(decoding: model.replay(id: id), as: UTF8.self) == replay)
        model.request(.format)
        try await self.waitUntil(diagnostic: { model.records.map { $0.status.rawValue + ": " + ($0.error ?? "no error") + " / " + String(decoding: model.replay(id: $0.id), as: UTF8.self) }.joined(separator: " | ") }) { model.activeRecord != nil && String(decoding: model.replay(id: model.records.last!.id), as: UTF8.self).contains("fixture ready") }
        let cancelled = try #require(model.activeRecord?.id)
        model.toggleSection(.tasks); model.cancel(id: cancelled)
        try await self.waitUntil(diagnostic: { model.records.map { $0.status.rawValue + ": " + ($0.error ?? "no error") + " / " + String(decoding: model.replay(id: $0.id), as: UTF8.self) }.joined(separator: " | ") }) { model.records.first(where: { $0.id == cancelled })?.status == .cancelled }
    }

    @Test
    func rendersEveryAreaAt440PointsAndReducedHeight() async throws {
        let fixture = try InlineFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        model.readiness = [.generation: [], .localization: [], .proto: ["protoc"], .format: []]
        model.generatorName = "ProfileHeader"; model.generationPlan = try fixture.plan()
        model.simulators = [SimulatorDevice(id: UUID(), name: "iPad Pro 13-inch Development Configuration", runtime: "iOS 26.5", state: "Shutdown")]
        let output = ProcessInfo.processInfo.environment["MIMIC_INLINE_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for section in [PanelSection.tool(.generation), .tool(.localization), .tool(.proto), .tool(.format), .simulators, .branches, .tasks] {
            model.revealSection(section)
            for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                let view = NSHostingView(rootView: MimicPanel(model: model).frame(width: 440, height: 420))
                view.appearance = NSAppearance(named: appearance); view.frame = NSRect(x: 0, y: 0, width: 440, height: 420)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(2))
                #expect(view.fittingSize.width <= 441)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let output { try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(section.scrollID + "-" + appearance.rawValue + ".png")) }
            }
        }
    }

    @Test
    func bootstrapExplanationFitsInlineWithoutWideningThePanel() throws {
        let collapsed = NSHostingView(rootView: BootstrapQuitNotice(compact: true).frame(width: 380))
        let expanded = NSHostingView(rootView: BootstrapQuitNotice(showingDetails: true, compact: true).frame(width: 380))
        collapsed.layoutSubtreeIfNeeded(); expanded.layoutSubtreeIfNeeded()
        #expect(expanded.fittingSize.width == 380)
        #expect(expanded.fittingSize.height > collapsed.fittingSize.height)
    }

    private func waitUntil(diagnostic: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "Fixture state: \(diagnostic())")
    }
}
