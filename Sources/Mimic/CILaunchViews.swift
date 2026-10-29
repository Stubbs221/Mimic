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
    var isExpanded = false
    var disabled = false
    var helpKey: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: self.action) {
            HStack {
                Text(text(self.kind.localizationKey)).mimicFont(.body, weight: .semibold)
                Spacer(minLength: 4)
                Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down").frame(width: 28, height: 28)
            }.contentShape(Rectangle())
        }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).disabled(self.disabled)
            .background(PanelControlRegion())
            .mimicHelp(text(self.helpKey ?? "ci.launch." + self.kind.rawValue))
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
    @State private var showingBranches = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var branchFocused: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(self.preferences.kinds, id: \.self) { kind in
                CILaunchButton(kind: kind, isExpanded: self.launch.selected == kind,
                               disabled: self.launch.contracts[kind] == nil || self.launch.checking.contains(kind) || self.launch.submitting,
                               helpKey: self.launch.capabilityErrors[kind]) { self.launch.open(kind) }
                if self.launch.selected == kind { self.form(kind) }
            }
            if !self.launch.checking.isEmpty, self.launch.contracts.isEmpty { CISkeleton(presented: self.presented) }
            ForEach(self.preferences.kinds, id: \.self) { kind in
                if let error = self.launch.capabilityErrors[kind], !(self.launch.credentialBlocked && ["ci.error.credential", "jenkins.error.credential", "ci.error.authentication", "jenkins.error.authentication"].contains(error)) {
                    HStack(alignment: .top) {
                        Text(text(kind.localizationKey) + ": " + text(error)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button(text("ci.details.retry")) { self.launch.refreshCapabilities() }
                            .buttonStyle(.plain).accessibilityLabel(text("refresh"))
                    }
                }
            }
        }.mimicFont(.caption)
            .onAppear { self.launch.setVisible(self.presented, preserveDraft: !self.presented) }
            .onChange(of: self.presented) { _, value in if !value { self.showingBranches = false }; self.launch.setVisible(value, preserveDraft: !value) }
            .onDisappear { self.launch.setVisible(false, preserveDraft: true) }
    }

    private func form(_ kind: RemoteCIKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                self.query = ""; self.showingBranches = true; self.launch.searchBranches("")
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                    Text(self.launch.branch.isEmpty ? text("ci.launch.branch") : self.launch.branch).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                }.frame(maxWidth: .infinity).frame(minHeight: 28)
            }.buttonStyle(RowButtonStyle()).accessibilityIdentifier("ci.launch.branch")
                .mimicHelp(self.launch.branch).popover(isPresented: self.$showingBranches) { self.branchPicker }
            if kind == .uiTests {
                Picker(text("ci.launch.plan"), selection: self.$launch.plan) {
                    ForEach(self.launch.availablePlans, id: \.self) { plan in Text(plan.rawValue).tag(plan) }
                }.mimicSelection(text("ci.launch.plan"), selection: self.$launch.plan, options: self.launch.availablePlans.map { .init($0.rawValue, $0) })
            }
            if kind == .qualityGates {
                ForEach(QualityGate.allCases, id: \.self) { gate in
                    Toggle(text(gate.localizationKey), isOn: Binding(get: { self.launch.gates[gate] == true }, set: { self.launch.gates[gate] = $0 })).toggleStyle(MimicCheckboxStyle())
                }
            }
            if kind == .beta, self.launch.reviewedContract != nil {
                LabeledContent(text("ci.launch.product"), value: self.launch.betaValue(.target) ?? "—")
                LabeledContent(text("ci.launch.rebase"), value: self.launch.betaValue(.rebase).flatMap { $0.isEmpty ? nil : $0 } ?? text("ci.launch.none"))
                LabeledContent("Firebase", value: text(self.launch.betaValue(.upload) == "TRUE" ? "ci.launch.enabled" : "ci.launch.disabled"))
            }
            if let message = self.launch.message, !(self.launch.credentialBlocked && ["ci.error.credential", "jenkins.error.credential", "ci.error.authentication", "jenkins.error.authentication"].contains(message)) { Text(text(message)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(text(self.launch.submitting ? "ci.launch.submitting" : "ci.launch.submit")) { self.launch.submit() }.disabled(!self.launch.canSubmit)
                    .accessibilityIdentifier("ci.launch.submit")
            }
        }.padding(MimicMetrics.medium).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .background(PanelControlRegion())
            .disabled(self.launch.submitting)
    }
    private var branchPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("ci.launch.branch")).mimicFont(.heading)
            TextField(text("ci.launch.search"), text: self.$query).textFieldStyle(.roundedBorder).mimicInput()
                .focused(self.$searchFocused).accessibilityIdentifier("ci.launch.branch.search")
                .onChange(of: self.query) { _, value in self.launch.searchBranches(value) }
                .onKeyPress(.downArrow) { self.branchFocused = self.launch.branches.first; return .handled }
            if self.launch.searchingBranches { CISkeleton(presented: self.showingBranches) }
            else if self.launch.branches.isEmpty { Text(text("ci.launch.noBranches")).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(self.launch.branches, id: \.self) { branch in
                        Button {
                            self.launch.chooseBranch(branch); self.showingBranches = false
                        } label: {
                            HStack {
                                Text(branch).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if self.launch.branch == branch { Image(systemName: "checkmark") }
                            }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        }.buttonStyle(BranchSelectionButtonStyle(current: self.launch.branch == branch)).focused(self.$branchFocused, equals: branch).mimicHelp(branch)
                            .accessibilityAddTraits(self.launch.branch == branch ? .isSelected : [])
                            .onKeyPress(.downArrow) { self.moveBranchFocus(from: branch, by: 1); return .handled }
                            .onKeyPress(.upArrow) { self.moveBranchFocus(from: branch, by: -1); return .handled }
                    }
                }
            }.frame(maxHeight: 260)
        }.mimicFont(.caption).padding(16).frame(width: 360)
            .onAppear { self.searchFocused = true }
            .onExitCommand { self.showingBranches = false }
    }

    private func moveBranchFocus(from branch: String, by offset: Int) {
        guard let index = self.launch.branches.firstIndex(of: branch), !self.launch.branches.isEmpty else { return }
        self.branchFocused = self.launch.branches[min(self.launch.branches.count - 1, max(0, index + offset))]
    }

}
