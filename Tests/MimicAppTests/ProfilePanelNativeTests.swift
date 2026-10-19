// Created by Василий Маслов on 16.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct ProfilePanelNativeTests {
    @Test func profileControlsShareQueueStructuredResultAndRequestIdentity() async throws {
        let suite = "ProfilePanelQueue-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Fixture"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", arguments, directory: root.path).0 == 0)
        }
        try Data().write(to: root.appendingPathComponent("marker"))
        var manifest = try #require(JSONSerialization.jsonObject(with: Profile11Fixture.data()) as? [String: Any])
        let panel: [String: Any] = ["id": "settings", "title": "Fixture settings", "actionID": "settings", "requiredFiles": ["marker"], "applications": [["id": "demo", "title": "Demo"]], "fields": [["id": "first", "title": "First"], ["id": "second", "title": "Second"]]]
        manifest["panels"] = [panel]
        let output = #"MIMIC_PANEL_RESULT {"status":"saved","values":{"first":"123","second":"456"},"revision":"r1","devices":[],"developerMode":true}"# + "\n"
        var actions = try #require(manifest["actions"] as? [[String: Any]])
        let parameters = ProfilePanel.parameterIDs.sorted().map { ["id": $0, "title": $0, "kind": "text", "defaultValue": "", "required": false] as [String: Any] }
        actions.append(["id": "settings", "title": "Fixture settings", "presentation": "regular", "logPolicy": "metadataOnly", "mcpAllowed": true, "requiresXcodeQuit": false, "requiredFiles": [], "requiredTools": [], "parameters": parameters, "steps": [["executable": "/usr/bin/printf", "arguments": ["%s", output], "directory": "${checkout}"]]])
        manifest["actions"] = actions
        let storage = root.appendingPathComponent("Storage"), snapshot = try Profile11Fixture.install(directory: storage, data: JSONSerialization.data(withJSONObject: manifest))
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TaskHost")
        let model = TaskCoordinator(directory: storage, helperURL: helper, defaults: defaults)
        defer { model.records = []; model.stopAndExit() }
        let project = try EnvironmentInspector.project(path: root.path)
        model.projects = [project]; model.selectedProjectPath = project.path; model.activeProfile = snapshot
        let integration = MimicIntegration(model: model, defaults: defaults)
        let owner = "fixture-panel"
        try integration.workspaceStore.save(PanelWorkspace(checkout: project.path), for: owner)
        let id = UUID().uuidString
        let values = ["operation": "apply", "device": UUID().uuidString, "application": "demo", "values": #"{"first":"123","second":"456"}"#, "field": "", "expectedRevision": "r0", "force": "false"]
        var parametersValue: [String: BridgeValue] = ["actionID": .string("settings"), "parameters": try .encode(values), "context": MimicIntegration.context(project, profile: snapshot), "requestID": .string(id)]
        let request = MimicBridgeRequest(method: "panel_profile_control", parameters: parametersValue, threadID: owner)
        let first = try await integration.handle(request), duplicate = try await integration.handle(request)
        #expect(first["id"].string == id && duplicate["id"].string == id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.records.contains(where: { [.queued, .running].contains($0.status) }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let record = try #require(model.records.first { $0.id.uuidString == id })
        #expect(record.status == .succeeded && record.panelResult?.values["first"] == "123" && record.logPath == nil)
        #expect(model.records.count == 1)
        var changed = values; changed["values"] = #"{"first":"999","second":"456"}"#
        parametersValue["parameters"] = try .encode(changed)
        await #expect(throws: (any Error).self) { try await integration.handle(.init(method: "panel_profile_control", parameters: parametersValue, threadID: owner)) }
    }
    @Test func compactFieldsFitBothSizesAndEveryAppearanceWithoutLiveActions() async throws {
        let suite = "ProfilePanelNative-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let profile = try JSONDecoder().decode(MimicProfile.self, from: Data(#"{"schemaVersion":1,"id":"fixture","version":"1","title":"Fixture","requiredFiles":[],"actions":[],"panels":[{"id":"settings","title":"Custom settings","actionID":"settings","requiredFiles":["marker"],"applications":[{"id":"demo","title":"Demo application"}],"fields":[{"id":"first","title":"First ID"},{"id":"second","title":"Second ID"},{"id":"target","title":"Environment","pattern":"^[a-z]+$","placeholder":"Default"}]}]}"#.utf8))
        let panel = try #require(profile.panels?.first), snapshot = ProfileSnapshot(profile: profile, revision: "fixture", directory: directory.path)
        let project = ProjectContext(path: directory.path), output = URL(fileURLWithPath: "/private/tmp/MimicCustomPanel-20261016/native")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in PanelAppearance.allCases {
            for width: CGFloat in [258, 528] {
                let form = ProfilePanelForm(model: model, panel: panel, project: project, snapshot: snapshot, defaults: defaults)
                form.device = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"; form.application = "demo"
                form.result = try JSONDecoder().decode(ProfilePanelResult.self, from: Data(#"{"status":"ready","values":{"first":"123","second":"456","target":"testing"},"revision":"r1","devices":[{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","title":"Demo simulator"}],"developerMode":true}"#.utf8))
                form.values = form.result!.values
                let root = NSHostingView(rootView: VStack(alignment: .leading, spacing: 4) {
                    Text(panel.title).mimicFont(.heading)
                    ProfilePanelView(form: form, full: width > 300)
                }.padding(12).background(Color.white).frame(width: width, height: 160, alignment: .topLeading).environment(\.mimicPanelAppearance, appearance))
                let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = root; window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(50)); root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
                let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(appearance.rawValue + "-" + String(Int(width)) + ".png"))
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let fields = descendants(root).compactMap { $0 as? NSTextField }.filter(\.isEditable)
                #expect(fields.count >= 3)
                for field in fields {
                    let rect = root.convert(field.bounds, from: field)
                    #expect(rect.minX >= 0 && rect.maxX <= width && rect.minY >= 0 && rect.maxY <= 160)
                }
                window.contentView = nil; window.close()
            }
        }
        #expect(model.records.isEmpty)
    }
}
