// Created by Василий Маслов on 06.10.2026.
import AppKit
import SwiftUI
import UserNotifications
import MimicCore

extension MimicIntegration {
    /// Private UI operations do not expose drafts or terminal traffic to model-visible results.
    func panelRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        guard let threadID = request.threadID else { throw failure("context") }
        let p = request.parameters
        let keys: [String: Set<String>] = [
            "panel_get_workspace": [], "panel_save_workspace": ["workspace"], "panel_save_layout": ["layout", "expectedRevision"],
            "panel_setup": ["operation"], "panel_branches": [], "panel_switch_branch": ["branch", "context"],
            "panel_preview_generator": ["actionID", "parameters", "context", "requestID"], "panel_generate": ["actionID", "parameters", "context", "requestID"], "panel_get_preview": ["taskID"],
            "panel_terminal_open": ["taskID", "publicKey"], "panel_terminal_poll": ["channelID"], "panel_terminal_send": ["channelID", "packet"], "panel_terminal_close": ["channelID"], "panel_secret_input": ["taskID"], "panel_bootstrap_control": ["taskID", "operation"]]
        guard let allowed = keys[request.method], Set(p.keys) == allowed else { throw failure("arguments") }
        switch request.method {
        case "panel_get_workspace": return try BridgeValue.encode(workspaceStore.load(threadID))
        case "panel_save_workspace":
            var workspace = try JSONDecoder().decode(PanelWorkspace.self, from: JSONEncoder().encode(p["workspace"]!))
            workspace.checkout = workspaceStore.load(threadID).checkout
            // Only named non-secret profile fields and build form fields may be persisted.
            let permitted = Dictionary(uniqueKeysWithValues: (model.activeProfile?.profile.actions ?? []).map { ($0.id, Set($0.parameters.map(\.id))) })
            for (action, fields) in workspace.drafts {
                let allowed = action == "builds" ? Set(["backend", "scheme", "configuration", "destinationID", "workspaceTab", "testPlan", "testIdentifiers", "simulatorConfirmed"]) : permitted[action] ?? []
                guard Set(fields.keys).isSubset(of: allowed), fields.values.allSatisfy({ DiagnosticText.clean($0) == $0 }) else { throw failure("arguments") }
            }
            try workspaceStore.save(workspace, for: threadID); return .object(["saved": .bool(true)])
        case "panel_save_layout":
            guard let revision = p["expectedRevision"]?.integer else { throw failure("arguments") }
            let layout = try JSONDecoder().decode(PanelLayout.self, from: JSONEncoder().encode(p["layout"]!))
            do { return try BridgeValue.encode(layoutStore.save(layout, for: .codex, expectedRevision: revision)) }
            catch PanelLayoutError.conflict { throw failure("layoutConflict") }
        case "panel_setup":
            guard let operation = p["operation"]?.string else { throw failure("arguments") }
            if operation == "notifications" {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                defaults.set(granted, forKey: "setupNotifications")
                return .object(["done": .bool(granted)])
            }
            if operation == "credentials" { panelCredentials(project: project(threadID)); return .object(["done": .bool(true)]) }
            try await model.panelSetup(operation, project: project(threadID)); return .object(["done": .bool(true)])
        case "panel_bootstrap_control":
            guard let id = p["taskID"]?.string.flatMap(UUID.init(uuidString:)), let current = project(threadID),
                  let record = model.records.first(where: { $0.id == id && $0.project.path == current.path && $0.action == .bootstrap }),
                  record.status == .queued, model.launchState == .blockedByXcode(id) else { throw failure("notFound") }
            switch p["operation"]?.string {
            case "retry": model.retryBootstrap(id: id)
            case "activateXcode": model.activateBlockingXcode()
            default: throw failure("arguments")
            }
            return .object(["accepted": .bool(true)])
        case "panel_branches":
            guard let current = project(threadID) else { throw failure("context") }
            return .object(["branches": try BridgeValue.encode(try await model.panelBranches(current))])
        case "panel_switch_branch":
            let current = try expected(p["context"] ?? .null, threadID: threadID)
            guard let branch = p["branch"]?.string, !branch.isEmpty, branch.utf8.count <= 1024 else { throw failure("arguments") }
            try await model.switchPanelBranch(branch, project: current); return .object(["done": .bool(true)])
        case "panel_preview_generator", "panel_generate":
            guard let actionID = p["actionID"]?.string, model.activeProfile?.profile.actions.contains(where: { $0.id == actionID && $0.presentation == .generator && $0.allowsMCP }) == true else { throw failure("arguments") }
            return try await local(p, threadID: threadID, preview: request.method == "panel_preview_generator", allowGenerator: true)
        case "panel_get_preview":
            guard let id = p["taskID"]?.string.flatMap(UUID.init(uuidString:)), let record = model.records.first(where: { $0.id == id && $0.project.path == project(threadID)?.path }),
                  let execution = record.profileExecution, execution.preview else { throw failure("notFound") }
            guard record.status == .succeeded, let reviewed = model.profilePreviews[ProfilePreview.cacheKey(project: record.project, execution: execution)], reviewed.execution == execution else { return .object(["status": .string(record.status.rawValue)]) }
            return .object(["status": .string("succeeded"), "plan": try BridgeValue.encode(reviewed.plan)])
        default: return try await terminalRequest(request, threadID: threadID)
        }
    }

    /// Credentials enter Keychain directly from secure native fields, never HTML/MCP arguments.
    private func panelCredentials(project: ProjectContext?) {
        guard let project else { return }
        let settings = CISettingsModel(store: DefaultsCIConfigurationStore(defaults: defaults))
        settings.selectCheckout(project.path)
        settings.address = model.activeProfile?.profile.services?.gitLabURL ?? settings.address
        settings.projectPath = model.activeProfile?.profile.services?.gitLabProject ?? settings.projectPath
        let content = ScrollView { VStack(spacing: 16) {
            JenkinsSettingsView(settings: model.jenkinsSettings)
            CISettingsView(settings: settings, hasCheckout: true)
        }.padding(16) }.frame(width: 440, height: 600)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = text("panel.credentials.title"); window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        credentialsWindow = window
    }
}
