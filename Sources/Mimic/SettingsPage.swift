//
//  SettingsPage.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import SwiftUI
import MimicCore

// MARK: - Retained documents

struct MimicPageInteraction: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        content.opacity(self.visible ? 1 : 0).allowsHitTesting(self.visible)
            .disabled(!self.visible).accessibilityHidden(!self.visible)
    }
}

/// Hiding the native scroll view also excludes its controls from AppKit's key-view loop.
/// Its document remains mounted, retaining local state and the clip view's scroll offset.
struct MimicDocumentVisibility: NSViewRepresentable {
    let page: PanelPage
    let visible: Bool
    func makeNSView(context: Context) -> Marker { Marker(page: self.page, visible: self.visible) }
    func updateNSView(_ view: Marker, context: Context) { view.visible = self.visible; view.updateVisibility() }
    final class Marker: NSView {
        let page: PanelPage
        var visible: Bool
        private var retainedOffset: NSPoint?
        init(page: PanelPage, visible: Bool) { self.page = page; self.visible = visible; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); self.updateVisibility() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); self.updateVisibility() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func updateVisibility() {
            guard let scroll = self.enclosingScrollView else { return }
            scroll.identifier = NSUserInterfaceItemIdentifier(self.page == .home ? "page.home" : "page.settings")
            if !self.visible, !scroll.isHidden {
                // Freeze a reveal already in flight before retaining the hidden document.
                let clip = scroll.contentView
                let animating = clip.layer?.animationKeys()?.isEmpty == false
                let current = animating ? clip.layer?.presentation()?.bounds.origin ?? clip.bounds.origin : clip.bounds.origin
                clip.layer?.removeAllAnimations(); clip.scroll(to: current)
                scroll.reflectScrolledClipView(clip)
                retainedOffset = current
            }
            let restoring = self.visible && scroll.isHidden
            scroll.isHidden = !self.visible
            if restoring, let retainedOffset {
                // SwiftUI resets a newly unhidden clip view on its next layout pass.
                // Restore once after that pass; later explicit navigation can seek its own target.
                DispatchQueue.main.async { [weak self, weak scroll] in
                    guard let self, self.visible, let scroll, !scroll.isHidden else { return }
                    scroll.layoutSubtreeIfNeeded()
                    scroll.contentView.scroll(to: retainedOffset); scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }
}

struct PanelMessages: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        if !self.model.message.isEmpty { InlineMessage(message: self.model.message) { self.model.message = "" } }
        if !self.model.branchError.isEmpty, self.model.expandedSection != .branches {
            InlineMessage(message: self.model.branchError) { self.model.branchError = "" }
        }
    }
}

struct SettingsNavigationBar: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        HStack(spacing: MimicMetrics.medium) {
            Button { self.model.returnHome() } label: { Label(text("settings.back"), systemImage: "chevron.left") }
                .buttonStyle(RowButtonStyle()).accessibilityIdentifier("settings.back")
            Text(text("settings")).mimicFont(.heading).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }.padding(.horizontal, MimicMetrics.documentInset).padding(.vertical, MimicMetrics.small)
            .accessibilityIdentifier("settings.navigation")
    }
}

// MARK: - Retained category documents

