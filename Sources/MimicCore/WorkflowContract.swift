//
//  WorkflowContract.swift
//  MimicCore
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation

/// Shared bounds and field errors for native admission, CLI and the published tool schemas.
public enum WorkflowContract {
    public static let pageSize = 100
    public static let maximumMethods = 10_000
    public static let pendingBudget = 3
    public static let maximumWaitMilliseconds = 25_000
    public static let tools = ["create_test_selection", "append_test_selection", "finalize_test_selection", "get_test_selection", "cancel_workflow_pending", "get_test_facts", "start_ci_evidence", "get_ci_evidence", "list_test_artifacts", "get_test_artifact"]
    public static let mutations: Set<String> = ["create_test_selection", "append_test_selection", "finalize_test_selection", "cancel_workflow_pending"]

    public struct ToolRule: Sendable {
        public let fields: [String: BridgeValue]
        public let required: Set<String>
        public let description: String
    }
    public static var rules: [String: ToolRule] {
        let string: BridgeValue = .object(["type": .string("string"), "maxLength": .number(4096)])
        let uuid: BridgeValue = .object(["type": .string("string"), "format": .string("uuid")])
        let page: BridgeValue = .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(Double(pageSize))])
        let context: BridgeValue = .object(["type": .string("object"), "properties": .object(Dictionary(uniqueKeysWithValues: ["checkoutId", "branch", "sha", "xcode"].map { ($0, string) }).merging(["appleTarget": .object(["type": .array([.string("object"), .string("null")])]), "profileID": .object(["type": .array([.string("string"), .string("null")])]), "profileRevision": .object(["type": .array([.string("string"), .string("null")])])], uniquingKeysWith: { _, value in value })), "required": .array(["checkoutId", "branch", "sha", "xcode", "appleTarget", "profileID", "profileRevision"].map(BridgeValue.string)), "additionalProperties": .bool(false)])
        let identifiers: BridgeValue = .object(["type": .string("array"), "items": .object(["type": .string("string"), "maxLength": .number(1024)]), "minItems": .number(1), "maxItems": .number(Double(pageSize))])
        func rule(_ fields: [String: BridgeValue], _ required: Set<String>, _ description: String) -> ToolRule { .init(fields: fields, required: required, description: description) }
        return [
            "create_test_selection": rule(["catalogueID": uuid, "context": context, "requestID": uuid], ["catalogueID", "context", "requestID"], "Create a caller-owned draft pinned to a fresh native catalogue. Does not run tests."),
            "append_test_selection": rule(["selectionID": uuid, "testIdentifiers": identifiers, "requestID": uuid], ["selectionID", "testIdentifiers", "requestID"], "Append up to 100 exact method IDs idempotently. Draft capacity is 10000 unique methods."),
            "finalize_test_selection": rule(["selectionID": uuid, "context": context, "cursor": string, "limit": page], ["selectionID", "context"], "Freeze a fresh exact selection; unknown or disabled IDs prevent finalization. Errors are paginated."),
            "get_test_selection": rule(["selectionID": uuid, "cursor": string, "limit": page], ["selectionID"], "Read selection count, digest, expiry and paginated exact IDs. Never resumes execution."),
            "cancel_workflow_pending": rule(["workflowID": uuid, "requestID": uuid], ["workflowID", "requestID"], "Cancel only caller-owned queued workflow activities. Running and foreign work are preserved."),
            "get_test_facts": rule(["activityID": uuid, "cursor": string, "limit": page], ["activityID"], "Read persisted method/case/execution facts in pages up to 100. Does not repeat tests."),
            "start_ci_evidence": rule(["snapshotID": uuid], ["snapshotID"], "Read-only collection for a native-pinned CI snapshot. No logs, job retries or new authorization."),
            "get_ci_evidence": rule(["queryID": uuid, "cursor": string, "limit": page], ["queryID"], "Read bounded CI evidence, completeness and provenance. Default failure-test page is 50."),
            "list_test_artifacts": rule(["activityID": uuid, "methodID": string, "cursor": string, "limit": page], ["activityID", "methodID"], "List immutable image attachments from this activity's xcresult for one exact method."),
            "get_test_artifact": rule(["artifactID": uuid], ["artifactID"], "Read one native image handle and bounded preview; original digest and provenance remain separate.")
        ]
    }

    public static func validate(_ parameters: [String: BridgeValue], method: String) throws {
        guard let rule = rules[method] else { throw WorkflowFieldError("unknownMethod", field: "method") }
        if let unexpected = parameters.keys.sorted().first(where: { rule.fields[$0] == nil }) { throw WorkflowFieldError("unknownField", field: unexpected) }
        if let missing = rule.required.sorted().first(where: { parameters[$0] == nil }) { throw WorkflowFieldError("requiredField", field: missing) }
        for (key, value) in parameters {
            if key == "limit" { guard let limit = value.integer, (1...pageSize).contains(limit) else { throw WorkflowFieldError("outOfRange", field: key, limit: pageSize) } }
            else if key == "context" { guard value.object != nil else { throw WorkflowFieldError("invalidContext", field: key) } }
            else if key == "testIdentifiers" { guard let ids = value.array, !ids.isEmpty, ids.count <= pageSize, ids.allSatisfy({ $0.string.map(identifier) == true }) else { throw WorkflowFieldError("invalidIdentifiers", field: key, limit: pageSize) } }
            else {
                guard let text = value.string, text.utf8.count <= 4096, !text.contains("\0") else { throw WorkflowFieldError("invalidString", field: key) }
                if key.hasSuffix("ID"), key != "methodID", UUID(uuidString: text) == nil { throw WorkflowFieldError("invalidUUID", field: key) }
            }
        }
    }

    public static func identifier(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && value.utf8.count <= 1024 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains("*") }
    }
}

