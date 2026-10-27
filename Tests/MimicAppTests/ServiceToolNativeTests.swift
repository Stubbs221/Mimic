// Created by Василий Маслов on 16.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor @Suite(.serialized) struct ServiceToolNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_SERVICE_PROFILE"] != nil))
    func confirmedSettingsRouteEachChatAndDraftsCannotRedirectRequests() throws {
        let archive = try #require(ProcessInfo.processInfo.environment["MIMIC_SERVICE_PROFILE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServiceContext-" + UUID().uuidString)
        let snapshot = try ProfileStore(directory: root.appendingPathComponent("Profile")).importArchive(URL(fileURLWithPath: archive), requireInterface: true)
        let tool = try #require(snapshot.profile.serviceTools?.first), panel = try #require(snapshot.profile.panels?.first)
        let suite = "ServiceContext-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: root.appendingPathComponent("State"), defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        for path in tool.requiredFiles { let file = root.appendingPathComponent(path); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: file) }
        let project = ProjectContext(path: root.path), device = UUID().uuidString, application = panel.applications[0].id
        model.projects = [project]; model.selectedProjectPath = project.path; model.activeProfile = snapshot
        var record = TaskRecord(id: UUID(), action: .format, project: project)
        record.profileExecution = ProfileExecution(snapshot: snapshot, actionID: panel.actionID, parameters: ["device": device, "application": application, "values": "unconfirmed-draft"])
        record.panelResult = try JSONDecoder().decode(ProfilePanelResult.self, from: JSONSerialization.data(withJSONObject: ["status": "saved", "values": [tool.source.namespaceField: "fixture" + (tool.source.namespaceSuffixes?.first ?? ""), tool.source.appVersionField: "456"], "revision": "confirmed", "devices": [], "developerMode": true]))
        record.status = .succeeded; model.records = [record]
        let integration = MimicIntegration(model: model, defaults: defaults)
        for owner in ["chat-a", "chat-b"] { try integration.workspaceStore.save(PanelWorkspace(checkout: project.path, drafts: [panel.actionID: ["device": device, "application": application, "values": "unconfirmed-draft"]]), for: owner) }
        let config = try integration.serviceRequest(.init(method: "get_service_tool_configuration", parameters: ["toolID": .string(tool.id)], threadID: "chat-a"))
        #expect(config["context"]["namespace"] == .string("fixture")); #expect(config["context"]["appVersion"] == .string("456"))
        _ = try integration.serviceRequest(.init(method: "panel_service_save", parameters: ["toolID": .string(tool.id), "context": config["context"], "uid": .string("123"), "drafts": .object([:]), "clearRecent": .bool(false)], threadID: "chat-a"))
        let other = try integration.serviceRequest(.init(method: "get_service_tool_configuration", parameters: ["toolID": .string(tool.id)], threadID: "chat-b"))
        #expect(other["state"]["uid"] == .null)
        #expect(model.serviceContext(tool: tool, project: project, snapshot: snapshot, selection: [UUID().uuidString, application]).namespace.isEmpty)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_SERVICE_PROFILE"] != nil))
    func eightFormsFitMiniAndFullWithoutStartingLiveActions() async throws {
        _ = NSApplication.shared
        let archive = try #require(ProcessInfo.processInfo.environment["MIMIC_SERVICE_PROFILE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServiceNative-" + UUID().uuidString)
        let snapshot = try ProfileStore(directory: root.appendingPathComponent("Profile")).importArchive(URL(fileURLWithPath: archive), requireInterface: true)
        let tool = try #require(snapshot.profile.serviceTools?.first)
        let suite = "ServiceNative-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: root.appendingPathComponent("State"), defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path)
        let output = URL(fileURLWithPath: "/private/tmp/MimicServiceTools-20261016/native")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in PanelAppearance.allCases { for width: CGFloat in [258, 528] { for dark in [false, true] { for action in tool.actions {
            let form = ServiceToolForm(model: model, tool: tool, project: project, snapshot: snapshot)
            form.actionID = action.id; form.variantID = action.variants[0].id; form.uid = "18446744073709551615"
            form.context = .init(checkout: root.path, profileRevision: snapshot.revision, namespace: "qa-profile-preconditions-regression-xxxxxxxxxxxxxxxxxxxxxxxxxxxx", appVersion: "456", sourceRevision: "fixture")
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 4) {
                Text("Service fixture").mimicFont(.heading)
                ServiceToolView(form: form)
            }.padding(12).frame(width: width, height: 160, alignment: .topLeading).background(dark ? Color.black : Color.white).environment(\.mimicPanelAppearance, appearance).preferredColorScheme(dark ? .dark : .light))
            let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let controls = descendants(host).filter { ($0 as? NSTextField)?.isEditable == true || $0 is NSButton }
            for control in controls where !control.isHidden {
                let bounds = host.convert(control.bounds, from: control)
                #expect(bounds.minX >= 0 && bounds.maxX <= width + 1 && bounds.minY >= 0 && bounds.maxY <= 161, "Native service controls fit: \(action.id), \(appearance.rawValue), \(width)")
            }
            if action.id == tool.actions[0].id || action.variants[0].fields.filter({ !$0.advanced }).count == 2 {
                let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: image)
                try #require(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(appearance.rawValue)-\(Int(width))-\(dark)-\(action.id).png"))
            }
            window.contentView = nil; window.close()
        } } } }
        #expect(model.serviceTools.pendingCount == 0 && model.records.isEmpty)
    }
}
