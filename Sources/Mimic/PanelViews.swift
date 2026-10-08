//
//  PanelViews.swift
//  Mimic
//
//  Created by Василий Маслов on 01.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Both documents retain their view identity and scroll position inside one bounded panel.
struct MimicPanel: View {
    private var theme = MimicTheme()
    @ObservedObject
    var model: TaskCoordinator
    @ObservedObject private var layout: PanelLayoutController
    @Environment(\.mimicTextScale) private var textScale

    init(model: TaskCoordinator) { self.model = model; self.layout = model.panelLayout }

    var body: some View {
        VStack(spacing: 0) {
            MimicChrome {
                VStack(spacing: 0) {
                    if theme.tiled { TileGridIdentity(model: model) }
                    else { ProjectBar(model: self.model) }
                }.frame(minHeight: MimicMetrics.footerRow)
                    .padding(.horizontal, MimicMetrics.documentInset).padding(.vertical, MimicMetrics.medium)
            }
            if !theme.tiled { MimicPanelSeparator() }
            if let updater = self.model.updater { MimicUpdateNotice(updater: updater) }
            GeometryReader { bounds in
                ZStack(alignment: .topLeading) {
                    self.homeDocument
                        .environment(\.mimicPresentationVisible, model.panelPage == .home && model.panelVisible)
                        .frame(width: bounds.size.width, height: bounds.size.height)
                        .modifier(MimicPageInteraction(visible: self.model.panelPage == .home))
                    SettingsDocument(model: model).frame(width: bounds.size.width, height: bounds.size.height)
                        .environment(\.mimicPresentationVisible, model.panelPage == .settings && model.panelVisible)
                        .modifier(MimicPageInteraction(visible: self.model.panelPage == .settings))
                }
            }
            if !theme.tiled { MimicPanelSeparator() }
            MimicFooter(model: self.model)
        }.frame(width: model.appearance.selection.panelWidth).frame(maxHeight: .infinity).mimicFont(.body).tint(theme.tiled ? theme.color("accent") : .indigo).buttonStyle(MimicButtonStyle())
            .background(theme.tiled ? theme.color("paper") : Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay(alignment: .topTrailing) { chromeOverlay }
            .modifier(MimicAppearanceRoot(store: model.appearance))
            .environment(\.mimicMotionSettings, self.model.motionSettings)
            .environment(\.mimicPresentationVisible, model.panelVisible)
            .accessibilityIdentifier("toolbox.panel")
            .disabled(self.model.updateReserved)
            .onChange(of: model.panelPage) { _, _ in layout.cancelPresentation() }
            .onChange(of: model.selectedProjectPath) { _, _ in layout.cancelPresentation() }
    }

    /// Keep popovers in the owning window so click-away dismissal and Escape share the panel's lifecycle.
    @ViewBuilder private var chromeOverlay: some View {
        if theme.tiled, model.panelPage == .home, layout.catalogVisible || model.expandedSection == .branches {
            GeometryReader { bounds in
                let top = max(32, 24 * textScale) + 24
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { dismissChromeOverlay() }.accessibilityHidden(true)
                    Group {
                        if layout.catalogVisible {
                            PanelTileCatalog(model: model, layout: layout).frame(width: min(292 * max(1, textScale), bounds.size.width - 64))
                        } else {
                            BranchPicker(model: model).frame(width: bounds.size.width - 64, height: min(400, max(80, bounds.size.height - top - 32)))
                        }
                    }.padding(16).background(theme.color("raised"), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color("line"), lineWidth: 1))
                        .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
                        .padding(.horizontal, 16)
                }.padding(.top, top)
            }
        }
    }
    private func dismissChromeOverlay() {
        layout.cancelPresentation()
        if model.expandedSection == .branches { model.expandedSection = nil }
    }

    private var homeDocument: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MimicMetrics.large) {
                    PanelMessages(model: self.model)
                    MimicCollapse(expanded: !theme.tiled && self.model.expandedSection == .branches, source: self.model.navigationSource) {
                        Surface { BranchPicker(model: self.model) }.id(PanelSection.branches.scrollID)
                    }
                    if self.model.hasCompatibleProfile { HomePage(model: self.model) }
                    else { ProfileSetupView(model: self.model) }
                }.padding(MimicMetrics.documentInset)
                    .background(MimicDocumentVisibility(page: .home, visible: self.model.panelPage == .home))
            }.scrollIndicators(.hidden).modifier(MimicScrollEdges())
                .modifier(MimicPanelScrollDriver(model: self.model, scroll: self.model.panelScroll, page: .home, proxy: proxy))
        }
    }

}

