// Created by Василий Маслов on 16.10.2026.
import Foundation
import MimicCore

extension TaskCoordinator {
    /// Only confirmed adapter results for the selected application can supply service routing.
    func serviceContext(tool: ServiceTool, project: ProjectContext, snapshot: ProfileSnapshot, selection: [String]) -> ServiceToolContext {
        let panel = snapshot.profile.panels?.first { $0.id == tool.source.panelID }
        let record = selection.count == 2 ? records.reversed().first { record in
            record.project.path == project.path && record.profileExecution?.snapshot.revision == snapshot.revision &&
            record.profileExecution?.actionID == panel?.actionID && record.profileExecution?.parameters["device"] == selection[0] &&
            record.profileExecution?.parameters["application"] == selection[1] &&
            ![.queued, .running].contains(record.status)
        } : nil
        // A newer failed/unavailable read invalidates routing from an older successful read.
        let value = record.flatMap { record in
            record.status == .succeeded && ["ready", "shutdown", "saved", "launchFailed"].contains(record.panelResult?.status ?? "") ? record.panelResult : nil
        }
        let raw = value?.values[tool.source.namespaceField] ?? ""
        let namespace = raw.hasSuffix(".ing") || raw.hasSuffix(".svc") ? String(raw.dropLast(4)) : raw
        return .init(checkout: project.path, profileRevision: snapshot.revision, namespace: ServiceTool.validNamespace(namespace) ? namespace : "", appVersion: value?.values[tool.source.appVersionField] ?? "", sourceRevision: (value?.revision ?? "") + ":" + selection.joined(separator: ":"))
    }
}

extension MimicIntegration {
    func serviceContext(tool: ServiceTool, threadID: String?) throws -> ServiceToolContext {
        guard let project = project(threadID), let snapshot = model.activeProfile, tool.matches(project.path) else { throw failure("context") }
        let selection: [String]
        if let threadID {
            let panel = snapshot.profile.panels?.first { $0.id == tool.source.panelID }
            let draft = workspaceStore.load(threadID).drafts[panel?.actionID ?? ""] ?? [:]
            selection = [draft["device"] ?? "", draft["application"] ?? ""]
        } else { selection = model.serviceSettingsSelection(checkout: project.path, panelID: tool.source.panelID) }
        return model.serviceContext(tool: tool, project: project, snapshot: snapshot, selection: selection)
    }
    /// Native ownership is derived from the bridge session, never accepted from tool arguments.
    func serviceRequest(_ request: MimicBridgeRequest) throws -> BridgeValue {
        let p = request.parameters, owner = request.threadID ?? "desktop"
        let keys: Set<String>
        switch request.method {
        case "get_service_tool_configuration", "panel_service_configuration": keys = ["toolID"]
        case "get_service_tool_result", "panel_service_result": keys = ["toolID", "context", "requestID"]
        case "panel_service_save": keys = ["toolID", "context", "uid", "drafts", "clearRecent"]
        default: keys = ["toolID", "context", "requestID", "actionID", "variantID", "uid", "parameters"]
        }
        guard Set(p.keys) == keys, let id = p["toolID"]?.string,
              let tool = model.activeProfile?.profile.serviceTools?.first(where: { $0.id == id }),
              request.method.hasPrefix("panel_") || tool.mcpAllowed else { throw failure("arguments") }
        let context = try serviceContext(tool: tool, threadID: request.threadID)
        let scope = ServiceToolCoordinator.scope(owner: owner, tool: id, context: context)
        if request.method.hasSuffix("configuration") {
            return .object(["tool": tool.catalog, "context": try BridgeValue.encode(context), "state": model.serviceTools.state(scope: scope)])
        }
        guard p["context"] == (try BridgeValue.encode(context)) else { throw failure("context") }
        if request.method == "panel_service_save" {
            guard let uid = p["uid"]?.string, let clear = p["clearRecent"], case .bool(let clearRecent) = clear,
                  let drafts = p["drafts"], let value = try? JSONDecoder().decode([String: [String: String]].self, from: JSONEncoder().encode(drafts)) else { throw failure("arguments") }
            try model.serviceTools.save(scope: scope, tool: tool, uid: uid, drafts: value, clearRecent: clearRecent)
            return model.serviceTools.state(scope: scope)
        }
        guard let requestID = p["requestID"]?.string.flatMap(UUID.init(uuidString:)) else { throw failure("arguments") }
        if request.method.hasSuffix("result") { return model.serviceTools.result(scope: scope, requestID: requestID) }
        guard !model.admissionsClosed, let snapshot = model.activeProfile, let action = p["actionID"]?.string, let variant = p["variantID"]?.string,
              let uid = p["uid"]?.string, let fields = p["parameters"]?.object, fields.values.allSatisfy({ $0.string != nil }) else { throw failure("arguments") }
        try model.verifyServiceProfile(snapshot)
        return try model.serviceTools.start(owner: owner, tool: tool, context: context, actionID: action, variantID: variant, uid: uid, values: fields.mapValues { $0.string! }, requestID: requestID) { [weak self] in
            guard let self, self.model.activeProfile?.revision == snapshot.revision else { return false }
            return (try? self.serviceContext(tool: tool, threadID: request.threadID)) == context
        }
    }
}
