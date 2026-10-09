// Created by Василий Маслов on 09.10.2026.
import Foundation
import MimicCore

extension MimicIntegration {
    /// App-only actions never become model-visible tools. Every await rechecks the chat's exact context.
    func panelBuildRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        let p = request.parameters
        guard Set(p.keys) == ["context", "operation", "parameters", "requestID", "activityID", "productID"], let operation = p["operation"]?.string else { throw BuildError.arguments }
        let context = p["context"] ?? .null
        let project = try expected(context, threadID: request.threadID)
        let pinned = try await BuildDiscovery.pinned(project)
        _ = try expected(context, threadID: request.threadID)
        let developer = pinned.developerDirectory ?? ""
        if operation == "get" {
            let draft = model.builds.panelDraft(project: project, developer: developer)
            return .object(["context": context, "developerDirectory": .string(developer), "draft": try BridgeValue.encode(draft), "catalogue": model.builds.testCatalogue(project: project, parameters: draft, developer: developer).flatMap { try? BridgeValue.encode($0) } ?? .null])
        }
        if operation == "product" {
            guard let id = p["activityID"]?.string.flatMap(UUID.init(uuidString:)), let record = model.builds.records.first(where: { $0.id == id && $0.project == project }), canAccess(record.project, threadID: request.threadID), let product = p["productID"]?.string else { throw BuildError.context }
            try model.builds.chooseProduct(product, activityID: id); return BuildBridge.summary(record)
        }
        guard let fields = p["parameters"]?.object, Set(fields.keys).isSubset(of: ["operation", "backend", "scheme", "configuration", "destinationID", "platform", "testPlan", "testIdentifiers", "workspaceTab", "simulatorConfirmed", "developerDirectory"]), fields["simulatorConfirmed"] == nil || fields["simulatorConfirmed"] == .bool(true) || fields["simulatorConfirmed"] == .bool(false) else { throw BuildError.arguments }
        guard fields["developerDirectory"]?.string == developer else { throw BuildError.context }
        var parameters = try JSONDecoder().decode(BuildParameters.self, from: JSONEncoder().encode(p["parameters"]!))
        guard ([parameters.scheme, parameters.configuration, parameters.destinationID, parameters.workspaceTab, parameters.testPlan] + parameters.testIdentifiers).allSatisfy({ $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }), parameters.testIdentifiers.count <= 100 else { throw BuildError.arguments }
        if operation == "save" { model.builds.savePanelDraft(parameters, project: project, developer: developer); return .object(["saved": .bool(true)]) }
        guard ["build", "run", "tests", "catalogue"].contains(operation), let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)) else { throw BuildError.arguments }
        // Retries retain their request ID. Another manual click cannot queue a second run during admission.
        guard model.builds.records.contains(where: { $0.id == id }) || model.builds.admittingCount == 0 && !model.builds.records.contains(where: { $0.project == project && $0.status.isPending }) else { throw BuildError.capacity }
        parameters.operation = operation == "tests" ? .test : .build
        parameters.intent = operation == "run" ? .run : operation == "catalogue" ? .catalogue : nil
        if parameters.operation == .build { parameters.testIdentifiers = []; if operation != "catalogue" { parameters.testPlan = "" } }
        if parameters.backend == .xcodeMCP { parameters.scheme = ""; parameters.configuration = ""; parameters.destinationID = ""; parameters.testPlan = ""; parameters.platform = nil }
        try parameters.validate()
        let record = try await model.builds.submit(id: id, project: project, parameters: parameters, source: "Codex · вручную", simulatorConfirmed: fields["simulatorConfirmed"] == .bool(true))
        _ = try expected(context, threadID: request.threadID)
        return BuildBridge.summary(record)
    }
}