/// The available width selects sidebar or menu without replacing retained category bodies.
struct SettingsDocument: View {
    @ObservedObject var model: TaskCoordinator
    @Environment(\.mimicTextScale) private var textScale
    private var theme = MimicTheme()
    var body: some View {
        GeometryReader { bounds in
            VStack(spacing: 0) {
                SettingsNavigationBar(model: model)
                let compact = bounds.size.width < 500 || textScale > 1.2
                HStack(alignment: .top, spacing: compact ? 0 : 12) {
                    if !compact {
                        ScrollView { SettingsCategoryNavigation(model: model) }.scrollIndicators(.hidden)
                            .frame(width: 132).padding(.leading, 16).padding(.vertical, 16)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Color.clear.frame(height: 0).id("settings.top").accessibilityHidden(true)
                                if compact { SettingsCategoryNavigation(model: model, compact: true) }
                                PanelMessages(model: model)
                                SettingsContent(model: model)
                            }.padding(.vertical, 16).padding(.trailing, 16).padding(.leading, compact ? 16 : 0)
                                .background(MimicDocumentVisibility(page: .settings, visible: model.panelPage == .settings))
                        }.scrollIndicators(.hidden).modifier(MimicScrollEdges())
                            .modifier(MimicPanelScrollDriver(model: model, scroll: model.settingsScroll, page: .settings, proxy: proxy))
                    }
                }
            }
        }.background(theme.color("paper")).foregroundStyle(theme.color("ink")).tint(theme.color("accent"))
            .buttonStyle(TileGridButtonStyle())
            // Settings share B typography and text scaling even in the legacy working panel.
            .environment(\.mimicPanelAppearance, .tileGrid)
    }
}

/// Observes only scroll requests, without rebuilding the panel document on cancellation.
private struct MimicPanelScrollDriver: ViewModifier {
    let model: TaskCoordinator
    @ObservedObject var scroll: MimicPanelScroll
    let page: PanelPage
    let proxy: ScrollViewProxy
    func body(content: Content) -> some View {
        content.background(MimicScrollCancellation(cancel: { self.model.panelPage == self.page && self.scroll.cancel() }))
            .onChange(of: scroll.request) { _, _ in scrollPanel(using: proxy) }
            .onAppear { scrollPanel(using: proxy) }
    }
    private func scrollPanel(using proxy: ScrollViewProxy) {
        let request = self.scroll.request, target = self.scroll.target
        guard self.model.panelPage == self.page, !target.isEmpty else { return }
        let policy = MimicMotionPolicy(source: self.scroll.source, reduceMotion: self.model.motionSettings.nativeReduceMotion, multiplier: self.model.motionSettings.multiplier)
        // Reveal the lazy history row before seeking a terminal or analysis inside it.
        DispatchQueue.main.async {
            guard self.model.panelPage == self.page, self.scroll.isActive(request) else { return }
            if let selected = self.model.selectedTaskID, target.hasPrefix("terminal.") || target.hasPrefix("analysis.") {
                proxy.scrollTo("task." + selected.uuidString, anchor: .top)
            }
            DispatchQueue.main.async {
                guard self.model.panelPage == self.page, self.scroll.isActive(request) else { return }
                withAnimation(policy.moves ? policy.animation(.disclosure) : nil) { proxy.scrollTo(target, anchor: .top) }
                if policy.moves {
                    DispatchQueue.main.asyncAfter(deadline: .now() + policy.duration(.disclosure)) { self.scroll.complete(request) }
                } else { self.scroll.complete(request) }
            }
        }
    }
}

