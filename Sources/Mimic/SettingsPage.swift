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
                let current = clip.layer?.presentation()?.bounds.origin ?? clip.bounds.origin
                clip.layer?.removeAllAnimations(); clip.scroll(to: current)
                scroll.reflectScrolledClipView(clip)
            }
            scroll.isHidden = !self.visible
        }
    }
}

struct PanelMessages: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        if !self.model.message.isEmpty { InlineMessage(message: self.model.message) { self.model.message = "" } }
        if !self.model.branchError.isEmpty { InlineMessage(message: self.model.branchError) { self.model.branchError = "" } }
    }
}

struct SettingsNavigationBar: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        HStack(spacing: MimicMetrics.medium) {
            Button { self.model.returnHome() } label: { Label(text("settings.back"), systemImage: "chevron.left") }
                .buttonStyle(RowButtonStyle()).accessibilityIdentifier("settings.back")
            Text(text("settings")).font(MimicMetrics.heading).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }.padding(.horizontal, MimicMetrics.documentInset).padding(.vertical, MimicMetrics.small)
            .accessibilityIdentifier("settings.navigation")
    }
}

// MARK: - Grouped settings

struct SettingsContent: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.large) {
            ForEach(SettingsGroup.allCases) { group in
                Surface {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { self.model.toggleSettingsGroup(group) } label: {
                            HStack(spacing: MimicMetrics.small) {
                                Image(systemName: self.model.settingsGroup == group ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9)).accessibilityHidden(true)
                                Text(group.title).font(MimicMetrics.heading).accessibilityAddTraits(.isHeader)
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(RowButtonStyle())
                            .accessibilityValue(disclosureValue(self.model.settingsGroup == group))
                            .accessibilityIdentifier(group.scrollID + ".toggle")
                        MimicCollapse(expanded: self.model.settingsGroup == group, source: self.model.navigationSource) {
                            self.contents(group).padding(.top, MimicMetrics.medium)
                        }
                    }
                }.id(group.scrollID).accessibilityIdentifier(group.scrollID)
            }
        }.controlSize(.small).accessibilityIdentifier("settings.page")
    }

    @ViewBuilder private func contents(_ group: SettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: MimicMetrics.large) {
            switch group {
            case .application:
                Button(text("setup.title")) { self.model.showSetup?() }.accessibilityIdentifier("setup.open")
                Divider()
                ProfileSection(model: self.model)
                Divider()
                AppIconSettingsView(settings: self.model.appIconSettings, framed: false)
                Divider()
                Button { self.model.showInterfaceMap?() } label: { Label(text("interface.map.title"), systemImage: "map") }
                    .accessibilityIdentifier("interface.map.open")
                Button(text("quit")) { NSApp.terminate(nil) }
            case .aiIntegrations:
                AIIntegrationsSettingsView(model: self.model, settings: self.model.aiSettings, usage: self.model.aiUsage, analysis: self.model.analysis)
            case .ci:
                CISettingsView(settings: self.model.ciSettings, hasCheckout: self.model.project != nil, framed: false)
                Divider()
                JenkinsSettingsView(settings: self.model.jenkinsSettings, framed: false)
                Divider()
                CILaunchPreferencesView(preferences: self.model.ciLaunchPreferences, framed: false)
            case .environment:
                ProjectSelectionSettingsView(model: self.model)
                Divider()
                VStack(alignment: .leading, spacing: MimicMetrics.medium) {
                    Label(text("xcode.selection"), systemImage: "hammer").font(MimicMetrics.heading)
                    Text(self.model.project?.developerDirectory ?? text("xcode.system"))
                        .font(MimicMetrics.secondary).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    MimicActionLayout {
                        Button(text("xcode.choose")) { self.model.chooseXcode() }
                        Button(text("xcode.reset")) { self.model.resetXcode() }
                    }.disabled(self.model.switchingBranch)
                }
                Divider()
                MimicDisclosure(text("diagnostic"), isExpanded: self.$model.settingsDiagnosticsExpanded) {
                    VStack(alignment: .leading, spacing: MimicMetrics.medium) {
                        Button(text("refresh")) { self.model.refresh() }.disabled(self.model.checking || self.model.switchingBranch)
                        Text(self.model.diagnostic).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let project = self.model.project {
                            Text(project.path).font(MimicMetrics.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.font(MimicMetrics.secondary)
            }
        }.font(MimicMetrics.body)
    }
}

/// Project choice belongs to environment settings; full paths distinguish identically named checkouts.
struct ProjectSelectionSettingsView: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.medium) {
            Label(text("project"), systemImage: "folder").font(MimicMetrics.heading)
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
                Text(project.path).font(MimicMetrics.secondary).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.project.path")
                LabeledContent(text("task.commit")) { Text(project.commit).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    .font(MimicMetrics.secondary)
                if let profile = self.model.activeProfile {
                    LabeledContent(text("profile.revision")) { Text(profile.revision).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        .font(MimicMetrics.secondary)
                }
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
            Text(self.title).font(MimicMetrics.secondary).foregroundStyle(.secondary)
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
            HStack(alignment: .firstTextBaseline) {
                Text(self.service).font(MimicMetrics.heading).accessibilityAddTraits(.isHeader)
                Spacer(minLength: MimicMetrics.small)
                Label(text(self.connected ? "settings.connection.connected" : "settings.connection.disconnected"),
                      systemImage: self.connected ? "checkmark.circle" : "link")
                    .font(MimicMetrics.secondary).foregroundStyle(self.connected ? Color.green : Color.secondary)
            }
            self.fields()
            if self.connected { Text(text("settings.token.keep")).font(MimicMetrics.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            self.credential()
            if let unavailable = self.unavailable { Text(unavailable).font(MimicMetrics.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
        }.font(MimicMetrics.body).disabled(self.checking).accessibilityIdentifier(self.identifier + ".settings")
    }
}
