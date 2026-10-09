//
//  SettingsPageTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor private final class SettingsCredentials: CICredentialStore {
    var values: [UUID: String] = [:]
    var denied = false
    func token(for id: UUID, interaction: CICredentialInteraction = .silent) throws -> String {
        if self.denied { throw CICredentialAccessError.accessRequired }
        guard let value = self.values[id] else { throw CICredentialAccessError.missing }
        return value
    }
    func save(_ token: String, for id: UUID) { self.values[id] = token }
    func remove(_ id: UUID) { self.values[id] = nil }
}

/// All requests terminate in memory; even the fixed Jenkins endpoint never reaches the network.
private actor SettingsHTTP: CIHTTPTransport {
    var forbidden = false
    private(set) var requests: [URLRequest] = []
    func reject(_ value: Bool) { self.forbidden = value }
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        self.requests.append(request)
        if self.forbidden { return CIHTTPResponse(data: Data(), status: 403) }
        let body: String
        if request.url?.path.hasSuffix("/whoAmI/api/json") == true {
            body = #"{"authenticated":true,"anonymous":false}"#
        } else if request.url?.host == "jenkins.example.com" {
            body = #"{"property":[{"parameterDefinitions":[{"name":"BRANCH","_class":"net.uaznia.lukanus.hudson.plugins.gitparameter.GitParameterDefinition","allValueItems":{"values":[{"value":"origin/feature/configuration"}],"errors":[]}},{"name":"TEST_PLAN","choices":["SMOKE","FUNCTIONAL","STATS","FULL"],"defaultParameterValue":{"value":"SMOKE"}}]}]}"#
        } else if request.url?.path.contains("/repository/branches/") == true {
            body = #"{"name":"feature/configuration"}"#
        } else if request.url?.path.hasSuffix("/repository/branches") == true {
            body = #"[{"name":"feature/configuration"}]"#
        } else if request.url?.path.hasSuffix("/user") == true {
            body = #"{"id":7,"username":"fixture-user","name":"Fixture User"}"#
        } else {
            body = #"{"id":272,"path_with_namespace":"team/mobile"}"#
        }
        return CIHTTPResponse(data: Data(body.utf8), status: 200)
    }
}

@MainActor private struct SettingsFixture {
    let suite = "SettingsPage-" + UUID().uuidString
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsPage-" + UUID().uuidString)
    let defaults: UserDefaults
    let model: TaskCoordinator
    let credentials = SettingsCredentials()
    let http = SettingsHTTP()
    init() throws {
        self.defaults = try #require(UserDefaults(suiteName: self.suite))
        let gitlab = GitLabClient(transport: self.http)
        let settings = CISettingsModel(credentials: self.credentials, store: DefaultsCIConfigurationStore(defaults: self.defaults), client: gitlab)
        let jenkins = JenkinsSettings(defaults: self.defaults, credentials: self.credentials, client: JenkinsClient(transport: self.http))
        self.model = TaskCoordinator(directory: self.directory, defaults: self.defaults, ciClient: gitlab, ciSettings: settings, jenkinsSettings: jenkins)
        let project = ProjectContext(path: "/private/tmp/SettingsPage-fixture", branch: "feature/configuration", commit: "fixture")
        self.model.projects = [project]; self.model.selectedProjectPath = project.path
        self.model.integration = MimicIntegration(model: self.model, defaults: self.defaults)
        settings.selectCheckout(project.path)
        settings.address = "https://gitlab.example.test"; settings.projectPath = "team/mobile"
        jenkins.address = "https://jenkins.example.com"
    }
    func cleanUp() {
        self.model.remoteTests.stop(); self.model.ci.setVisible(false)
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.directory)
    }
}

