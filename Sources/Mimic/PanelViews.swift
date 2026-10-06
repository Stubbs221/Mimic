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
    @ObservedObject
    var model: TaskCoordinator

    init(model: TaskCoordinator) { self.model = model }

    var body: some View {
        VStack(spacing: 0) {
            MimicChrome {
                ProjectBar(model: self.model).frame(height: MimicMetrics.footerRow)
                    .padding(.horizontal, MimicMetrics.documentInset).padding(.vertical, MimicMetrics.medium)
            }
            MimicPanelSeparator()
            GeometryReader { bounds in
                ZStack(alignment: .topLeading) {
                    self.homeDocument
                        .frame(width: bounds.size.width, height: bounds.size.height)
                        .modifier(MimicPageInteraction(visible: self.model.panelPage == .home))
                    VStack(spacing: 0) {
                        SettingsNavigationBar(model: self.model)
                        MimicPanelSeparator()
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: MimicMetrics.large) {
                                    PanelMessages(model: self.model)
                                    SettingsContent(model: self.model)
                                }.padding(MimicMetrics.documentInset)
                                    .background(MimicDocumentVisibility(page: .settings, visible: self.model.panelPage == .settings))
                            }.modifier(MimicScrollEdges())
                                .modifier(MimicPanelScrollDriver(model: self.model, scroll: self.model.settingsScroll, page: .settings, proxy: proxy))
                        }
                    }.frame(width: bounds.size.width, height: bounds.size.height)
                        .modifier(MimicPageInteraction(visible: self.model.panelPage == .settings))
                }
            }
            MimicPanelSeparator()
            MimicFooter(model: self.model)
        }.frame(width: MimicMetrics.panelWidth).frame(maxHeight: .infinity).font(MimicMetrics.body).tint(.indigo).buttonStyle(MimicButtonStyle())
            .background(Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
            .environment(\.mimicMotionSettings, self.model.motionSettings)
            .accessibilityIdentifier("toolbox.panel")
    }

    private var homeDocument: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MimicMetrics.large) {
                    PanelMessages(model: self.model)
                    MimicCollapse(expanded: self.model.expandedSection == .branches, source: self.model.navigationSource) {
                        Surface { BranchPicker(model: self.model) }.id(PanelSection.branches.scrollID)
                    }
                    if self.model.hasCompatibleProfile { HomePage(model: self.model) }
                    else { ProfileSetupView(model: self.model) }
                }.padding(MimicMetrics.documentInset)
                    .background(MimicDocumentVisibility(page: .home, visible: self.model.panelPage == .home))
            }.modifier(MimicScrollEdges())
                .modifier(MimicPanelScrollDriver(model: self.model, scroll: self.model.panelScroll, page: .home, proxy: proxy))
        }
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
        HStack(spacing: 6) {
            if let project = model.project {
                Button { model.toggleSection(.branches); if model.expandedSection == .branches { model.loadBranches() } } label: {
                    Label(project.branch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).font(MimicMetrics.secondary).disabled(model.switchingBranch)
                    .help(project.branch).accessibilityIdentifier("branch.toggle")
                    .accessibilityLabel(text("branch.choose")).accessibilityValue(project.branch)
            } else { Text(text("project.no.branch")).font(MimicMetrics.secondary) }
            Spacer(minLength: 2)
            Button { model.toggleSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help(text("settings")).accessibilityIdentifier("settings.toggle")
        }.foregroundStyle(.secondary)
    }
}

struct BranchPicker: View {
    @ObservedObject
    var model: TaskCoordinator
    private var branches: [LocalBranch] {
        let matching = self.model.localBranches.filter { self.model.branchSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(self.model.branchSearch) }
        return matching.filter { $0.name == self.model.project?.branch } + matching.filter { $0.name != self.model.project?.branch }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.large) {
            Text(text("branch.choose")).font(MimicMetrics.heading).accessibilityAddTraits(.isHeader)
            TextField(text("branch.search"), text: self.$model.branchSearch).textFieldStyle(.roundedBorder).mimicImmediate().accessibilityIdentifier("branch.search")
            if self.model.loadingBranches { ProgressView().controlSize(.small) }
            if !self.model.canSwitchBranch { Text(text(self.model.hasGitOperation ? "branch.operation" : self.model.gitSummary.map { $0.changed + $0.untracked > 0 } == true ? "branch.dirty" : "branch.blocked")).font(MimicMetrics.secondary).foregroundStyle(.orange) }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(self.branches) { branch in
                    Button {
                        if branch.name != self.model.project?.branch { self.model.switchBranch(branch.name) }
                        self.model.toggleSection(.branches)
                    } label: {
                        HStack {
                            Text(branch.name).font(MimicMetrics.body.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if branch.name == self.model.project?.branch { Image(systemName: "checkmark") }
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!self.model.canSwitchBranch && branch.name != self.model.project?.branch)
                }
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
            Text(self.message).font(MimicMetrics.secondary).textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: self.dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(text("dismiss"))
        }
    }
}
