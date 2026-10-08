//
//  CILaunchViews.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import SwiftUI
import MimicCore

/// Intrinsic button labels share the same wrapping layout at every panel width.
struct CILaunchButton: View {
    let kind: RemoteCIKind
    var disabled = false
    var helpKey: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: self.action) {
            Label(text("ci.launch." + self.kind.rawValue), systemImage: "play.fill")
                .mimicFont(.caption, weight: .medium)
                .padding(.horizontal, MimicMetrics.medium).frame(height: MimicMetrics.footerRow)
        }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).disabled(self.disabled)
            .background(PanelControlRegion())
            .help(text(self.helpKey ?? "ci.launch." + self.kind.rawValue))
            .accessibilityIdentifier("ci.launch." + self.kind.rawValue)
    }
}

struct CILaunchPreferencesView: View {
    @ObservedObject var preferences: CILaunchPreferences
    var framed = true
    var body: some View {
        SettingsFormContainer(framed: self.framed) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text("ci.launch.preferences")).mimicFont(.heading)
                SettingsSwitch(title: text("ci.launch.showQualityGates"), isOn: self.$preferences.qualityGates, identifier: "ci.launch.showQualityGates")
                SettingsSwitch(title: text("ci.launch.showBeta"), isOn: self.$preferences.beta, identifier: "ci.launch.showBeta")
                Text(text("ci.launch.preferences.detail")).mimicFont(.caption).foregroundStyle(.secondary)
            }.mimicFont(.body)
        }
    }
}

/// The native form uses a searchable remote branch, without touching the local checkout.
struct CILaunchActions: View {
    @ObservedObject var launch: CILaunchModel
    @ObservedObject var preferences: CILaunchPreferences
    var presented = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MimicActionLayout {
                ForEach(self.preferences.kinds, id: \.self) { kind in
                    CILaunchButton(kind: kind, disabled: self.launch.contracts[kind] == nil || self.launch.checking.contains(kind) || self.launch.submitting,
                                   helpKey: self.launch.capabilityErrors[kind]) { self.launch.open(kind) }
                }
            }
            if !self.launch.checking.isEmpty { ProgressView().controlSize(.small).accessibilityLabel(text("jenkins.checking")) }
            ForEach(self.preferences.kinds, id: \.self) { kind in
                if let error = self.launch.capabilityErrors[kind], !(self.launch.credentialBlocked && ["ci.error.credential", "jenkins.error.credential", "ci.error.authentication", "jenkins.error.authentication"].contains(error)) {
                    HStack(alignment: .top) {
                        Text(text(kind.localizationKey) + ": " + text(error)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button { self.launch.refreshCapabilities() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).accessibilityLabel(text("refresh"))
                    }
                }
            }
            if let kind = self.launch.selected { self.form(kind) }
        }.mimicFont(.caption)
            .onAppear { self.launch.setVisible(self.presented, preserveDraft: !self.presented) }
            .onChange(of: self.presented) { _, value in self.launch.setVisible(value, preserveDraft: !value) }
            .onDisappear { self.launch.setVisible(false) }
    }

    private func form(_ kind: RemoteCIKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text(kind.localizationKey)).mimicFont(.body, weight: .semibold)
            TextField(text("ci.launch.branch"), text: self.$launch.branch).textFieldStyle(.roundedBorder)
                .accessibilityLabel(text("ci.launch.branch")).accessibilityIdentifier("ci.launch.branch")
                .onChange(of: self.launch.branch) { _, query in self.launch.searchBranches(query) }
            if !self.launch.branches.isEmpty {
                Menu(text("ci.launch.chooseBranch")) {
                    ForEach(self.launch.branches, id: \.self) { branch in Button(branch) { self.launch.branch = branch } }
                }
            }
            if kind == .uiTests {
                Picker(text("ci.launch.plan"), selection: self.$launch.plan) {
                    ForEach(self.launch.availablePlans, id: \.self) { plan in Text(plan.rawValue).tag(plan) }
                }
            }
            if kind == .qualityGates {
                ForEach(QualityGate.allCases, id: \.self) { gate in
                    Toggle(text(gate.localizationKey), isOn: Binding(get: { self.launch.gates[gate] == true }, set: { self.launch.gates[gate] = $0 }))
                }
            }
            if kind == .beta, self.launch.reviewedContract != nil {
                LabeledContent(text("ci.launch.product"), value: self.launch.betaValue(.target) ?? "—")
                LabeledContent(text("ci.launch.rebase"), value: self.launch.betaValue(.rebase).flatMap { $0.isEmpty ? nil : $0 } ?? text("ci.launch.none"))
                LabeledContent("Firebase", value: text(self.launch.betaValue(.upload) == "TRUE" ? "ci.launch.enabled" : "ci.launch.disabled"))
            }
            if let message = self.launch.message, !(self.launch.credentialBlocked && ["ci.error.credential", "jenkins.error.credential", "ci.error.authentication", "jenkins.error.authentication"].contains(message)) { Text(text(message)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(text("ci.launch.submit")) { self.launch.submit() }.disabled(self.launch.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ci.launch.submit")
                Button(text("ci.launch.close")) { self.launch.close() }
                if self.launch.submitting { ProgressView().controlSize(.small) }
            }
        }.padding(MimicMetrics.medium).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .background(PanelControlRegion())
            .disabled(self.launch.submitting)
    }
}
