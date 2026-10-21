// Created by Василий Маслов on 16.10.2026.
import Foundation
import Testing
@testable import MimicCore

@Suite(.serialized) struct ProfilePanelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_PROFILE_PANEL_ARCHIVE"] != nil))
    func privateArchiveImportsWithoutExecutingAdapters() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MIMIC_PROFILE_PANEL_ARCHIVE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfilePanelImport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(directory: root)
        let snapshot = try store.importArchive(URL(fileURLWithPath: path), requireInterface: true)
        try store.verify(snapshot)
        let panel = try #require(snapshot.profile.panels?.first)
        #expect(panel.fields.count == 3)
        #expect(snapshot.profile.actions.first { $0.id == panel.actionID }?.logPolicy == .metadataOnly)
    }
    private func panel() throws -> ProfilePanel {
        try JSONDecoder().decode(ProfilePanel.self, from: Data(#"{"id":"settings","title":"Custom settings","actionID":"settings-action","requiredFiles":["marker"],"applications":[{"id":"demo","title":"Demo"}],"fields":[{"id":"first","title":"First"},{"id":"second","title":"Second"},{"id":"target","title":"Target","pattern":"^[a-z][a-z0-9-]{0,30}$","placeholder":"Default"}]}"#.utf8))
    }
    @Test func customIdentityPreservesLegacyLayoutEncoding() throws {
        #expect(try JSONDecoder().decode(PanelBlockKind.self, from: Data(#""builds""#.utf8)) == .builds)
        let block = try panel().block(profileID: "fixture.profile")
        #expect(block.isCustom)
        #expect(try JSONDecoder().decode(PanelBlockKind.self, from: JSONEncoder().encode(block)) == block)
        #expect(PanelBlockKind(rawValue: "profile:../bad:settings") == nil)
        var layout = PanelLayout.standard(for: .codex)
        try layout.add(block, size: .mini); try layout.validate(for: .codex)
        #expect(try JSONDecoder().decode(PanelLayout.self, from: JSONEncoder().encode(layout)) == layout)
    }
    @Test @MainActor func introductionIsOncePerSurfaceAndRespectsRemoval() throws {
        let suite = "ProfilePanelTests." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelLayoutStore(defaults: defaults), panel = try panel(), block = panel.block(profileID: "fixture")
        let first = store.introduce([panel], profileID: "fixture", checkout: "/fixture", surface: .desktop)
        #expect(first.size(of: block) == .mini)
        #expect(store.introduce([panel], profileID: "fixture", checkout: "/fixture", surface: .desktop) == first)
        var removed = first; removed.remove(block)
        _ = try store.save(removed, for: .desktop, expectedRevision: first.revision)
        #expect(!store.introduce([panel], profileID: "fixture", checkout: "/fixture", surface: .desktop).blocks.contains(block))
        #expect(store.introduce([panel], profileID: "fixture", checkout: "/fixture", surface: .codex).blocks.contains(block))
    }
    @Test func directActionsValidateIDsFieldsAndRevision() throws {
        let panel = try panel()
        var request = ["operation": "apply", "device": UUID().uuidString, "application": "demo", "values": #"{"first":"123","second":"","target":"testing-3"}"#, "field": "", "expectedRevision": "snapshot", "force": "false"]
        try panel.validateRequest(request)
        request["values"] = #"{"first":"0","second":"","target":"testing"}"#
        #expect(throws: (any Error).self) { try panel.validateRequest(request) }
        request["values"] = #"{"first":"123","second":"","target":"https://bad"}"#
        #expect(throws: (any Error).self) { try panel.validateRequest(request) }
        request["operation"] = "reset"; request["values"] = "{}"; request["field"] = "unrelated"
        #expect(throws: (any Error).self) { try panel.validateRequest(request) }
        request["field"] = "first"; request["expectedRevision"] = ""
        #expect(throws: (any Error).self) { try panel.validateRequest(request) }
    }
    @Test func resultsRejectForeignFieldsAndUnboundedOutput() throws {
        let panel = try panel()
        let valid = #"MIMIC_PANEL_RESULT {"status":"saved","values":{"first":"123","target":"testing"},"revision":"r1","devices":[],"developerMode":true}"#
        #expect(ProfilePanelResult.parse(Data(("untrusted output\n" + valid + "\r\n").utf8), panel: panel)?.values["first"] == "123")
        #expect(ProfilePanelResult.parse(Data(valid.replacingOccurrences(of: "first", with: "foreign").utf8), panel: panel) == nil)
        #expect(ProfilePanelResult.parse(Data(valid.replacingOccurrences(of: "saved", with: "arbitrary").utf8), panel: panel) == nil)
        #expect(ProfilePanelResult.parse(Data(valid.replacingOccurrences(of: "123", with: "0").utf8), panel: panel) == nil)
        for revision in ["ghp_fixturecredential", "r1\\ncontrol"] {
            #expect(ProfilePanelResult.parse(Data(valid.replacingOccurrences(of: "r1", with: revision).utf8), panel: panel) == nil)
        }
        let digest = String(repeating: "abcdef0123456789", count: 4)
        #expect(ProfilePanelResult.parse(Data(valid.replacingOccurrences(of: "r1", with: digest).utf8), panel: panel)?.revision == digest)
    }
    @Test func scalarPatternsMatchTheEntireValue() throws {
        let field = try JSONDecoder().decode(ProfilePanel.Field.self, from: Data(#"{"id":"target","title":"Target","pattern":"[a-z]+"}"#.utf8))
        #expect(field.accepts("testing"))
        #expect(!field.accepts("123testing"))
        #expect(!field.accepts("testing\n"))
    }
    @Test func descriptorIsOptionalAndCannotBindBuiltInRoles() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Mimic11/profile.json")
        var profile = try JSONDecoder().decode(MimicProfile.self, from: Data(contentsOf: path))
        try ProfilePanel.validate(profile: profile)
        profile.panels = [try panel()]
        #expect(throws: (any Error).self) { try ProfilePanel.validate(profile: profile) }
    }
}
