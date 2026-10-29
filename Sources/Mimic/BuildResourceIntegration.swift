//
//  BuildResourceIntegration.swift
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation
import MimicCore

extension TaskCoordinator {
    // MARK: - Readiness

    /// Cache identity includes the entire checkout context and immutable profile revision.
    func buildResourceKey(project: ProjectContext, platform: BootstrapPlatform) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ((try? encoder.encode(project).base64EncodedString()) ?? project.path) + "|" + platform.rawValue + "|" + (activeProfile?.revision ?? "")
    }

    func cachedBuildResources(project: ProjectContext, platform: BootstrapPlatform) -> BuildResourceState {
        if let cached = buildResourceStates[buildResourceKey(project: project, platform: platform)] { return cached }
        return .init(checks: (activeProfile?.profile.buildResources ?? []).filter { $0.platform == platform }.map {
            .init(id: $0.id, title: $0.title, platform: platform, status: .unknown, expectedVersion: nil)
        })
    }

    /// Admission and execution always use fresh evidence, independently of a visible card's cache.
    @discardableResult func refreshBuildResources(project: ProjectContext, platform: BootstrapPlatform) async throws -> BuildResourceState {
        guard let snapshot = activeProfile else { return .init() }
        let requirements = snapshot.profile.buildResources ?? []
        guard requirements.contains(where: { $0.platform == platform }) else { return .init() }
        try verifyServiceProfile(snapshot)
        let key = buildResourceKey(project: project, platform: platform)
        let state = await Task.detached { BuildResourceInspector.inspect(requirements, project: project, platform: platform) }.value
        guard activeProfile == snapshot, projects.contains(project), !Task.isCancelled else { throw BuildError.context }
        if buildResourceStates.count > 100 { buildResourceStates.removeAll() }
        if buildResourceStates[key] != state { buildResourceStates[key] = state }
        return state
    }

    func buildResourceActivity(project: ProjectContext, platform: BootstrapPlatform) -> TaskRecord? {
        guard let snapshot = activeProfile else { return nil }
        let requirements = (snapshot.profile.buildResources ?? []).filter { $0.platform == platform }
        return records.last { record in
            guard record.project == project, let execution = record.profileExecution, execution.snapshot == snapshot else { return false }
            return requirements.contains { $0.recoveryActionID == execution.actionID && $0.recoveryParameters == execution.parameters }
        }
    }

    // MARK: - Explicit recovery

    /// Coalesces repeated request IDs before profile admission. Different cards cannot race two repairs.
    func restoreBuildResources(project: ProjectContext, platform: BootstrapPlatform, resourceID: String, requestID: UUID) async throws -> UUID {
        guard let snapshot = activeProfile, let requirement = snapshot.profile.buildResources?.first(where: { $0.id == resourceID && $0.platform == platform }),
              projects.contains(project), !admissionsClosed, !switchingBranch else { throw BuildError.context }
        let key = buildResourceKey(project: project, platform: platform)
        let identity = key + "|" + requirement.id
        let execution = ProfileExecution(snapshot: snapshot, actionID: requirement.recoveryActionID, parameters: requirement.recoveryParameters)
        if let request = resourceRecoveryRequests[requestID] {
            guard request.identity == identity else { throw BuildError.duplicate }; return try await request.task.value
        }
        if let record = records.first(where: { $0.id == requestID }) {
            guard record.project == project, record.profileExecution == execution else { throw BuildError.duplicate }; return record.id
        }
        guard !resourceRecoveryAdmissions.contains(key), buildResourceActivity(project: project, platform: platform).map({ [.queued, .running].contains($0.status) || agentMetadataPending.contains($0.id) }) != true else { throw BuildError.capacity }
        resourceRecoveryAdmissions.insert(key)
        let task = Task { @MainActor [weak self] () throws -> UUID in
            guard let self else { throw BuildError.unavailable }
            defer { resourceRecoveryAdmissions.remove(key) }
            let state = try await refreshBuildResources(project: project, platform: platform)
            guard state.checks.first(where: { $0.id == resourceID })?.canRecover == true,
                  activeProfile == snapshot, projects.contains(project), !admissionsClosed, !switchingBranch else { throw BuildError.context }
            return try await withCheckedThrowingContinuation { continuation in
                requestProfile(execution: execution, expected: project, recordID: requestID, reveal: false, navigate: false) { record in
                    if let record { continuation.resume(returning: record.id) }
                    else { continuation.resume(throwing: BuildError.unavailable) }
                }
            }
        }
        resourceRecoveryRequests[requestID] = (identity, task)
        defer { resourceRecoveryRequests[requestID] = nil }
        return try await task.value
    }

    /// A successful shell exit is insufficient: adapters may swallow a failed download.
    func finishBuildResourceRecovery(_ record: TaskRecord) async {
        guard let execution = record.profileExecution,
              let requirement = execution.snapshot.profile.buildResources?.first(where: { $0.recoveryActionID == execution.actionID && $0.recoveryParameters == execution.parameters }) else { return }
        let state = await Task.detached { BuildResourceInspector.inspect(execution.snapshot.profile.buildResources ?? [], project: record.project, platform: requirement.platform) }.value
        if record.status == .succeeded, state.checks.first(where: { $0.id == requirement.id })?.status != .ready,
           let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index].status = .failed; records[index].error = text("build.resources.verificationFailed"); unreadFailure = true
        }
        if activeProfile == execution.snapshot, projects.contains(record.project) {
            buildResourceStates[buildResourceKey(project: record.project, platform: requirement.platform)] = state
        }
    }

    /// Panel and agent receive safe action references, never commands or service addresses.
    func buildResourceMetadata(project: ProjectContext, platform: BootstrapPlatform, state: BuildResourceState) -> BridgeValue {
        let check = state.blocker
        let activity = buildResourceActivity(project: project, platform: platform)
        let pending = activity.map { [.queued, .running].contains($0.status) || agentMetadataPending.contains($0.id) } == true
        var fields: [String: BridgeValue] = ["blocking": .bool(state.blocking), "status": .string(check?.status.rawValue ?? "ready"), "title": .string(check?.title ?? ""),
            "resourceID": check.map { .string($0.id) } ?? .null, "platform": .string(platform.rawValue), "expectedVersion": check?.expectedVersion.map(BridgeValue.string) ?? .null,
            "canRecover": .bool(check?.canRecover == true && !pending && !resourceRecoveryAdmissions.contains(buildResourceKey(project: project, platform: platform))),
            "admitting": .bool(resourceRecoveryAdmissions.contains(buildResourceKey(project: project, platform: platform)))]
        if let check, let requirement = activeProfile?.profile.buildResources?.first(where: { $0.id == check.id }) {
            fields["nextStep"] = .object(["code": .string("restoreBuildResources"), "actionID": .string(requirement.recoveryActionID), "parameters": (try? .encode(requirement.recoveryParameters)) ?? .null])
        }
        if let activity, pending || state.blocking {
            fields["activity"] = .object(["id": .string(activity.id.uuidString), "status": .string(pending && activity.status == .succeeded ? "verifying" : activity.status.rawValue),
                "phase": .string(profileProgress[activity.id] ?? text("build.resources.restoring")), "canCancel": .bool([.queued, .running].contains(activity.status)),
                "startedAt": .number((activity.startedAt ?? activity.createdAt).timeIntervalSince1970 * 1000), "finishedAt": activity.finishedAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null,
                "error": activity.error.map(BridgeValue.string) ?? .null])
        }
        return .object(fields)
    }
}