/// Category bodies stay mounted, preserving form drafts and asynchronous checks across navigation.
struct SettingsContent: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SettingsGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 12) {
                    Text(group.title).mimicFont(.heading).accessibilityAddTraits(.isHeader)
                    contents(group)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(MimicPageInteraction(visible: model.settingsGroup == group))
                    .frame(height: model.settingsGroup == group ? nil : 0, alignment: .top).clipped()
                    .id(group.scrollID).accessibilityIdentifier(group.scrollID)
            }
        }.controlSize(.small).mimicFont(.body).accessibilityIdentifier("settings.page")
    }

    @ViewBuilder private func contents(_ group: SettingsGroup) -> some View {
        switch group {
        case .application:
            SettingsCard { MimicSystemOptionsView(options: model.systemOptions) }
            if let updater = model.updater { SettingsCard { MimicUpdateSettings(updater: updater) } }
            SettingsCard {
                Text(text("settings.service")).mimicFont(.heading)
                serviceAction(text("setup.title"), identifier: "setup.open") { model.showSetup?() }
                serviceAction(text("interface.map.title"), identifier: "interface.map.open") { model.showInterfaceMap?() }
                serviceAction(text("quit"), identifier: "settings.quit") { NSApp.terminate(nil) }
            }
        case .appearance:
            AppearanceSettingsContent(model: model)
        case .environment:
            SettingsCard {
                Text(text("settings.profile.global")).mimicFont(.heading)
                SettingsRow(title: model.activeProfile?.profile.title ?? text("profile.empty"),
                            detail: model.activeProfile.map { $0.profile.version + " · " + String($0.revision.prefix(12)) } ?? text("profile.empty.description")) {
                    Button(text("profile.import")) { model.importProfile() }.disabled(model.importingProfile)
                        .accessibilityIdentifier("settings.profile.import")
                }
                if model.importingProfile { ProgressView().controlSize(.small) }
            }
            SettingsCard {
                ProjectSelectionSettingsView(model: model)
                SettingsRow(title: text("settings.workspace"), detail: model.project?.appleTarget?.path ?? text("settings.workspace.empty")) {
                    Button(text("settings.choose")) { model.chooseAppleTarget() }
                        .disabled(model.project == nil || model.busy).accessibilityIdentifier("settings.workspace.choose")
                }
                SettingsRow(title: text("xcode.selection"), detail: model.project?.developerDirectory ?? text("xcode.system")) {
                    MimicActionLayout {
                        Button(text("xcode.choose")) { model.chooseXcode() }
                        Button(text("xcode.reset")) { model.resetXcode() }
                    }.disabled(model.switchingBranch)
                }
            }
        case .aiIntegrations:
            AIIntegrationsSettingsView(model: model, settings: model.aiSettings, usage: model.aiUsage, analysis: model.analysis)
        case .ci:
            SettingsCard { CISettingsView(settings: model.ciSettings, hasCheckout: model.project != nil, framed: false) }
            SettingsCard { JenkinsSettingsView(settings: model.jenkinsSettings, framed: false) }
            SettingsCard { CILaunchPreferencesView(preferences: model.ciLaunchPreferences, framed: false) }
        case .diagnostics:
            SettingsCard { FrameDiagnosticsSettingsView(settings: model.frameDiagnostics) }
            SettingsCard {
                SettingsRow(title: text("settings.environment.diagnostics")) {
                    Button(text("refresh")) { model.refresh() }.disabled(model.checking || model.switchingBranch)
                        .accessibilityIdentifier("settings.diagnostics.refresh")
                }
                MimicDisclosure(text("settings.details"), isExpanded: $model.settingsDiagnosticsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.diagnostic).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let project = model.project {
                            Text(project.path).mimicFont(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.mimicFont(.caption)
            }
        }
    }

    private func serviceAction(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(RowButtonStyle()).accessibilityIdentifier(identifier)
    }
}

/// Project choice belongs to environment settings; full paths distinguish identically named checkouts.
struct ProjectSelectionSettingsView: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.medium) {
            Label(text("project"), systemImage: "folder").mimicFont(.heading)
            Menu {
                ForEach(self.model.projects) { project in
                    Button { self.model.selectProject(project) } label: {
                        if project.path == self.model.selectedProjectPath { Label(project.path, systemImage: "checkmark") }
                        else { Text(project.path) }
                    }
                }
            } label: {
                Text(self.model.project.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? text("checkout.choose"))
                    .lineLimit(1).truncationMode(.middle)
            }.disabled(!self.model.canSelectProject || self.model.projects.isEmpty)
                .accessibilityLabel(text("project.choose"))
                .accessibilityValue(self.model.project?.path ?? text("project.no.branch"))
                .accessibilityIdentifier("settings.project.select")
            if let project = self.model.project {
                Text(project.path).mimicFont(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.project.path")
                LabeledContent(text("task.commit")) { Text(project.commit).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    .mimicFont(.caption)

            }
            Button(text("project.add")) { self.model.chooseProject() }
                .disabled(!self.model.canSelectProject).accessibilityIdentifier("settings.project.add")
        }.accessibilityIdentifier("settings.project")
    }
}

// MARK: - Shared form vocabulary

/// A single frame can be omitted when the form is already inside a settings group.
struct SettingsFormContainer<Content: View>: View {
    var framed = true
    @ViewBuilder let content: () -> Content
    var body: some View {
        if self.framed { Surface(content: self.content) }
        else { self.content() }
    }
}

struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.small) {
            Text(self.title).mimicFont(.caption).foregroundStyle(.secondary)
            self.content().textFieldStyle(.roundedBorder).accessibilityLabel(self.title)
        }
    }
}

/// Connection identity and verification are separate: Check never implies Save.
struct CIConnectionForm<Fields: View, Credential: View>: View {
    let service: String
    let connected: Bool
    let checking: Bool
    let verified: Bool
    let error: String?
    var unavailable: String? = nil
    let check: () -> Void
    let save: () -> Void
    let disconnect: () -> Void
    let identifier: String
    @ViewBuilder let fields: () -> Fields
    @ViewBuilder let credential: () -> Credential

    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.medium) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.service).mimicFont(.heading).accessibilityAddTraits(.isHeader)
                Label(text(self.connected ? "settings.connection.connected" : "settings.connection.disconnected"),
                      systemImage: self.connected ? "checkmark.circle" : "link")
                    .mimicFont(.caption).foregroundStyle(self.connected ? Color.green : Color.secondary)
            }
            self.fields()
            if self.connected { Text(text("settings.token.keep")).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            self.credential()
            if let unavailable = self.unavailable { Text(unavailable).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            MimicActionLayout {
                Button(text("ci.check"), action: self.check).disabled(self.unavailable != nil).accessibilityIdentifier(self.identifier + ".check")
                Button(text("ci.save"), action: self.save).disabled(!self.verified || self.unavailable != nil).accessibilityIdentifier(self.identifier + ".save")
                if self.connected { Button(text("ci.disconnect"), action: self.disconnect).accessibilityIdentifier(self.identifier + ".disconnect") }
            }
            if self.checking {
                HStack { ProgressView().controlSize(.small); Text(text("settings.connection.checking")) }
                    .accessibilityIdentifier(self.identifier + ".checking")
            } else if let error = self.error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(self.identifier + ".error")
            } else if self.verified {
                Label(text("settings.connection.verified"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(self.identifier + ".verified")
            }
        }.mimicFont(.body).disabled(self.checking).accessibilityIdentifier(self.identifier + ".settings")
    }
}