func disclosureValue(_ expanded: Bool) -> String { text(expanded ? "panel.expanded" : "panel.collapsed") }

struct ProjectBar: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let project = model.project {
                    Button { model.toggleSection(.branches); if model.expandedSection == .branches { model.loadBranches() } } label: {
                        Label(project.branch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                    }.buttonStyle(.plain).mimicFont(.caption).disabled(model.switchingBranch)
                        .help(project.branch).accessibilityIdentifier("branch.toggle")
                        .accessibilityLabel(text("branch.choose")).accessibilityValue(project.branch)
                        .layoutPriority(-1)
                    Spacer(minLength: 2)
                    Toggle(text("branch.rebase"), isOn: Binding(
                        get: { model.branchSwitch.rebaseEnabled(path: project.path) },
                        set: { value in do { try model.branchSwitch.setRebase(value, path: project.path) } catch { model.branchError = text("branch.blocked") } }
                    )).toggleStyle(.checkbox).mimicFont(.caption).fixedSize()
                        .disabled(model.switchingBranch).help(text("branch.rebase.help"))
                        .accessibilityIdentifier("branch.rebase")
                } else { Text(text("project.no.branch")).mimicFont(.caption); Spacer() }
                Button { model.toggleSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help(text("settings")).accessibilityIdentifier("settings.toggle")
            }.foregroundStyle(.secondary)
            if let project = model.project, let operation = model.branchSwitch.latest(path: project.path) {
                BranchSwitchStatus(model: model, operation: operation)
            }
        }
    }
}

struct BranchSwitchStatus: View {
    @ObservedObject var model: TaskCoordinator
    let operation: BranchSwitchOperation
    var body: some View {
        if operation.phase != .succeeded || operation.stashSHA != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if model.branchSwitch.isExecuting { ProgressView().controlSize(.mini) }
                    Text(text("branch.phase." + operation.phase.rawValue)).lineLimit(2)
                    Spacer(minLength: 0)
                    if let thread = operation.ownerThreadID, let url = URL(string: "codex://threads/" + thread.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) {
                        Button(text("branch.codex.open")) { NSWorkspace.shared.open(url) }.buttonStyle(.plain)
                    } else if operation.phase == .awaitingAgent && ![.reserved, .sent, .unknown].contains(operation.delivery) {
                        Button(text("branch.codex.open")) { try? model.branchSwitch.openChat(operation.id) }.buttonStyle(.plain)
                    }
                    if operation.phase.holdsCheckout && (operation.ownerThreadID == nil || operation.phase == .needsReview) {
                        Button(text(operation.phase == .needsReview ? "branch.review.acknowledge" : "cancel")) {
                            Task { do { _ = try await model.branchSwitch.cancel(operation.id) } catch { model.branchError = text("branch.error.review") } }
                        }.buttonStyle(.plain)
                    }
                }
                if operation.phase == .awaitingAgent {
                    Text(text("branch.delivery." + operation.delivery.rawValue)).foregroundStyle(.secondary)
                }
                if let error = operation.error { Text(text(error)).foregroundStyle(.orange).lineLimit(3).help(text(error)) }
                if let stash = operation.stashName { Text(text("branch.stash.backup") + " " + stash).lineLimit(1).truncationMode(.middle).help(stash) }
            }.mimicFont(.caption).accessibilityIdentifier("branch.progress")
        }
    }
}

