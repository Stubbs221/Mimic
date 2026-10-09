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
        guard let fields = value.object, Set(fields.keys).isSubset(of: ["backend", "scheme", "configuration", "destinationID", "platform", "testPlan", "testIdentifiers", "workspaceTab"]), let backend = value["backend"].string.flatMap(BuildBackend.init(rawValue:)) else { throw BuildError.arguments }
        for key in ["scheme", "configuration", "destinationID", "testPlan", "workspaceTab"] { if let field = fields[key], field.string == nil { throw BuildError.arguments } }
        if let platform = fields["platform"], platform.string.flatMap(BootstrapPlatform.init(rawValue:)) == nil { throw BuildError.arguments }
        let identifiers = value["testIdentifiers"].array ?? []
        guard (fields["testIdentifiers"] == nil || value["testIdentifiers"].array != nil), identifiers.allSatisfy({ $0.string != nil }) else { throw BuildError.arguments }
        var result = BuildParameters(operation: operation, backend: backend, scheme: value["scheme"].string ?? "", configuration: value["configuration"].string ?? "", destinationID: value["destinationID"].string ?? "", platform: value["platform"].string.flatMap(BootstrapPlatform.init(rawValue:)), testPlan: value["testPlan"].string ?? "", testIdentifiers: identifiers.compactMap(\.string), workspaceTab: value["workspaceTab"].string ?? "")
        result.intent = intent
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
        var result: [String: BridgeValue] = ["id": .string(record.id.uuidString), "requestID": .string(record.id.uuidString), "title": .string(record.parameters.operation.rawValue), "status": .string(record.status.rawValue), "tracking": .string(record.tracking.rawValue), "phase": .string(record.phase), "source": .string(record.source), "createdAt": .string(record.createdAt.ISO8601Format()), "context": .object(["checkoutId": .string(record.project.path), "branch": .string(record.project.branch), "sha": .string(record.project.commit), "xcode": .string(record.selectedDeveloperDirectory ?? record.project.developerDirectory ?? ""), "profileID": record.profileID.map(BridgeValue.string) ?? .null, "profileRevision": record.profileRevision.map(BridgeValue.string) ?? .null]), "parameters": (try? BridgeValue.encode(record.parameters)) ?? .null, "diagnosticAvailable": .bool(record.diagnosticAvailable), "canCancel": .bool(record.canCancel), "truncated": .bool(record.truncated)]
        result["selectedXcode"] = record.selectedDeveloperDirectory.map(BridgeValue.string) ?? .null
        if var context = result["context"]?.object { context["appleTarget"] = (try? BridgeValue.encode(record.project.appleTarget)) ?? .null; result["context"] = .object(context) }
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
        result["products"] = (try? BridgeValue.encode(record.products)) ?? .null
        result["selectedProductID"] = record.selectedProductID.map(BridgeValue.string) ?? .null
        result["destinationName"] = record.destinationName.map(BridgeValue.string) ?? .null
        result["completedTestCount"] = record.completedTestCount.map { .number(Double($0)) } ?? .null
        result["selectedTestCount"] = record.selectedTestCount.map { .number(Double($0)) } ?? .null
        return .object(result)
    }
}
