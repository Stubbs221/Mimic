//
//  BuildResourceRecoveryView.swift
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import SwiftUI
import MimicCore

struct BuildResourceReason: View {
    let check: BuildResourceCheck
    private var message: String {
        String(format: text("build.resources." + check.status.rawValue), check.title)
            + " · " + check.platform.rawValue + (check.expectedVersion.map { " · " + $0 } ?? "")
    }
    var body: some View {
        Text(message).mimicFont(.caption).foregroundStyle(.orange).lineLimit(1).mimicHelp(message)
            .accessibilityIdentifier("build.resources.reason")
    }
}

/// R1 uses the primary slot in both compact sizes; it never opens Extended to start a repair.
struct BuildResourceRestoreButton: View {
    @ObservedObject var model: TaskCoordinator
    let project: ProjectContext
    let platform: BootstrapPlatform
    let check: BuildResourceCheck
    var retry = false
    var body: some View {
        Button {
            Task {
                do { _ = try await model.restoreBuildResources(project: project, platform: platform, resourceID: check.id, requestID: UUID()) }
                catch { model.message = text("build.resources.recoveryFailed") }
            }
        } label: {
            Text(text(retry ? "build.resources.retry" : "build.resources.restore")).frame(maxWidth: .infinity)
        }.buttonStyle(MimicAuxiliaryButtonStyle(primary: true, height: 28, horizontalPadding: 8))
            .disabled(!check.canRecover || model.resourceRecoveryAdmissions.contains(model.buildResourceKey(project: project, platform: platform)) || model.admissionsClosed || model.switchingBranch)
            .accessibilityIdentifier("build.resources.restore")
    }
}

/// Recovery is an ordinary queued profile action, with the same cancel and log ownership as other tools.
struct BuildResourceRecoveryView: View {
    @ObservedObject var model: TaskCoordinator
    let project: ProjectContext
    let platform: BootstrapPlatform
    let state: BuildResourceState
    let record: TaskRecord?
    private var pending: Bool { record == nil || record.map { [.queued, .running].contains($0.status) || model.agentMetadataPending.contains($0.id) } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text(pending ? record?.status == .queued ? "build.resources.queued" : "build.resources.restoring" : "build.resources.recoveryFailed"))
                .mimicFont(.caption).lineLimit(1).foregroundStyle(pending ? Color.secondary : .orange)
            if let record {
                HStack {
                    Text(record.error ?? model.profileProgress[record.id] ?? text("build.resources.verifying")).lineLimit(1)
                    Spacer(minLength: 0)
                    MimicActivityClock(running: pending) { now in
                        let seconds = max(0, Int((record.finishedAt ?? now).timeIntervalSince(record.startedAt ?? record.createdAt)))
                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
                    }
                }.mimicFont(.caption).foregroundStyle(.secondary)
            }
            if pending { MimicProgressBar(value: nil, color: .accentColor, label: text("build.resources.restoring")) }
            HStack(spacing: 8) {
                if let record, [.queued, .running].contains(record.status) {
                    Button(text("build.stop")) { model.cancel(id: record.id) }.buttonStyle(MimicAuxiliaryButtonStyle(height: 28))
                        .accessibilityIdentifier("build.resources.cancel")
                } else if !pending, let check = state.blocker {
                    BuildResourceRestoreButton(model: model, project: project, platform: platform, check: check, retry: true)
                }
                if let record {
                    Button(text("build.resources.log")) { model.showHistory(id: record.id, focusTerminal: true) }
                        .buttonStyle(MimicAuxiliaryButtonStyle(height: 28)).accessibilityIdentifier("build.resources.log")
                }
            }
        }.accessibilityIdentifier("build.resources.activity")
    }
}