/// Safe validation information; submitted values and credentials are never reflected in errors.
public struct WorkflowFieldError: Error, Sendable {
    public let code: String
    public let field: String
    public let limit: Int?
    public let existingActivityID: UUID?
    public init(_ code: String, field: String, limit: Int? = nil, existingActivityID: UUID? = nil) {
        self.code = code; self.field = field; self.limit = limit; self.existingActivityID = existingActivityID
    }
    public var payload: BridgeValue {
        .object(["status": .string("blocked"), "code": .string(code), "field": .string(field), "limit": limit.map { .number(Double($0)) } ?? .null,
                 "existingActivityID": existingActivityID.map { .string($0.uuidString) } ?? .null,
                 "nextStep": .string(["busy", "resultsPending"].contains(code) ? "observeExistingActivity" : "correctField")])
    }
}

/// Selections are durable native-owned handles; draft pages never authorize execution.
public struct TestSelectionStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.appendingPathComponent("Selections") }
    public func load(_ id: UUID) throws -> VerifiedTestSelection? {
        let path = root.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let attributes = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) < 64 * 1024 * 1024 else { throw BuildError.arguments }
        return try JSONDecoder().decode(VerifiedTestSelection.self, from: Data(contentsOf: path))
    }
    public func save(_ selection: VerifiedTestSelection) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent(selection.id.uuidString + ".json")
        if !FileManager.default.fileExists(atPath: path.path), try FileManager.default.contentsOfDirectory(atPath: root.path).count >= 1024 { throw WorkflowFieldError("capacity", field: "selectionID", limit: 1024) }
        try JSONEncoder().encode(selection).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public func append(_ ids: [String], requestID: UUID, to selection: inout VerifiedTestSelection) throws {
        guard !selection.expired else { throw BuildError.selectionExpired }
        guard !ids.isEmpty, ids.count <= WorkflowContract.pageSize, ids.allSatisfy(WorkflowContract.identifier) else { throw WorkflowFieldError("invalidIdentifiers", field: "testIdentifiers", limit: WorkflowContract.pageSize) }
        let digest = SourceRevisionReader.hash(try JSONEncoder().encode(ids))
        if let previous = selection.pageReceipts?[requestID.uuidString] {
            guard previous == digest else { throw BuildError.duplicate }; return
        }
        guard selection.state == "draft" else { throw WorkflowFieldError("selectionFinalized", field: "selectionID") }
        let merged = Set(selection.parameters.testIdentifiers).union(ids)
        guard merged.count <= WorkflowContract.maximumMethods else { throw WorkflowFieldError("capacity", field: "testIdentifiers", limit: WorkflowContract.maximumMethods) }
        selection.parameters.testIdentifiers = merged.sorted()
        var receipts = selection.pageReceipts ?? [:]; receipts[requestID.uuidString] = digest; selection.pageReceipts = receipts
        guard receipts.count <= 10_000 else { throw BuildError.capacity }
    }
}

/// Response files avoid argv limits without expanding selection or invoking a shell.
public enum TestSelectionCommand {
    public static func prepare(_ command: CommandSpec, record: BuildActivity, root: URL, supportsResponseFile: Bool, argumentBudget: Int = 128 * 1024) throws -> CommandSpec {
        guard record.parameters.operation == .test, command.executable == "/usr/bin/xcrun", command.arguments.first == "xcodebuild", record.parameters.testTarget == nil else { return command }
        guard supportsResponseFile else {
            let size = command.arguments.reduce(0) { $0 + $1.utf8.count + 1 } + command.environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 2 }
            guard size <= argumentBudget else { throw BuildError.selectionTooLargeForToolchain }
            return command
        }
        let ids = record.parameters.testIdentifiers
        guard !ids.isEmpty, ids.allSatisfy(WorkflowContract.identifier) else { throw BuildError.arguments }
        let path = root.appendingPathComponent(record.id.uuidString + ".selection.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((ids.joined(separator: "\n") + "\n").utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let args = command.arguments.filter { !$0.hasPrefix("-only-testing:") } + ["-only-testing", "@" + path.path]
        return .init(executable: command.executable, arguments: args, directory: command.directory, environment: command.environment)
    }
}
