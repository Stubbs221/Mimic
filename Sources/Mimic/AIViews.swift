//
//  AIViews.swift
//  Mimic
//
//  Created by Василий Маслов on 02.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// One task-local editor, preview and result; opening/collapsing never invokes a provider.
struct AnalysisView: View {
    @ObservedObject
    var model: TaskCoordinator
    let id: UUID
    var body: some View {
        AnalysisEditor(model: self.model, coordinator: self.model.analysis, settings: self.model.aiSettings, id: self.id)
    }
}

private struct AnalysisEditor: View {
    @ObservedObject
    var model: TaskCoordinator
    @ObservedObject
    var coordinator: AnalysisCoordinator
    @ObservedObject
    var settings: AISettingsModel
    let id: UUID
    @State
    private var previewExpanded = false
    @State private var requestSource = MimicMotionSource.automatic
    @State
    private var copied = false
    @FocusState
    private var editorFocused: Bool
    @AccessibilityFocusState
    private var accessibilityFocused: Bool
    private var session: AnalysisSession? { self.coordinator.sessions[self.id] }
    private var active: Bool { self.coordinator.activeTaskID == self.id }
    private var providerName: String { self.session?.provider == .claude ? "Claude" : "Codex" }

    var body: some View {
        if let session {
            VStack(alignment: .leading, spacing: 12) {
                if !session.result.isEmpty {
                    Text(text("ai.result.title")).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(session.result).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).mimicImmediate().accessibilityIdentifier("ai.analysis.result")
                }
                if !session.requestExpanded {
                    Button(text("ai.request.show")) { self.requestSource = .current; self.coordinator.setRequestExpanded(id: self.id, expanded: true) }.buttonStyle(BootstrapControlStyle())
                }
                MimicCollapse(expanded: session.requestExpanded, source: self.requestSource) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(text("ai.analysis.provider.label")).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                ForEach(AIProvider.allCases, id: \.self) { provider in
                                    Button(provider == .codex ? "Codex" : "Claude") { self.coordinator.edit(id: self.id, provider: provider) }
                                        .buttonStyle(BootstrapControlStyle(selected: session.provider == provider)).disabled(self.active)
                                        .accessibilityValue(text(session.provider == provider ? "bootstrap.platform.selected" : "bootstrap.platform.unselected"))
                                        .accessibilityIdentifier("ai.analysis.provider." + provider.rawValue)
                                }
                            }
                            Spacer(minLength: 0)
                            if !session.result.isEmpty { Button(text("ai.request.hide")) { self.requestSource = .current; self.coordinator.setRequestExpanded(id: self.id, expanded: false) }.buttonStyle(.plain) }
                        }
                        if session.snapshot.outputUnavailable { Text(text("ai.fragment.unavailable")).foregroundStyle(.secondary) }
                        if session.snapshot.truncated { Text(text("ai.fragment.truncated")).foregroundStyle(.secondary) }
                        Text(text("ai.fragment")).fontWeight(.medium)
                        TextEditor(text: Binding(get: { self.session?.fragment ?? "" }, set: { self.coordinator.edit(id: self.id, fragment: $0) }))
                            .font(.system(size: 11, design: .monospaced)).frame(height: 150).padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.18)))
                            .disabled(self.active).focused(self.$editorFocused).accessibilityFocused(self.$accessibilityFocused)
                            .accessibilityLabel(text("ai.fragment")).mimicImmediate().accessibilityIdentifier("ai.analysis.fragment")
                        Text(text("ai.comment")).foregroundStyle(.secondary)
                        TextField(text("ai.comment.placeholder"), text: Binding(get: { self.session?.comment ?? "" }, set: { self.coordinator.edit(id: self.id, comment: $0) }), axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(1 ... 3).padding(8).frame(minHeight: 32)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.18)))
                            .disabled(self.active).accessibilityLabel(text("ai.comment")).mimicImmediate().accessibilityIdentifier("ai.analysis.comment")
                        MimicDisclosure(text("ai.request.full"), isExpanded: self.$previewExpanded) {
                            Text(session.prompt).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).accessibilityIdentifier("ai.analysis.preview")
                        }
                        Text(String(format: text("ai.transmission.provider.format"), self.providerName)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { self.sendAction(session); self.copyAction; Spacer(minLength: 0) }
                            VStack(alignment: .leading, spacing: 8) { self.sendAction(session); self.copyAction }
                        }
                        if self.copied { Text(text("ai.copied")).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("ai.analysis.copied") }
                        if self.active {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(text("ai.state." + session.state.rawValue))
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    Text(String(format: text("ai.elapsed.format"), Int(max(0, (session.finishedAt ?? Date()).timeIntervalSince(session.startedAt ?? Date()))))).monospacedDigit()
                                }
                            }.foregroundStyle(.secondary).accessibilityIdentifier("ai.analysis.state")
                        } else if session.state == .cancelled { Text(text("ai.state.cancelled")).foregroundStyle(.secondary) }
                        if self.coordinator.isActive, !self.active { Text(text("ai.error.busy")).foregroundStyle(.secondary) }
                        if let error = session.error, error != .cancelled {
                            Text(text(error.localizationKey)).foregroundStyle(.orange).textSelection(.enabled).accessibilityIdentifier("ai.analysis.error")
                        } else if let error = self.settings.errors[session.provider] {
                            Text(text(error.localizationKey)).foregroundStyle(.orange)
                        }
                    }
                }
            }.font(.system(size: 12)).padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
                .onAppear { self.focusEditor() }.onChange(of: self.model.analysisFocusRequest) { _, _ in self.focusEditor() }
                .onChange(of: session.requestExpanded) { _, expanded in
                    if expanded { self.focusEditor() }
                    else { self.editorFocused = false; self.accessibilityFocused = false }
                }
                .onChange(of: self.model.analysisEditorFocusTaskID) { _, id in
                    if id != self.id { self.editorFocused = false; self.accessibilityFocused = false }
                }
                .onChange(of: session.prompt) { _, _ in self.copied = false }
                .onChange(of: session.state) { _, state in if state == .succeeded { self.previewExpanded = false } }
                .accessibilityIdentifier("ai.analysis")
        }
    }

    @ViewBuilder
    private func sendAction(_ session: AnalysisSession) -> some View {
        if self.active {
            Button(text("ai.stop")) { self.coordinator.cancel() }.buttonStyle(BootstrapControlStyle()).accessibilityIdentifier("ai.analysis.stop")
        } else {
            Button(String(format: text(session.requestID == nil ? "ai.send.provider.format" : "ai.retry.provider.format"), self.providerName)) {
                self.coordinator.submit(id: self.id, settings: self.settings.settings)
            }.buttonStyle(BootstrapControlStyle(primary: true)).disabled(self.coordinator.isActive || self.settings.checking != nil).accessibilityIdentifier("ai.analysis.send")
        }
    }

    private var copyAction: some View {
        Button(text("ai.copy.request")) { self.copied = self.model.copyAnalysisRequest(id: self.id) }
            .buttonStyle(BootstrapControlStyle()).accessibilityIdentifier("ai.analysis.copy")
    }

    private func focusEditor() {
        guard self.model.analysisEditorFocusTaskID == self.id, self.session?.requestExpanded == true, !self.active else { return }
        self.editorFocused = true; self.accessibilityFocused = true
    }
}