/// Uses the same retained native document and CI presentation hooks as the production panel.
private struct SettingsCILifetimeView: View {
    @ObservedObject var model: TaskCoordinator
    let launch: CILaunchModel
    var body: some View {
        ScrollView {
            CISection(state: self.model.ci, settings: self.model.ciSettings, launch: self.launch,
                      presented: self.model.panelPage == .home, expanded: .constant(true))
                .background(MimicDocumentVisibility(page: .home, visible: self.model.panelPage == .home))
        }.modifier(MimicPageInteraction(visible: self.model.panelPage == .home))
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct SettingsPageTests {
    // MARK: - Navigation

    @Test func backPreservesHomeAndCancelsBothDocumentsWithoutCancellingWork() throws {
        let f = try SettingsFixture(); defer { f.cleanUp() }
        let m = f.model
        var record = TaskRecord(action: .format, project: try #require(m.project)); record.status = .running
        m.records = [record]
        m.showHistory(id: record.id, focusTerminal: true, source: .keyboard)
        let staleHome = m.panelScrollRequest
        m.generatorName = "ProfileHeader"; m.taskSearch = "fixture"; m.branchSearch = "feature/"
        var releases = 0; m.releasePanelFocus = { releases += 1 }
        m.openSettings(group: .ci, source: .keyboard)
        #expect(m.panelPage == .settings && m.expandedSection == .tasks && m.selectedTaskID == record.id)
        #expect(!m.panelScroll.isActive(staleHome) && m.terminalFocusTaskID == nil)
        let staleSettings = m.settingsScroll.request
        #expect(m.settingsScroll.target == "settings.top" && m.settingsScroll.source == .keyboard)
        m.returnHome(source: .keyboard)
        #expect(m.panelPage == .home && m.expandedSection == .tasks)
        #expect(!m.settingsScroll.isActive(staleSettings) && m.panelScrollTarget.isEmpty)
        #expect(m.generatorName == "ProfileHeader" && m.taskSearch == "fixture" && m.branchSearch == "feature/")
        #expect(m.activeRecord?.id == record.id && releases == 2)
        m.toggleSettings(); m.panelVisibilityChanged(false)
        #expect(m.panelPage == .settings && m.settingsGroup == .ci && m.activeRecord?.id == record.id)
        m.toggleSettings(); #expect(m.panelPage == .home)
    }

    @Test func entryPointsRevealTheirDestinationEvenWhenThatHomeSectionWasRetained() throws {
        let f = try SettingsFixture(); defer { f.cleanUp() }
        let m = f.model
        m.revealSection(.tasks, source: .keyboard); m.openSettings()
        m.toggleHistory(source: .keyboard)
        #expect(m.panelPage == .home && m.expandedSection == .tasks)
        m.openSettings(); m.openTool(.bootstrap, source: .keyboard)
        #expect(m.panelPage == .home && m.expandedSection == nil && m.panelScrollTarget == "section.bootstrap")
        m.openSettings(); m.revealSection(.branches, source: .keyboard)
        #expect(m.panelPage == .home && m.expandedSection == .branches)
        m.toggleFooterCI()
        #expect(m.panelPage == .settings && m.settingsGroup == .ci)
        m.openSettings(group: .environment, source: .keyboard)
        #expect(m.settingsGroup == .environment && m.settingsScroll.target == "settings.top")
        m.toggleSettingsGroup(.aiIntegrations, source: .keyboard)
        #expect(m.settingsGroup == .aiIntegrations && m.settingsScroll.target == "settings.top")
        m.toggleSettingsGroup(.aiIntegrations, source: .keyboard)
        #expect(m.settingsGroup == .aiIntegrations)
        m.toggleSettings(); m.toggleSettings()
        #expect(m.settingsGroup == .aiIntegrations)
        let restarted = TaskCoordinator(directory: f.directory, defaults: f.defaults)
        #expect(restarted.panelPage == .home && restarted.expandedSection == nil && restarted.settingsGroup == .application)
    }

    @Test func codexAppearanceEntryPreservesCategoryDrafts() async throws {
        let f = try SettingsFixture(); defer { f.cleanUp() }
        let m = f.model
        m.ciSettings.enteredToken = "fixture-gitlab-draft"
        m.jenkinsSettings.enteredToken = "fixture-jenkins-draft"
        m.aiSettings.settings.codexModel = "fixture-model"
        var presentations = 0; m.showPanel = { presentations += 1 }
        for appearance in PanelAppearance.allCases {
            m.appearance.select(appearance)
            try await m.panelSetup("appearance", project: nil)
            #expect(m.panelPage == .settings && m.settingsGroup == .appearance)
            for group in SettingsGroup.allCases { m.openSettings(group: group, source: .keyboard) }
            m.returnHome(); m.openSettings()
            #expect(m.settingsGroup == .diagnostics)
            #expect(m.ciSettings.enteredToken == "fixture-gitlab-draft")
            #expect(m.jenkinsSettings.enteredToken == "fixture-jenkins-draft")
            #expect(m.aiSettings.settings.codexModel == "fixture-model")
        }
        #expect(presentations == 2 && f.credentials.values.isEmpty)
        #expect(await f.http.requests.isEmpty)
    }

    // MARK: - Shared CI lifecycle

    @Test(arguments: [false, true]) func connectionFormsKeepCheckSaveReplacementAndKeychainSemantics(jenkins: Bool) async throws {
        let f = try SettingsFixture(); defer { f.cleanUp() }
        let g = f.model.ciSettings, j = f.model.jenkinsSettings
        if jenkins { j.username = "fixture-user"; j.enteredToken = "fixture-token"; j.check() }
        else { g.enteredToken = "fixture-token"; g.check() }
        try await self.wait { !g.checking && !j.checking }
        #expect(jenkins ? j.verified : g.verified)
        #expect(jenkins ? j.connection == nil : g.connection == nil)
        if jenkins { j.save() } else { g.save() }
        let id = try #require(jenkins ? j.connection?.id : g.connection?.id)
        #expect(f.credentials.values[id] == "fixture-token")
        #expect((jenkins ? j.enteredToken : g.enteredToken).isEmpty)
        #expect(!(jenkins ? j.verified : g.verified))
        if jenkins { j.enteredToken = "replacement-token"; j.check() } else { g.enteredToken = "replacement-token"; g.check() }
        try await self.wait { !g.checking && !j.checking }
        #expect(jenkins ? j.verified : g.verified)
        if jenkins { j.username = "changed-user" } else { g.projectPath = "ios/changed" }
        #expect(!(jenkins ? j.verified : g.verified))
        if jenkins { j.save() } else { g.save() }
        #expect(f.credentials.values[id] == "fixture-token")
        if jenkins { j.check() } else { g.check() }
        try await self.wait { !g.checking && !j.checking }
        if jenkins { j.save() } else { g.save() }
        #expect(f.credentials.values[id] == "replacement-token")
        f.credentials.denied = true
        if jenkins { j.credentialSession.forget(id) } else { g.credentialSession.forget(id) }
        if jenkins { j.check() } else { g.check() }
        try await self.wait { !g.checking && !j.checking }
        #expect(jenkins ? j.error != nil : g.error != nil)
        #expect(!(jenkins ? j.verified : g.verified))
        f.credentials.denied = false
        await f.http.reject(true)
        if jenkins { j.enteredToken = "rejected-token"; j.check() } else { g.enteredToken = "rejected-token"; g.check() }
        try await self.wait { !g.checking && !j.checking }
        #expect(jenkins ? j.error != nil : g.error != nil)
        if jenkins { j.disconnect() } else { g.disconnect() }
        #expect(jenkins ? j.connection == nil : g.connection == nil)
        #expect(f.credentials.values[id] == nil)
        #expect(await f.http.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func providerPreferencesAndCLICheckStayIndependentFromPanelIntegration() async throws {
        let f = try SettingsFixture(); defer { f.cleanUp() }
        let m = f.model, integration = try #require(m.integration)
        m.aiSettings.settings.codexPath = "/nonexistent/settings-fixture-codex"
        m.aiSettings.settings.claudePath = "/nonexistent/settings-fixture-claude"
        m.aiSettings.settings.provider = .claude
        m.aiUsage.setPreference(.weekly, for: .codex)
        m.aiUsage.setPreference(.session, for: .claude)
        m.aiSettings.check(.codex)
        try await self.wait { m.aiSettings.checking == nil }
        #expect(m.aiSettings.errors[.codex] == .missingCLI)
        #expect(m.aiSettings.settings.provider == .claude)
        #expect(m.aiUsage.settings.preference(for: .codex) == .weekly)
        #expect(m.aiUsage.settings.preference(for: .claude) == .session)
        #expect(!integration.connecting && integration.connectionMessage.isEmpty && !m.analysis.isActive)
        let restarted = TaskCoordinator(directory: f.directory, defaults: f.defaults)
        #expect(restarted.aiSettings.settings.provider == .claude)
        #expect(restarted.aiUsage.settings.preference(for: .codex) == .weekly)
        #expect(await f.http.requests.isEmpty)
    }

    // MARK: - Native document and rendering acceptance

    @Test func retainedCIDocumentPausesRequestsAndPreservesTheLaunchDraft() async throws {
        let f = try SettingsFixture(); defer { f.cleanUp() }
        let m = f.model
        m.ciSettings.enteredToken = "fixture-token"; m.ciSettings.check()
        m.jenkinsSettings.address = "https://jenkins.example.com"; m.jenkinsSettings.username = "fixture-user"; m.jenkinsSettings.enteredToken = "fixture-token"; m.jenkinsSettings.check()
        try await self.wait { !m.ciSettings.checking && !m.jenkinsSettings.checking }
        m.ciSettings.save(); m.jenkinsSettings.save()
        let owner = ProfileRemoteCoordinator(directory: f.directory, jenkins: JenkinsClient(transport: f.http), gitlab: GitLabClient(transport: f.http), jenkinsToken: { _ in "fixture" }, gitlabToken: { _ in "fixture" })
        defer { owner.stop() }
        let launch = CILaunchModel(preferences: m.ciLaunchPreferences, settings: m.jenkinsSettings,
                                   gitlabSettings: m.ciSettings, coordinator: owner,
                                   snapshot: { try? Profile11Fixture.snapshot(directory: f.directory, legacyCI: true) },
                                   submitProfile: { _, _, _, _, _, _ in throw ProfileError.action },
                                   client: JenkinsClient(transport: f.http), gitlab: GitLabClient(transport: f.http),
                                   project: { m.project }, validate: { _ in })
        defer { launch.setVisible(false) }
        let window = self.window(); defer { window.close() }
        let host = NSHostingView(rootView: SettingsCILifetimeView(model: m, launch: launch).frame(width: 440, height: 420))
        window.contentView = host; try await self.layout(host)
        try await self.wait { launch.contracts[.uiTests] != nil }
        launch.open(.uiTests); try await self.wait { launch.branch == "feature/configuration" }
        launch.plan = .functional
        m.openSettings(source: .keyboard); try await self.layout(host)
        #expect(!m.ci.feedPresented && launch.selected == .uiTests && launch.plan == .functional)
        #expect(self.scroll(in: host, id: "page.home")?.isHidden == true)
        let count = await f.http.requests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(await f.http.requests.count == count)
        m.returnHome(source: .keyboard); try await self.layout(host)
        #expect(m.ci.feedPresented && launch.selected == .uiTests && launch.plan == .functional)
        #expect(launch.branch == "feature/configuration")
        launch.setVisible(false, preserveDraft: true)
        launch.setVisible(false)
        #expect(launch.selected == nil)
    }

    @Test(arguments: PanelAppearance.allCases)
    func nativeDocumentsRetainSeparateScrollOffsetsAndExcludeHiddenControls(appearance: PanelAppearance) async throws {
        let f = try SettingsFixture(); defer { f.cleanUp() }
        let m = f.model
        m.appearance.select(appearance)
        m.activeProfile = try Profile11Fixture.snapshot(directory: f.directory)
        m.motionSettings.reduceMotionOverride = true
        m.revealSection(.tasks, source: .keyboard)
        let window = self.window()
        defer { window.close() }
        let host = NSHostingView(rootView: MimicPanel(model: m).frame(width: m.appearance.selection.panelWidth, height: 420).modifier(MimicAppearanceRoot(store: m.appearance)))
        window.contentView = host
        try await self.layout(host)
        let home = try #require(self.scroll(in: host, id: "page.home"))
        let settings = try #require(self.scroll(in: host, id: "page.settings"))
        // Legacy style models “Always show scroll bars”; hidden indicators must not reserve a gutter.
        home.scrollerStyle = .legacy; settings.scrollerStyle = .legacy
        home.tile(); settings.tile()
        #expect(!home.hasVerticalScroller && !settings.hasVerticalScroller)
        #expect(!home.isHidden && settings.isHidden)
        #expect(home.superview?.isHiddenOrHasHiddenAncestor == false)
        #expect(settings.superview?.isHiddenOrHasHiddenAncestor == true)
        home.contentView.scroll(to: NSPoint(x: 0, y: 90)); home.reflectScrolledClipView(home.contentView)
        let homeOffset = home.contentView.bounds.origin
        m.openSettings(group: .aiIntegrations, source: .keyboard)
        try await self.layout(host)
        #expect(home.isHidden && !settings.isHidden)
        #expect(home.superview?.isHiddenOrHasHiddenAncestor == true)
        #expect(settings.superview?.isHiddenOrHasHiddenAncestor == false)
        settings.contentView.scroll(to: NSPoint(x: 0, y: 160)); settings.reflectScrolledClipView(settings.contentView)
        let settingsOffset = settings.contentView.bounds.origin
        m.returnHome(source: .keyboard); try await self.layout(host)
        #expect(!home.isHidden && settings.isHidden && home.contentView.bounds.origin == homeOffset)
        m.openSettings(source: .keyboard); try await self.layout(host)
        #expect(settings.contentView.bounds.origin == settingsOffset)
        #expect(home === self.scroll(in: host, id: "page.home") && settings === self.scroll(in: host, id: "page.settings"))
        m.motionSettings.reduceMotionOverride = false
        m.revealSection(.tool(.format), source: .pointer); try await self.layout(host)
        m.openSettings(source: .keyboard); try await self.layout(host)
        let frozen = home.contentView.bounds.origin
        try await Task.sleep(for: .milliseconds(240))
        #expect(home.contentView.bounds.origin == frozen && m.panelScrollTarget.isEmpty)
    }

    @Test func groupedPageAndWizardFormsRenderAtBoundedWidthsWithWorstCaseData() async throws {
        let f = try SettingsFixture(); defer { f.cleanUp() }
        let m = f.model
        m.ciSettings.address = "https://gitlab.mobile-platform-infrastructure.example.test"
        m.ciSettings.projectPath = "mobile-platform/infrastructure/ios-application-development"
        m.jenkinsSettings.username = "bartholomew.fitzgerald-platform-infrastructure"
        m.aiSettings.settings.codexPath = "/Applications/Developer Tools/Codex.app/Contents/Resources/bin/codex"
        m.aiSettings.settings.claudePath = "/Users/fixture/Library/Application Support/Developer Tools/Claude/claude"
        m.diagnostic = "Не найден инструмент в /Applications/Developer Tools/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        m.motionSettings.reduceMotionOverride = true
        let output = URL(fileURLWithPath: "/private/tmp/MimicSettings-20261008")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for group in SettingsGroup.allCases {
            m.openSettings(group: group, source: .keyboard)
            for width in [CGFloat(440), 520, 560] {
                for dark in [false, true] {
                    for scale in [CGFloat(1), 1.4] {
                        let appearance: PanelAppearance = width == 520 ? .legacy : .tileGrid
                        let view = SettingsDocument(model: m).frame(width: width, height: 720)
                            .environment(\.mimicPanelAppearance, appearance)
                            .environment(\.mimicTextScale, scale)
                            .environment(MimicAppearancePreview(reduceMotion: true, increasedContrast: false))
                            .environment(\.colorScheme, dark ? .dark : .light)
                        try await self.render(view, size: NSSize(width: width, height: 720), dark: dark,
                                              name: group.rawValue + "-\(Int(width))-\(dark)-\(scale)", output: output)
                    }
                }
            }
        }
        // Full documents expose below-the-fold provider and connection controls for visual review.
        for group in [SettingsGroup.aiIntegrations, .ci] {
            m.openSettings(group: group, source: .keyboard)
            let content = SettingsContent(model: m).frame(width: 408).font(MimicMetrics.body)
                .environment(\.mimicMotionSettings, m.motionSettings)
            let measure = NSHostingView(rootView: content); measure.layoutSubtreeIfNeeded()
            try await self.render(content, size: NSSize(width: 408, height: measure.fittingSize.height), dark: false,
                                  name: group.rawValue + "-document", output: output)
        }
        for width in [320.0, 408.0] {
            for dark in [false, true] {
                let forms = VStack(alignment: .leading, spacing: 12) {
                    CISettingsView(settings: m.ciSettings, hasCheckout: false)
                    JenkinsSettingsView(settings: m.jenkinsSettings)
                }.frame(width: width).font(MimicMetrics.body).controlSize(.small)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let measure = NSHostingView(rootView: forms); measure.layoutSubtreeIfNeeded()
                let size = measure.fittingSize
                #expect(size.width <= width + 1 && size.height > 400)
                try await self.render(forms, size: NSSize(width: width, height: size.height), dark: dark,
                                      name: "wizard-\(Int(width))-\(dark)", output: output)
            }
        }
        m.projects = []; m.selectedProjectPath = ""
        m.openSettings(group: .ci, source: .keyboard)
        try await self.render(SettingsDocument(model: m).frame(width: 440, height: 420),
                              size: NSSize(width: 440, height: 420), dark: false, name: "empty-project", output: output)
        #expect(m.aiUsage.refreshing.isEmpty && m.records.isEmpty)
        #expect(await f.http.requests.isEmpty)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func layout(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
    }
    private func scroll(in view: NSView, id: String) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.identifier?.rawValue == id { return scroll }
        return view.subviews.lazy.compactMap { self.scroll(in: $0, id: id) }.first
    }
    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, name: String, output: URL) async throws {
        let window = self.window(); defer { window.close() }
        window.setContentSize(size); window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view); window.contentView = host
        host.frame = NSRect(origin: .zero, size: size); try await self.layout(host)
        #expect(host.fittingSize.width <= size.width + 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}
