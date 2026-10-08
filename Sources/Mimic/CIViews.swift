//
//  CIViews.swift
//  Mimic
//
//  Created by Василий Маслов on 02.10.2026.
import AppKit
import SwiftUI
import MimicCore

struct CIStatusBadge: View {
    let status: String
    private var color: Color { FooterCIStatus.pipelineColor(self.status) }
    private var symbol: String { FooterCIStatus.pipelineSymbol(self.status) }

    var body: some View {
        let localized = text("ci.status." + self.status)
        Label(localized.hasPrefix("ci.status.") ? self.status : localized, systemImage: self.symbol).mimicFont(.caption).foregroundStyle(self.color).mimicStatus(self.status)
    }
}

/// One bounded history combines personal and subscribed pipelines; launch preferences never filter it.
struct CISection: View {
    @ObservedObject var state: CIState
    @ObservedObject var settings: CISettingsModel
    var launch: CILaunchModel? = nil
    var jenkins: JenkinsSettings? = nil
    var openSettings: (() -> Void)? = nil
    var showsHeader = true
    var presented = true
    @Binding var expanded: Bool
    @State private var showingSearch = false
    @State private var userQuery = ""

    var body: some View {
        if self.state.context?.connection != nil || self.settings.connection != nil {
            VStack(alignment: .leading, spacing: MimicMetrics.medium) {
                HStack {
                    if self.showsHeader { Text("CI").mimicFont(.heading).accessibilityAddTraits(.isHeader) }
                    if let owner = self.state.user { Text("@" + owner.username).mimicFont(.caption).foregroundStyle(.secondary).lineLimit(1).help(owner.name) }
                    Spacer(minLength: 4)
                    if self.state.loading { ProgressView().controlSize(.small) }
                    Button { self.state.refresh(manual: true) } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                        .buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).disabled(self.state.loading).accessibilityLabel(text("refresh"))
                }
                if self.expanded {
                    if let connection = self.state.context?.connection ?? self.settings.connection {
                        CICredentialAccessView(session: self.settings.credentialSession, id: connection.id, service: "GitLab", openSettings: self.openSettings) { await self.settings.requestCredentialAccess(connection: connection) }
                    }
                    if let jenkins, let connection = jenkins.connection {
                        CICredentialAccessView(session: jenkins.credentialSession, id: connection.id, service: "Jenkins", openSettings: self.openSettings) { await jenkins.requestCredentialAccess() }
                    }

                    if let launch { CILaunchActions(launch: launch, preferences: launch.preferences, presented: self.presented) }
                    if let error = self.state.error, error != .credential, self.settings.connection.flatMap({ self.settings.credentialSession.failures[$0.id] }) == nil {
                        Text(text(error.localizationKey)).mimicFont(.caption).foregroundStyle(.orange)
                    }
                    if self.state.error != nil, let date = self.state.loadedAt {
                        Text(text("ci.stale") + " · " + date.formatted(date: .omitted, time: .shortened)).mimicFont(.caption).foregroundStyle(.secondary)
                    }
                    Text(text("ci.feed.title")).mimicFont(.caption, weight: .semibold).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    if self.state.visibleEntries.isEmpty, self.state.error == nil {
                        Text(text(self.state.loading ? "ci.loading" : "ci.empty")).mimicFont(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(self.state.visibleEntries) { entry in
                        CIPipelineCard(state: self.state, entry: entry)
                        Divider()
                    }
                    if self.state.historyIncomplete { Text(text("ci.history.incomplete")).mimicFont(.caption).foregroundStyle(.secondary) }
                    if self.state.canShowMore {
                        Button(text("ci.feed.more")) { self.state.showMore() }.buttonStyle(RowButtonStyle())
                            .disabled(self.state.loading).accessibilityIdentifier("ci.feed.more")
                    }
                    DisclosureGroup(text("ci.tracked.title")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(self.state.trackedUsers) { group in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.user.name).lineLimit(2).help(group.user.name)
                                        Text("@" + group.user.username).foregroundStyle(.secondary).lineLimit(1).help(group.user.username)
                                        if let error = group.error, error != .credential, error != .authentication { Text(text(error.localizationKey)).foregroundStyle(.orange) }
                                    }
                                    Spacer(minLength: 4)
                                    Button { self.state.untrack(group.id) } label: { Image(systemName: "person.badge.minus") }
                                        .buttonStyle(RowButtonStyle()).help(text("ci.tracking.stop"))
                                        .accessibilityLabel(text("ci.tracking.stop") + " · " + group.user.name)
                                }
                            }
                            Button(text("ci.tracking.add")) { self.showingSearch.toggle(); if !self.showingSearch { self.userQuery = ""; self.state.searchUsers("") } }
                                .disabled(self.state.user == nil).accessibilityIdentifier("ci.tracking.add")
                            if self.showingSearch { self.memberSearch }
                        }.padding(.top, 6)
                    }.mimicFont(.caption)
                }
            }
            .onAppear { self.state.setFeedPresented(self.expanded && self.presented, preserveSelection: self.expanded && !self.presented) }
            .onDisappear { self.state.setFeedPresented(false) }
            .onChange(of: self.expanded) { _, value in self.state.setFeedPresented(value && self.presented, preserveSelection: value && !self.presented) }
            .onChange(of: self.presented) { _, value in self.state.setFeedPresented(value && self.expanded, preserveSelection: self.expanded && !value) }
            .onChange(of: self.state.context) { _, _ in self.launch?.contextChanged() }
            .onChange(of: self.state.user?.id) { _, _ in self.userQuery = ""; self.showingSearch = false }
        }
    }

    private var memberSearch: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(text("ci.tracking.search"), text: self.$userQuery).textFieldStyle(.roundedBorder)
                .accessibilityLabel(text("ci.tracking.search")).accessibilityIdentifier("ci.tracking.search")
                .onChange(of: self.userQuery) { _, query in self.state.searchUsers(query) }
            if self.state.searching { ProgressView().controlSize(.small) }
            if let error = self.state.searchError { Text(text(error.localizationKey)).foregroundStyle(.orange) }
            if !self.userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !self.state.searching, self.state.searchError == nil, self.state.searchResults.isEmpty {
                Text(text("ci.tracking.noResults")).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.state.searchResults) { user in
                        Button { self.state.track(user); self.userQuery = ""; self.showingSearch = false } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name).lineLimit(2)
                                Text("@" + user.username).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(RowButtonStyle()).help(user.name + " · @" + user.username)
                            .accessibilityLabel(text("ci.tracking.add") + " · " + user.name + " · @" + user.username)
                    }
                }
            }.frame(maxHeight: 180)
        }.mimicFont(.body)
    }

}

