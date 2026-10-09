//
//  PreparationIntegration.swift
//  Mimic
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import MimicCore

extension TaskCoordinator {
    /// Read-only receipt status. Ordinary source changes are deliberately outside its input identity.
    func preparationState(project: ProjectContext, platform: BootstrapPlatform) async -> BridgeValue {
        guard let profile = activeProfile, let requirement = profile.profile.preparation, requirement.platforms.contains(platform) else {
            return .object(["status": .string("missing"), "required": .bool(false), "blocking": .bool(false)])
        }
        let key = project.path + "|" + platform.rawValue
        let receipt = preparationReceipts[key]
        let digest = try? await Task.detached { try requirement.inputDigest(path: project.path) }.value
        let developer: String
        if let pinned = project.developerDirectory { developer = pinned }
        else { developer = await Task.detached { EnvironmentInspector.boundedCapture("/usr/bin/xcode-select", ["-p"], timeout: 10, maximumBytes: 4096).1.trimmingCharacters(in: .whitespacesAndNewlines) }.value }
        let toolchain = await identifyPreparationToolchain(developer)
        guard activeProfile?.revision == profile.revision else { return .object(["status": .string("unknown"), "required": .bool(requirement.required), "blocking": .bool(requirement.required)]) }
        let status: String
        if digest == nil || developer.isEmpty || toolchain == nil || receipt != nil && (receipt?.toolchainIdentity == nil || receipt?.completedStages == nil) { status = "unknown" }
        else if let receipt {
            status = receipt.profileID == profile.id && receipt.profileRevision == profile.revision && receipt.inputDigest == digest && receipt.developer == developer && receipt.toolchainIdentity == toolchain && Set(requirement.stages ?? []).isSubset(of: Set(receipt.completedStages ?? [])) ? "current" : "stale"
        } else { status = "missing" }
        return .object(["status": .string(status), "required": .bool(requirement.required), "blocking": .bool(requirement.required && status != "current"), "receipt": (try? .encode(receipt)) ?? .null, "nextStep": status == "current" ? .null : .object(["code": .string("runPreparation"), "actionID": .string(requirement.actionID), "platform": .string(platform.rawValue)])])
    }

    /// Runs under LaunchPreparation's queue ownership, before any process starts.
    func prepareAgentMetadata(_ record: TaskRecord) async {
        let before = try? await Task.detached { try GitActivitySnapshot.capture(path: record.project.path) }.value
        agentChangeSnapshots[record.id] = before
        guard let execution = record.profileExecution, let requirement = execution.snapshot.profile.preparation,
              execution.actionID == requirement.actionID, requirement.platforms.contains(record.options.platform),
              requirement.parameters.allSatisfy({ execution.parameters[$0.key] == $0.value }) else { return }
        let digest = try? await Task.detached { try requirement.inputDigest(path: record.project.path) }.value
        preparationInputs[record.id] = digest
        let developer = record.selectedDeveloperDirectory ?? record.project.developerDirectory ?? ""
        preparationToolchains[record.id] = await identifyPreparationToolchain(developer)
    }

    /// Successful process completion is required; failed/interrupted/external operations cannot mint a receipt.
    func finishAgentMetadata(_ record: TaskRecord) async {
        let after = try? await Task.detached { try GitActivitySnapshot.capture(path: record.project.path) }.value
        let changes = agentChangeSnapshots.removeValue(forKey: record.id).flatMap { before in after.map { before.changes(after: $0) } }
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].changes = changes ?? { var value = ActivityChanges(); value.unavailable = true; return value }() }
        if record.status == .succeeded, record.exitCode == 0, let execution = record.profileExecution, let requirement = execution.snapshot.profile.preparation, record.completedProfileSteps == execution.action?.steps.count,
           let before = preparationInputs.removeValue(forKey: record.id),
           let digest = try? await Task.detached(operation: { try requirement.inputDigest(path: record.project.path) }).value, digest == before {
            let developer = record.selectedDeveloperDirectory ?? record.project.developerDirectory ?? ""
            var receipt = PreparationReceipt(activityID: record.id, checkout: record.project.path, platform: record.options.platform, profileID: execution.snapshot.id, profileRevision: execution.snapshot.revision, developer: developer, parameters: execution.parameters, inputDigest: digest, completedAt: record.finishedAt ?? Date())
            receipt.toolchainIdentity = await identifyPreparationToolchain(developer)
            guard receipt.toolchainIdentity != nil, receipt.toolchainIdentity == preparationToolchains.removeValue(forKey: record.id) else { preparationInputs[record.id] = nil; saveAgentMetadata(); return }
            receipt.completedStages = Array(execution.action?.steps.indices ?? 0..<0)
            preparationReceipts[record.project.path + "|" + record.options.platform.rawValue] = receipt
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].preparationReceipt = receipt }
            storePreparationReceipts()
        }
        preparationInputs[record.id] = nil; preparationToolchains[record.id] = nil
        saveAgentMetadata()
    }
    func saveAgentMetadata() { persistAgentHistory() }
}
