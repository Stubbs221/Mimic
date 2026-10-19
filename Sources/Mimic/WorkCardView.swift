// Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Approved B23/02 keeps the task bounded; documents and secondary commands open on demand.
struct WorkCardView: View {
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var textScale
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var work: WorkCoordinator
    var full: Bool
    @State private var popup = ""
    @State private var query = ""
    @State private var service = "jira"
    @State private var result = WorkSearchResult()
    @State private var document: WorkDocument?
    @State private var busy = false
    @State private var notice = ""
    @State private var selected: Set<String> = []
    @State private var draft = ""
    @State private var reportReady = false
    private let owner = "desktop"
    #if DEBUG
    private var fixtureSnapshot: WorkContextSnapshot?
    private var fixtureMode = false
    private var fixturePopupKind = ""
    /// A presentation fixture skips polling and never invokes an Atlassian client.
    init(model: TaskCoordinator, full: Bool, fixturePopup: String, snapshot: WorkContextSnapshot? = nil) {
        self.model = model; self.work = model.work; self.full = full; fixtureSnapshot = snapshot; fixtureMode = true; fixturePopupKind = fixturePopup
        _query = State(initialValue: "Очень длинное русское название задачи")
        _draft = State(initialValue: "Сохранённый черновик отчёта\n" + String(repeating: "Безопасные фикстурные данные. ", count: 20)); _reportReady = State(initialValue: true)
    }
    #endif
    private var snapshot: WorkContextSnapshot {
        #if DEBUG
        if let fixtureSnapshot { return fixtureSnapshot }
        #endif
        return work.contexts.snapshot(owner)
    }
    private var identity: String { [model.project?.path ?? "", model.project?.branch ?? "", model.activeProfile?.revision ?? "", work.contexts.currentIdentity(owner) ?? ""].joined(separator: "\n") }
    init(model: TaskCoordinator, full: Bool) { self.model = model; self.work = model.work; self.full = full }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button((snapshot.issue?.key ?? text("work.choose")) + " ⌄") { popup = "actions" }
                    .buttonStyle(WorkCardButtonStyle(width: 114, leading: true))
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Text(status).mimicFont(.caption).foregroundStyle(theme.color("muted")).lineLimit(1)
                    .mimicHelp(statusDetail)
                Spacer(minLength: 0)
            }
            if let issue = snapshot.issue {
                Button { popup = "criteria" } label: {
                    Text(issue.title).mimicFont(full ? .workTitle : .body, weight: .semibold)
                        .lineLimit(2).truncationMode(.tail).lineSpacing(2 * textScale)
                        .frame(maxWidth: .infinity, minHeight: (full ? 23 : 34) * textScale, alignment: .topLeading)
                }.buttonStyle(.plain).mimicHelp(issue.title)
                HStack(spacing: 8) {
                    Button(text(full ? "work.context.copy" : "work.context")) { copy(issue.contextText) }
                        .buttonStyle(WorkCardButtonStyle(primary: true, width: full ? 164 : 96))
                    Button(text("work.documents") + (full ? " · \(issue.documents.count)" : "")) { document = nil; popup = "documents" }
                        .buttonStyle(WorkCardButtonStyle(width: full ? 128 : nil, fillsWidth: !full))
                }.lineLimit(1)
            } else {
                Text(text("work.phase." + snapshot.phase)).mimicFont(.body).lineLimit(2)
                    .mimicHelp(text("work.phase." + snapshot.phase))
                if snapshot.phase != "loading" {
                    Button(text(snapshot.phase == "choose" || snapshot.phase == "empty" ? "work.choose" : "work.connect")) {
                        popup = snapshot.phase == "choose" || snapshot.phase == "empty" ? "search" : "connection"
                    }.buttonStyle(MimicAuxiliaryButtonStyle(primary: true))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .background(PanelControlRegion())
            .mimicPopover(isPresented: Binding(get: { !popup.isEmpty }, set: { if !$0 { popup = "" } }), width: 440) { popover }
            .task(id: identity + String(model.panelVisible)) {
                #if DEBUG
                if fixtureMode {
                    try? await Task.sleep(for: .milliseconds(200))
                    if !Task.isCancelled { popup = fixturePopupKind }
                    return
                }
                #endif
                popup = ""; notice = ""; query = ""; reportReady = false
                while !Task.isCancelled && model.panelVisible { await refresh(); try? await Task.sleep(for: .seconds(30)) }
            }
            .accessibilityIdentifier(full ? "work.full" : "work.mini")
    }
    // MARK: - Secondary actions

    private var status: String {
        if !notice.isEmpty { return notice }
        if snapshot.error != nil || snapshot.stale { return text("work.stale") }
        if snapshot.phase == "loading" { return text("work.phase.loading") }
        return snapshot.issue?.status ?? ""
    }
    private var statusDetail: String {
        if let error = snapshot.error { return text("work.error." + error.rawValue) }
        return [status, snapshot.fetchedAt?.formatted() ?? "", snapshot.issue?.incomplete == true ? text("work.incomplete") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue = snapshot.issue {
                Button(text("work.openJira")) { open(issue.url) }.buttonStyle(RowButtonStyle())
                Button(text("work.criteria") + " · \(issue.requirements.count)") { popup = "criteria" }.buttonStyle(RowButtonStyle())
                Button(text("work.report")) { openReport() }.buttonStyle(RowButtonStyle())
            }
            Button(text("work.choose")) { service = "jira"; popup = "search" }.buttonStyle(RowButtonStyle())
            ForEach(snapshot.candidates, id: \.self) { key in Button(key) { select(key) }.buttonStyle(RowButtonStyle()) }
            Button(text("work.search.confluence")) { service = "confluence"; popup = "search" }.buttonStyle(RowButtonStyle())
            Button(text("refresh")) { Task { await refresh(force: true) } }.buttonStyle(RowButtonStyle()).disabled(snapshot.phase == "loading")
            Button(text("work.connect")) { popup = "connection" }.buttonStyle(RowButtonStyle())
            if let error = snapshot.error { Text(text("work.error." + error.rawValue)).mimicFont(.caption) }
        }
    }
    private func open(_ value: String) { if let url = URL(string: value) { NSWorkspace.shared.open(url) } }
    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(text("work.popup." + popup)).mimicFont(.heading); Spacer(); Button(text("work.close")) { popup = "" }.buttonStyle(.plain) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if popup == "actions" { actions }
                    if popup == "connection" { connection }
                    if popup == "search" { search }
                    if popup == "documents" || popup == "reader" { documents }
                    if popup == "criteria", let issue = snapshot.issue { Text(issue.description).textSelection(.enabled); ForEach(issue.requirements.keys.sorted(), id: \.self) { key in Text(key).bold(); Text(issue.requirements[key] ?? "").textSelection(.enabled) } }
                    if popup == "report" { report }
                    if busy { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, theme.retro ? 17 : 0)
            }.scrollIndicators(theme.retro ? .hidden : .automatic).mimicRetroScrollbars().frame(maxHeight: 440)
        }.padding(16).frame(width: 420).mimicFont(.body)
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let presets = model.activeProfile?.profile.services?.atlassian ?? []
            if presets.isEmpty { Text(text("work.unconfigured")) }
            ForEach(presets) { preset in
                Button(preset.title + (snapshot.presetID == preset.id ? " ✓" : "")) { work.choose(preset.id, project: model.project, profile: model.activeProfile); Task { await refresh(force: true) } }.buttonStyle(MimicAuxiliaryButtonStyle())
            }
            Button(text("work.connect")) { Task { await work.connect(project: model.project, profile: model.activeProfile, appearance: model.appearance); await refresh(force: true) } }.buttonStyle(MimicAuxiliaryButtonStyle(primary: true)).disabled(work.connecting || presets.isEmpty)
            Button(text("work.disconnect")) { work.disconnect(project: model.project, profile: model.activeProfile); Task { await refresh(force: true) } }.buttonStyle(MimicAuxiliaryButtonStyle()).disabled(work.connecting)
            if !work.message.isEmpty { Text(work.message).mimicFont(.caption) }
        }
    }
    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(text("work.search.placeholder"), text: $query).textFieldStyle(.roundedBorder).mimicInput().onSubmit { searchMore() }
            Picker(text("work.search.service"), selection: $service) { Text("Jira").tag("jira"); Text("Confluence").tag("confluence") }.pickerStyle(.segmented)
                .mimicSegments(selection: $service, options: [.init("Jira", "jira"), .init("Confluence", "confluence")])
            Button(text("work.search")) { searchMore() }.buttonStyle(MimicAuxiliaryButtonStyle()).disabled(busy || query.isEmpty)
            if service == "jira" { ForEach(result.issues) { issue in Button(issue.key + " · " + issue.title) { select(issue.key) }.buttonStyle(RowButtonStyle()) } }
            else { ForEach(result.documents) { page in Button(page.title) { load(page) }.buttonStyle(RowButtonStyle()) } }
            if result.nextCursor != nil { Button(text("work.more")) { searchMore(cursor: result.nextCursor) }.buttonStyle(MimicAuxiliaryButtonStyle()) }
            Button(text("work.connect")) { popup = "connection" }.buttonStyle(MimicAuxiliaryButtonStyle())
        }
    }
    @ViewBuilder private var documents: some View {
        if let document {
            Text(document.title).mimicFont(.heading); Text(document.content ?? "").textSelection(.enabled)
            if document.incomplete { Text(text("work.incomplete")) }
            if let offset = document.nextOffset { Button(text("work.more")) { load(document, offset: offset) }.buttonStyle(MimicAuxiliaryButtonStyle()) }
            Button(text("work.openOriginal")) { if let url = URL(string: document.url) { NSWorkspace.shared.open(url) } }.buttonStyle(MimicAuxiliaryButtonStyle())
        } else {
            if snapshot.issue?.documents.isEmpty != false { Text(text("work.documents.empty")).foregroundStyle(.secondary) }
            ForEach(snapshot.issue?.documents ?? []) { page in
                HStack(spacing: 8) {
                    Button(page.title + (popup == "reader" ? "" : " ↗")) { if popup == "reader" { load(page) } else { open(page.url) } }
                        .buttonStyle(RowButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
                    Button { copy(page.url, message: "work.link.copied") } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(MimicAuxiliaryButtonStyle(height: 32, horizontalPadding: 8)).mimicHelp(text("work.link.copy"))
                }
            }
            if popup != "reader" { Button(text("work.readHere")) { popup = "reader" }.buttonStyle(MimicAuxiliaryButtonStyle()) }
            Button(text("work.search.confluence")) { service = "confluence"; popup = "search" }.buttonStyle(MimicAuxiliaryButtonStyle())
        }
    }
    private var report: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.workEvidence(project: model.project)) { evidence in Toggle(evidence.title + " · " + evidence.result, isOn: Binding(get: { selected.contains(evidence.id) }, set: { if $0 { selected.insert(evidence.id) } else { selected.remove(evidence.id) } })).toggleStyle(MimicCheckboxStyle()) }
            Button(text("work.report.prepare")) { Task { await operation { draft = try await model.workReport(owner: owner, project: model.project, selected: selected.sorted()); reportReady = true } } }.buttonStyle(MimicAuxiliaryButtonStyle()).disabled(busy)
            if reportReady {
                TextEditor(text: $draft).frame(minHeight: 180).mimicInput()
                Button(text("work.copy")) { copy(draft) }.buttonStyle(MimicAuxiliaryButtonStyle(primary: true))
                Button(text("work.agent.request")) { copy(text("work.agent.prompt") + "\n\n" + draft) }.buttonStyle(MimicAuxiliaryButtonStyle())
            }
        }
    }
    private func refresh(force: Bool = false) async { await work.refresh(owner: owner, project: model.project, profile: model.activeProfile, force: force) }
    private func copy(_ value: String, message: String = "work.copied") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); notice = text(message) }
    private func openReport() { selected = []; draft = ""; reportReady = false; popup = "report" }
    private func select(_ key: String) { Task { await operation { try work.contexts.select(key, owner: owner); await work.contexts.refresh(owner, force: true); popup = "" } } }
    private func searchMore(cursor: String? = nil) { Task { await operation {
        if service == "jira", cursor == nil, let preset = work.contexts.preset(owner), let key = try? WorkReference.issue(query, preset: preset) { let issue = try await work.contexts.client(owner).issue(key); result = .init(issues: [issue]) }
        else { result = try await work.contexts.client(owner).search(query, service: service, cursor: cursor) }
    } } }
    private func load(_ page: WorkDocument, offset: Int = 0) { Task { await operation { let next = try await work.contexts.client(owner).page(page.id, offset: offset); document = next; popup = "documents" } } }
    private func operation(_ body: () async throws -> Void) async {
        guard !busy else { return }; busy = true; let oldIdentity = identity; defer { busy = false }
        do { try await body(); if identity != oldIdentity { result = .init(); document = nil; popup = "" } }
        catch { notice = text("work.error." + ((error as? AtlassianError)?.rawValue ?? "network")) }
    }
}

/// B23 uses fixed control slots and transparent secondary commands in both compact sizes.
private struct WorkCardButtonStyle: PrimitiveButtonStyle {
    var primary = false
    var width: CGFloat?
    var fillsWidth = false
    var leading = false
    private var theme = MimicTheme()
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if theme.retro {
            Button(configuration).buttonStyle(NativeRetroPrimitiveButtonStyle(height: 28))
        } else {
            Button(configuration).buttonStyle(WorkCardButtonArtwork(primary: primary, width: width, fillsWidth: fillsWidth, leading: leading))
        }
    }
}

private struct WorkCardButtonArtwork: ButtonStyle {
    var primary: Bool
    var width: CGFloat?
    var fillsWidth: Bool
    var leading: Bool
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var scale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.mimicFont(.body, weight: .semibold).lineLimit(1)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: leading ? .leading : .center)
            .padding(.horizontal, 8).frame(width: width, height: 32 * scale, alignment: leading ? .leading : .center)
            .foregroundStyle(theme.color(primary ? "surface" : "ink"))
            .background(primary ? theme.color("ink") : hovered ? theme.color("accentSoft") : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color("accent").opacity(focused ? 1 : 0), lineWidth: 2))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10)).onHover { hovered = $0 }
    }
}
