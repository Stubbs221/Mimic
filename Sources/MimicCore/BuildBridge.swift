// Created by Василий Маслов on 04.10.2026.
import Foundation

/// The same strict payload is used by Codex and the bundled terminal client.
public enum BuildBridge {
    public static let tools = ["start_build_configuration", "get_build_configuration_state", "get_build_configuration", "build_project", "run_selected_tests", "get_build_activity", "cancel_build_activity", "get_build_diagnostic", "get_build_readiness", "wait_build_activity", "get_build_result"]
    public static func context(_ value: BridgeValue) throws -> ProjectContext {
        guard let fields = value.object, Set(fields.keys).isSubset(of: ["checkoutId", "branch", "sha", "xcode", "appleTarget", "profileID", "profileRevision"]), let path = value["checkoutId"].string, let branch = value["branch"].string, let sha = value["sha"].string, let xcode = value["xcode"].string else { throw BuildError.context }
        let target = value["appleTarget"] == .null ? nil : try JSONDecoder().decode(AppleTarget.self, from: JSONEncoder().encode(value["appleTarget"]))
        return ProjectContext(path: path, branch: branch, commit: sha, developerDirectory: xcode.isEmpty ? nil : xcode, appleTarget: target)
    }
    public static func parameters(_ value: BridgeValue, operation: BuildOperation, intent: BuildIntent? = nil) throws -> BuildParameters {
        guard let fields = value.object else { throw WorkflowFieldError("invalidObject", field: "parameters") }
        let allowed: Set<String> = ["backend", "scheme", "configuration", "destinationID", "platform", "testPlan", "testIdentifiers", "workspaceTab"]
        if let key = fields.keys.sorted().first(where: { !allowed.contains($0) }) { throw WorkflowFieldError("unknownField", field: "parameters." + key) }
        guard let backend = value["backend"].string.flatMap(BuildBackend.init(rawValue:)), intent != .catalogue || backend == .cli else { throw WorkflowFieldError("unsupportedBackend", field: "parameters.backend") }
        for key in ["scheme", "configuration", "destinationID", "testPlan", "workspaceTab"] {
            if let field = fields[key] {
                guard let string = field.string, string.utf8.count <= 1024, !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw WorkflowFieldError("invalidString", field: "parameters." + key, limit: 1024) }
            }
        }
        if let platform = fields["platform"], platform.string.flatMap(BootstrapPlatform.init(rawValue:)) == nil { throw WorkflowFieldError("invalidPlatform", field: "parameters.platform") }
        let identifiers = value["testIdentifiers"].array ?? []
        guard (fields["testIdentifiers"] == nil || value["testIdentifiers"].array != nil), identifiers.allSatisfy({ $0.string != nil }) else { throw WorkflowFieldError("invalidIdentifiers", field: "parameters.testIdentifiers") }
        var result = BuildParameters(operation: operation, backend: backend, scheme: value["scheme"].string ?? "", configuration: value["configuration"].string ?? "", destinationID: value["destinationID"].string ?? "", platform: value["platform"].string.flatMap(BootstrapPlatform.init(rawValue:)), testPlan: value["testPlan"].string ?? "", testIdentifiers: identifiers.compactMap(\.string), workspaceTab: value["workspaceTab"].string ?? "")
        guard identifiers.count <= WorkflowContract.pageSize else { throw WorkflowFieldError("capacity", field: "testIdentifiers", limit: WorkflowContract.pageSize) }
        result.intent = intent
        if backend == .cli {
            if result.scheme.isEmpty { throw WorkflowFieldError("requiredField", field: "parameters.scheme") }
            if result.configuration.isEmpty { throw WorkflowFieldError("requiredField", field: "parameters.configuration") }
            if UUID(uuidString: result.destinationID) == nil { throw WorkflowFieldError("invalidUUID", field: "parameters.destinationID") }
            if !result.workspaceTab.isEmpty { throw WorkflowFieldError("incompatibleField", field: "parameters.workspaceTab") }
        }
        try result.validate(); return result
    }
    /// Polling and the model context carry counts instead of copying a potentially large selected-test list.
    public static func summary(_ record: BuildActivity) -> BridgeValue {
        var value = metadata(record).object ?? [:]
        var parameters = value["parameters"]?.object ?? [:]
        parameters["testIdentifiers"] = nil
        parameters["testCount"] = .number(Double(record.parameters.testIdentifiers.count))
        value["parameters"] = .object(parameters)
        return .object(value)
    }
    public static func metadata(_ record: BuildActivity) -> BridgeValue {
        var publicParameters = record.parameters
        publicParameters.testIdentifiers = Array(record.parameters.testIdentifiers.prefix(100))
        var parameters = (try? BridgeValue.encode(publicParameters).object) ?? [:]
        parameters["testCount"] = .number(Double(record.parameters.testIdentifiers.count))
        parameters["testIdentifiersTruncated"] = .bool(record.parameters.testIdentifiers.count > 100)
        var result: [String: BridgeValue] = ["id": .string(record.id.uuidString), "requestID": .string(record.id.uuidString), "title": .string(record.parameters.operation.rawValue), "status": .string(record.status.rawValue), "tracking": .string(record.tracking.rawValue), "phase": .string(record.phase), "source": .string(record.source), "createdAt": .string(record.createdAt.ISO8601Format()), "context": .object(["checkoutId": .string(record.project.path), "branch": .string(record.project.branch), "sha": .string(record.project.commit), "xcode": .string(record.project.developerDirectory ?? ""), "profileID": record.profileID.map(BridgeValue.string) ?? .null, "profileRevision": record.profileRevision.map(BridgeValue.string) ?? .null]), "parameters": .object(parameters), "diagnosticAvailable": .bool(record.diagnosticAvailable), "canCancel": .bool(record.canCancel), "truncated": .bool(record.truncated)]
        result["selectedXcode"] = record.selectedDeveloperDirectory.map(BridgeValue.string) ?? .null
        if var context = result["context"]?.object { context["appleTarget"] = (try? BridgeValue.encode(record.project.appleTarget)) ?? .null; result["context"] = .object(context) }
        result["admissionContext"] = result["context"]
        var execution = result["context"]?.object ?? [:]; execution["xcode"] = .string(record.selectedDeveloperDirectory ?? record.project.developerDirectory ?? "")
        result["executionContext"] = .object(execution)
        result["catalogueCache"] = .object(["status": .string(record.catalogueReusedFrom == nil ? "cacheMiss" : "cacheHit"), "reason": record.catalogueCacheReason.map(BridgeValue.string) ?? .null, "reusedFrom": record.catalogueReusedFrom.map { .string($0.uuidString) } ?? .null])
        result["queuePosition"] = record.queuePosition.map { .number(Double($0)) } ?? .null
        result["workflowPendingCount"] = record.workflowPendingCount.map { .number(Double($0)) } ?? .null
        result["verificationSummary"] = (try? .encode(record.verificationSummary)) ?? .null
        result["owner"] = record.owner.map(BridgeValue.string) ?? .null
        result["stageStartedAt"] = record.stageStartedAt.map { .string($0.ISO8601Format()) } ?? .null
        result["stageDurations"] = (try? .encode(record.stageDurations)) ?? .null
        result["processOutcome"] = record.processOutcome.map(BridgeValue.string) ?? .null
        result["cancellationOutcome"] = record.cancellationOutcome.map(BridgeValue.string) ?? .null
        result["needsInput"] = .bool(record.needsInput == true)
        result["xcodeRequestID"] = record.xcodeRequestID.map(BridgeValue.string) ?? .null
        result["startedAt"] = record.startedAt.map { .string($0.ISO8601Format()) } ?? .null
        result["finishedAt"] = record.finishedAt.map { .string($0.ISO8601Format()) } ?? .null
        result["exitCode"] = record.exitCode.map { .number(Double($0)) } ?? .null
        result["duration"] = .number(record.duration)
        result["errorCount"] = record.errorCount.map { .number(Double($0)) } ?? .null
        result["warningCount"] = record.warningCount.map { .number(Double($0)) } ?? .null
        result["errorCode"] = record.errorCode.map(BridgeValue.string) ?? .null
        result["resultBundlePath"] = record.resultBundlePath.map(BridgeValue.string) ?? .null
        result["resultSummaryPath"] = record.resultSummaryPath.map(BridgeValue.string) ?? .null
        result["workflowID"] = record.workflowID.map(BridgeValue.string) ?? .null
        result["revision"] = .number(Double(record.stateRevision ?? 0))
        result["actionKey"] = .string(record.actionKey)
        result["stage"] = record.stage.map { .string($0.rawValue) } ?? .null
        result["completedStages"] = record.completedStages.map { .number(Double($0)) } ?? .null
        result["progressTotal"] = .number(Double(record.progressTotal))
        result["progressFraction"] = record.progressFraction.map(BridgeValue.number) ?? .null
        result["debuggerAttached"] = record.debuggerAttached.map(BridgeValue.bool) ?? .null
        result["debuggerProcessID"] = record.debuggerProcessID.map { .number(Double($0)) } ?? .null
        result["products"] = (try? BridgeValue.encode(record.products)) ?? .null
        result["selectedProductID"] = record.selectedProductID.map(BridgeValue.string) ?? .null
        result["destinationName"] = record.destinationName.map(BridgeValue.string) ?? .null
        result["completedTestCount"] = record.completedTestCount.map { .number(Double($0)) } ?? .null
        result["selectedTestCount"] = record.selectedTestCount.map { .number(Double($0)) } ?? .null
        return .object(result)
    }
}
