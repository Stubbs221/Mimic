//
//  ProfileViews.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import SwiftUI
import CryptoKit
import MimicCore

struct ProfilePreview {
    let plan: GenerationPlan
    let project: ProjectContext
    let execution: ProfileExecution
}

/// A single global profile feeds the same native forms and MCP catalogue.
struct ProfileSection: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: MimicMetrics.large) {
                HStack {
                    Text(self.model.activeProfile?.profile.title ?? text("profile.empty")).mimicFont(.heading)
                    Spacer()
                    Button(text("profile.import")) { self.model.importProfile() }.disabled(self.model.importingProfile)
                    if self.model.importingProfile { ProgressView().controlSize(.small) }
                }
                if let snapshot = self.model.activeProfile {
                    Text(snapshot.profile.version + " · " + String(snapshot.revision.prefix(12))).mimicFont(.caption).foregroundStyle(.secondary)
                } else {
                    Text(text("profile.empty.description")).mimicFont(.caption).foregroundStyle(.secondary)
                }
                Button(text("profile.apple.choose")) { self.model.chooseAppleTarget() }.disabled(self.model.project == nil || self.model.busy)
                if let target = self.model.project?.appleTarget { Text(target.path).mimicFont(.caption).textSelection(.enabled) }
            }
        }
    }
}

/// Mandatory import gates the working panel; optional CI setup remains in the existing wizard.
struct ProfileSetupView: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.large) {
            Text(text("profile.setup.title")).mimicFont(.heading)
            Text(text("profile.setup.description")).mimicFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ProfileSection(model: self.model)
            Button(text("setup.title")) { self.model.showSetup?() }
        }.accessibilityIdentifier("profile.setup")
    }
}

extension ProfilePreview {
    /// Different chat drafts can retain independently reviewed plans for the same generator and checkout.
    static func cacheKey(project: ProjectContext, execution: ProfileExecution) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fields = execution.parameters.filter { $0.key != "expectedDigest" }
        let bytes = (try? encoder.encode(fields)) ?? Data()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return project.path + "|" + execution.actionID + "|" + execution.snapshot.revision + "|" + digest
    }
}