// MARK: - Provider settings

/// One provider section combines independent capabilities without coupling their disabled states.
struct AIIntegrationsSettingsView: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var settings: AISettingsModel
    @ObservedObject var usage: AIUsageCoordinator
    @ObservedObject var analysis: AnalysisCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.large) {
            SettingsField(title: text("settings.ai.default")) {
                Picker(text("settings.ai.default"), selection: self.$settings.settings.provider) {
                    Text("Codex").tag(AIProvider.codex); Text("Claude").tag(AIProvider.claude)
                }.labelsHidden().accessibilityIdentifier("ai.settings.provider")
                    .disabled(self.settings.checking != nil || self.analysis.isActive)
            }
            ForEach(AIProvider.allCases, id: \.self) { provider in
                Divider()
                Text(provider == .codex ? "Codex" : "Claude").font(MimicMetrics.heading).accessibilityAddTraits(.isHeader)
                if provider == .codex, let integration = self.model.integration {
                    MimicIntegrationSettingsView(integration: integration, framed: false)
                }
                AIProviderSettingsView(provider: provider, settings: self.settings, analysis: self.analysis)
                SettingsField(title: text("settings.usage.period")) {
                    Picker(text("settings.usage.period"), selection: Binding(
                        get: { self.usage.settings.preference(for: provider) },
                        set: { self.usage.setPreference($0, for: provider) }
                    )) {
                        ForEach(AIUsagePreference.allCases, id: \.self) { preference in
                            Text(text("usage.preference." + preference.rawValue)).tag(preference)
                        }
                    }.labelsHidden().accessibilityIdentifier("usage.preference." + provider.rawValue)
                }
            }
            Text(text("ai.cli.auth")).font(MimicMetrics.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.font(MimicMetrics.body)
    }
}

private struct AIProviderSettingsView: View {
    let provider: AIProvider
    @ObservedObject var settings: AISettingsModel
    @ObservedObject var analysis: AnalysisCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.medium) {
            Text(text("settings.ai.analysis")).font(MimicMetrics.body.weight(.medium))
            Text(text("settings.ai.analysis.detail")).font(MimicMetrics.secondary).foregroundStyle(.secondary)
            SettingsField(title: text("settings.ai.path")) {
                HStack {
                    TextField(text("settings.ai.path.placeholder"), text: self.path).accessibilityIdentifier("ai.settings.path." + self.provider.rawValue)
                    Button { self.choose() } label: { Image(systemName: "folder") }
                        .help(text("ai.cli.choose")).accessibilityLabel(text("ai.cli.choose"))
                        .accessibilityIdentifier("ai.settings.choose." + self.provider.rawValue)
                }
            }
            SettingsField(title: text("settings.ai.model")) {
                TextField(text("settings.ai.model.placeholder"), text: self.model).accessibilityIdentifier("ai.settings.model." + self.provider.rawValue)
            }
            HStack {
                Button(text("ai.cli.check")) { self.settings.check(self.provider) }
                    .accessibilityIdentifier("ai.settings.check." + self.provider.rawValue)
                if self.settings.checking == self.provider { ProgressView().controlSize(.small) }
            }
            if let capability = self.settings.capabilities[self.provider] {
                Text(capability.version).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = self.settings.errors[self.provider] {
                Text(text(error.localizationKey)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(self.settings.checking != nil || self.analysis.isActive)
    }

    private var path: Binding<String> {
        Binding(get: { self.settings.settings.path(for: self.provider) }, set: {
            if self.provider == .codex { self.settings.settings.codexPath = $0 }
            else { self.settings.settings.claudePath = $0 }
        })
    }
    private var model: Binding<String> {
        Binding(get: { self.settings.settings.model(for: self.provider) }, set: {
            if self.provider == .codex { self.settings.settings.codexModel = $0 }
            else { self.settings.settings.claudeModel = $0 }
        })
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.path.wrappedValue = url.path
    }
}