struct BranchPicker: View {
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var textScale
    @ObservedObject
    var model: TaskCoordinator
    private var branches: [LocalBranch] {
        let matching = self.model.localBranches.filter { self.model.branchSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(self.model.branchSearch) }
        return matching.filter { $0.name == self.model.project?.branch } + matching.filter { $0.name != self.model.project?.branch }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.large) {
            HStack {
                Text(text("branch.choose")).mimicFont(.heading).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if theme.tiled {
                    MimicChromeIconButton(symbol: "xmark", label: text("panel.chrome.close"), identifier: "branch.close") { model.expandedSection = nil }
                }
            }
            TextField(text("branch.search"), text: self.$model.branchSearch).textFieldStyle(.roundedBorder).mimicFont(.body).mimicImmediate().accessibilityIdentifier("branch.search")
            if self.model.loadingBranches { ProgressView().controlSize(.small) }
            if let blocker = self.model.branchSwitchBlocker {
                Text(blocker.message).mimicFont(.caption).foregroundStyle(.orange).accessibilityIdentifier("branch.blocker")
            }
            if !self.model.branchError.isEmpty, self.model.branchError != self.model.branchSwitchBlocker?.message {
                Text(self.model.branchError).mimicFont(.caption).foregroundStyle(.orange).accessibilityIdentifier("branch.error")
            }
            if theme.tiled { ScrollView { branchList } }
            else { branchList }
            if theme.tiled, let project = model.project {
                theme.color("line").frame(height: 1).accessibilityHidden(true)
                Toggle(text("branch.rebase"), isOn: Binding(
                    get: { model.branchSwitch.rebaseEnabled(path: project.path) },
                    set: { value in do { try model.branchSwitch.setRebase(value, path: project.path) } catch { model.branchError = text("branch.blocked") } }
                )).toggleStyle(.checkbox).mimicFont(.body).disabled(model.switchingBranch)
                    .help(text("branch.rebase.help")).accessibilityIdentifier("branch.rebase")
                Text(text("branch.rebase.help")).mimicFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Only the branch list scrolls in B2; search and Rebase stay visible before a selection.
    private var branchList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(self.branches) { branch in
                Button { self.model.switchBranch(branch.name) } label: {
                    HStack {
                        Text(branch.name).font(theme.tiled ? .system(size: MimicTheme.metric("body") * textScale, design: .monospaced) : MimicMetrics.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if branch.name == self.model.project?.branch { Image(systemName: "checkmark") }
                    }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!self.model.canSwitchBranch && branch.name != self.model.project?.branch)
                    .help(branch.name).accessibilityIdentifier("branch.select." + branch.name)
            }
        }
    }
}

struct HomePage: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View { PanelGrid(model: model, layout: model.panelLayout) }
}

struct ToolRow: View {
    @ObservedObject
    var model: TaskCoordinator
    let action: MimicAction
    private var expanded: Bool { self.model.expandedSection == .tool(self.action) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { self.model.toggleSection(.tool(self.action)) } label: {
                HStack(spacing: MimicMetrics.medium) {
                    Image(systemName: ActionPresentation.symbol(self.action)).foregroundStyle(.secondary).frame(width: 20)
                    Text(text("tool.name." + self.action.rawValue)).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let missing = model.readiness[action], !missing.isEmpty { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(missing.joined(separator: ", ")) }
                    Image(systemName: self.expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets(top: MimicMetrics.medium, leading: MimicMetrics.medium, bottom: MimicMetrics.medium, trailing: MimicMetrics.medium))).accessibilityIdentifier(self.action.rawValue).accessibilityValue(disclosureValue(self.expanded))
            MimicCollapse(expanded: self.expanded, source: self.model.navigationSource) { ToolContent(model: self.model, action: self.action).padding(.bottom, 12) }
        }.id(PanelSection.tool(self.action).scrollID)
    }
}

struct InlineMessage: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(self.message).mimicFont(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: self.dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(text("dismiss"))
        }
    }
}