struct CIPipelineDetailsView: View {
    @ObservedObject
    var state: CIState
    private var stages: [String] {
        var seen = Set<String>()
        return (self.state.details?.jobs ?? []).sorted { $0.id < $1.id }.map(\.stage).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.state.loadingDetails { ProgressView().controlSize(.small) }
            if let error = state.detailError, error != .credential, error != .authentication { Text(text(error.localizationKey)).foregroundStyle(.orange) }
            if let details = state.details {
                ForEach(self.stages, id: \.self) { stage in
                    Text(stage).mimicFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    ForEach(details.jobs.filter { $0.stage == stage }.sorted { $0.id < $1.id }) { job in
                        HStack {
                            Text(job.name).lineLimit(1).truncationMode(.middle).help(job.name)
                            Spacer()
                            if job.allowFailure { Image(systemName: "info.circle").help(text(job.status == "failed" ? "ci.job.allowedFailure" : "ci.allowed.failure")) }
                            CIStatusBadge(status: job.status)
                            CIWebButton(url: job.webURL)
                        }
                        if job.allowFailure, job.status == "failed" { Text(text("ci.job.allowedFailure")).foregroundStyle(.secondary) }
                    }
                }
                if !details.bridges.isEmpty { Text(text("ci.children")).mimicFont(.caption, weight: .semibold).foregroundStyle(.secondary) }
                ForEach(details.bridges) { bridge in
                    HStack {
                        Text(bridge.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        CIStatusBadge(status: bridge.downstreamPipeline?.status ?? bridge.status)
                        CIWebButton(url: bridge.downstreamPipeline?.webURL ?? bridge.webURL)
                    }
                }
                if let error = details.bridgeError { Text(text("ci.children.error") + " " + text(error.localizationKey)).foregroundStyle(.orange) }
                if details.jobs.isEmpty, details.bridges.isEmpty, details.bridgeError == nil { Text(text("ci.jobs.empty")).foregroundStyle(.secondary) }
            }
        }.mimicFont(.caption).padding(.leading, 10)
    }
}

struct CIWebButton: View {
    let url: URL
    var body: some View {
        Button { if self.url.scheme == "https" || self.url.scheme == "http" { NSWorkspace.shared.open(self.url) } } label: { Image(systemName: "arrow.up.right.square") }
            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(text("ci.open.browser"))
            .background(PanelControlRegion())
    }
}

/// Shared native form; the setup wizard adds a frame, grouped settings omit it.
struct CISettingsView: View {
    @ObservedObject var settings: CISettingsModel
    let hasCheckout: Bool
    var framed = true
    var body: some View {
        SettingsFormContainer(framed: self.framed) {
            CIConnectionForm(service: "GitLab", connected: self.settings.connection != nil,
                             checking: self.settings.checking, verified: self.settings.verified,
                             error: self.settings.error.map { text($0.localizationKey) },
                             unavailable: self.hasCheckout ? nil : text("settings.connection.checkout"),
                             check: self.settings.check, save: self.settings.save, disconnect: self.settings.disconnect,
                             identifier: "gitlab") {
                SettingsField(title: text("settings.field.server")) {
                    TextField("https://gitlab.example.com", text: self.$settings.address).accessibilityIdentifier("gitlab.address")
                }
                SettingsField(title: text("ci.project")) {
                    TextField("team/mobile", text: self.$settings.projectPath).accessibilityIdentifier("gitlab.project")
                }
                SettingsField(title: text("ci.token")) {
                    SecureField(text(self.settings.connection == nil ? "settings.token.placeholder" : "ci.token.replace"), text: self.$settings.enteredToken)
                        .accessibilityIdentifier("gitlab.token")
                }
                Text(text("ci.token.scope")).mimicFont(.caption).foregroundStyle(.secondary)
            } credential: {
                if let connection = self.settings.connection {
                    CICredentialAccessView(session: self.settings.credentialSession, id: connection.id, service: "GitLab", alwaysShow: true) {
                        await self.settings.requestCredentialAccess()
                    }
                }
            }
        }
    }
}

/// Compact actions retain their intrinsic labels and flow onto another line when necessary.
struct MimicActionLayout: Layout {
    private let spacing = MimicMetrics.medium

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        self.arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = self.arrangement(width: bounds.width, subviews: subviews)
        for (index, point) in arrangement.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + self.spacing; rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + self.spacing
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), points)
    }
}
