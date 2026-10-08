// Created by Василий Маслов on 07.10.2026.
import Foundation
import MimicCore

extension MimicIntegration {
    /// Metadata exposes progress; diagnostic output is returned only for the explicitly delegated operation.
    static func branchMetadata(_ op: BranchSwitchOperation) -> BridgeValue {
        .object(["id": .string(op.id.uuidString), "checkout": .string(op.source.path), "sourceBranch": .string(op.source.branch),
                 "targetBranch": .string(op.target), "phase": .string(op.phase.rawValue), "holdsCheckout": .bool(op.phase.holdsCheckout),
                 "delivery": .string(op.delivery.rawValue), "ownerThreadID": op.ownerThreadID.map(BridgeValue.string) ?? .null,
                 "stashName": op.stashName.map(BridgeValue.string) ?? .null, "stashSHA": op.stashSHA.map(BridgeValue.string) ?? .null,
                 "error": op.error.map { .string(text($0)) } ?? .null])
    }

    func branchRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        let p = request.parameters
        guard Set(p.keys) == ["operationID"], let id = p["operationID"]?.string.flatMap(UUID.init(uuidString:)),
              let thread = request.threadID, !thread.isEmpty else { throw failure("arguments") }
        let coordinator = self.model.branchSwitch
        var op = try coordinator.operation(id)
        // IDs in an explicit delegation prompt bootstrap a new chat; only one host-supplied chat can claim it.
        guard op.ownerThreadID == nil || op.ownerThreadID == thread || op.sourceThreadID == thread else { throw failure("context") }
        switch request.method {
        case "get_branch_switch":
            var metadata = Self.branchMetadata(op).object ?? [:]
            metadata["sourceSHA"] = .string(op.source.commit)
            metadata["targetSHA"] = op.targetSHA.map(BridgeValue.string) ?? .null
            metadata["developSHA"] = op.developSHA.map(BridgeValue.string) ?? .null
            metadata["worktree"] = op.worktree.map(BridgeValue.string) ?? .null
            metadata["conflict"] = op.conflict.map { .string($0.rawValue) } ?? .null
            metadata["conflictPaths"] = .array(op.conflictPaths.map(BridgeValue.string))
            metadata["stoppedCommit"] = op.stoppedCommit.map(BridgeValue.string) ?? .null
            metadata["diagnostic"] = .string(op.diagnostic)
            metadata["instructions"] = .string(BranchSwitchBridge.prompt(id))
            return .object(metadata)
        case "claim_branch_switch":
            op = try coordinator.claim(id, threadID: thread)
            var workspace = self.workspaceStore.load(thread); workspace.checkout = op.source.path
            try self.workspaceStore.save(workspace, for: thread)
        case "complete_branch_switch": op = try await coordinator.complete(id, threadID: thread)
        case "cancel_branch_switch": op = try await coordinator.cancel(id, threadID: thread)
        default: throw failure("arguments")
        }
        return Self.branchMetadata(op)
    }

    func panelBranchRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        guard let thread = request.threadID, let current = self.project(thread) else { throw failure("context") }
        let p = request.parameters, coordinator = self.model.branchSwitch
        switch request.method {
        case "panel_branch_preferences":
            guard Set(p.keys) == ["context", "enabled"], case let .bool(enabled) = p["enabled"] else { throw failure("arguments") }
            _ = try self.expected(p["context"] ?? .null, threadID: thread)
            try coordinator.setRebase(enabled, path: current.path)
        case "panel_branch_heartbeat":
            guard Set(p.keys) == ["canSend"], case let .bool(canSend) = p["canSend"] else { throw failure("arguments") }
            coordinator.heartbeat(threadID: thread, path: current.path, canSend: canSend)
        case "panel_branch_delivery":
            guard p.isEmpty else { throw failure("arguments") }
            if let op = try coordinator.reserveDelivery(threadID: thread, path: current.path) {
                return .object(["operationID": .string(op.id.uuidString), "prompt": .string(BranchSwitchBridge.prompt(op.id))])
            }
            return .null
        case "panel_branch_delivery_result":
            guard Set(p.keys) == ["operationID", "sent"], let id = p["operationID"]?.string.flatMap(UUID.init(uuidString:)),
                  case let .bool(sent) = p["sent"], try coordinator.operation(id).source.path == current.path else { throw failure("arguments") }
            try coordinator.deliveryResult(id, threadID: thread, sent: sent)
        case "panel_cancel_branch_switch":
            guard Set(p.keys) == ["operationID"], let id = p["operationID"]?.string.flatMap(UUID.init(uuidString:)),
                  try coordinator.operation(id).source.path == current.path else { throw failure("arguments") }
            _ = try await coordinator.cancel(id)
        default: throw failure("arguments")
        }
        return .object(["done": .bool(true)])
    }
}
