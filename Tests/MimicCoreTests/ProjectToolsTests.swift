// Created by Василий Маслов on 07.10.2026.
import Foundation
import Testing
@testable import MimicCore

@MainActor struct ProjectToolsTests {
    @Test func favoritesAreSharedOrderedAndRejectStaleWrites() throws {
        let name = "ProjectTools-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let a = ToolsPreferencesStore(defaults: defaults), b = ToolsPreferencesStore(defaults: defaults)
        #expect(a.load().favorites == [.generation, .localization, .format])
        let first = try a.save([.proto, .format], expectedRevision: 0)
        #expect(b.load() == first)
        #expect(throws: PanelLayoutError.conflict) { try b.save([.generation], expectedRevision: 0) }
        #expect(throws: PanelLayoutError.invalid) { try a.save([.proto, .proto], expectedRevision: first.revision) }
        #expect(throws: PanelLayoutError.invalid) { try a.save([.proto, .format, .generation, .fullCleanup], expectedRevision: first.revision) }
        #expect(try b.save([], expectedRevision: first.revision).favorites == ToolsPreferences.standard)
    }
    @Test func taskPriorityIsCheckoutScopedAndSkipsPreviews() throws {
        let project = ProjectContext(path: "/private/tmp/tools-fixture"), other = ProjectContext(path: "/private/tmp/other-tools-fixture")
        var finished = TaskRecord(action: .format, project: project); finished.status = .succeeded; finished.finishedAt = .now
        var queued = TaskRecord(action: .format, project: project)
        var later = TaskRecord(action: .format, project: project)
        queued.status = .queued; later.status = .queued
        var running = TaskRecord(action: .format, project: project); running.status = .running
        let wrong = TaskRecord(action: .format, project: other)
        #expect(ProjectTool.format.record(in: [finished, later, wrong, queued, running], checkout: project.path)?.id == running.id)
        #expect(ProjectTool.format.record(in: [finished, later, wrong, queued], checkout: project.path)?.id == queued.id)
        #expect(ProjectTool.format.record(in: [finished, wrong], checkout: project.path)?.id == finished.id)
        let profile = try JSONDecoder().decode(MimicProfile.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Mimic11/profile.json")))
        let snapshot = ProfileSnapshot(profile: profile, revision: "fixture", directory: "/private/tmp")
        let execution = try snapshot.execution(role: .generateUI, values: [.name: "Header"], preview: true)
        var preview = execution.record(id: UUID(), project: project); preview.status = .succeeded
        #expect(ProjectTool.identify(preview) == .generation)
        #expect(ProjectTool.generation.record(in: [preview], checkout: project.path) == nil)
    }
    @Test func oldWorkspacesDecodeAndToolNavigationRoundTrips() throws {
        let old = try JSONDecoder().decode(PanelWorkspace.self, from: Data(#"{"checkout":"/fixture","drafts":{}}"#.utf8))
        #expect(old.toolSelection == nil && old.toolGenerator == nil)
        let updated = PanelWorkspace(checkout: "/fixture", expanded: .utils, drafts: ["generate-ui": ["name": "Header"]], toolSelection: .generation, toolGenerator: .module)
        #expect(try JSONDecoder().decode(PanelWorkspace.self, from: JSONEncoder().encode(updated)) == updated)
    }
}
