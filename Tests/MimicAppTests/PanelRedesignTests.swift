//
//  PanelRedesignTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

private func redesignPipeline(status: String = "success", sha: String = "fixture-sha", id: Int = 42) throws -> CIPipeline {
    let data = try JSONSerialization.data(withJSONObject: ["id": id, "status": status, "sha": sha, "ref": "fixture",
                                                         "web_url": "https://gitlab.example.invalid/pipelines/42"])
    return try JSONDecoder().decode(CIPipeline.self, from: data)
}

@MainActor
private struct RedesignCredentials: CICredentialStore {
    func token(for id: UUID, interaction: CICredentialInteraction = .silent) throws -> String { "fixture" }
    func save(_ token: String, for id: UUID) throws { }
    func remove(_ id: UUID) throws { }
}

private actor RedesignGitLab: GitLabService {
    private var responses: [Result<[CIPipeline], CIError>]
    private(set) var requests = 0
    init(_ responses: [Result<[CIPipeline], CIError>] = [.success([])]) { self.responses = responses }
    func currentUser(connection _: GitLabConnection, token _: String) async throws -> CIUser { CIUser(id: 7, username: "fixture", name: "Fixture") }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] { [] }
    func pipeline(connection _: GitLabConnection, id _: Int, token _: String) async throws -> CIPipeline { throw CIError.notFound }
    func pipelinePage(connection: GitLabConnection, username: String?, page _: Int, perPage _: Int, token: String) async throws -> CIPipelinePage {
        if username == nil { return CIPipelinePage(pipelines: []) }
        return CIPipelinePage(pipelines: try await self.pipelines(connection: connection, branch: "main", token: token))
    }

    func project(baseURL: URL, path: String, token: String) async throws -> CIProject { throw CIError.invalidConfiguration }
    func pipelines(connection: GitLabConnection, branch: String, token: String) async throws -> [CIPipeline] {
        self.requests += 1
        return try (self.responses.count > 1 ? self.responses.removeFirst() : self.responses[0]).get()
    }
    func details(connection: GitLabConnection, pipelineID: Int, token: String) async throws -> CIPipelineDetails { throw CIError.notFound }
}

@MainActor
private final class RedesignUsage: SimulatorUsageStore {
    var value = SimulatorUsage()
    func load() -> SimulatorUsage { self.value }
    func save(_ usage: SimulatorUsage) { self.value = usage }
}

@MainActor
private struct RedesignFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-redesign-" + UUID().uuidString)
    let suite = "Mimic-redesign-" + UUID().uuidString
    let defaults: UserDefaults
    let model: TaskCoordinator
    let project = ProjectContext(path: "/private/tmp/Mimic-redesign-fixture", branch: "fixture", commit: "fixture-sha")
    init(usage: RedesignUsage? = nil, client: RedesignGitLab = RedesignGitLab(), connected: Bool = false) throws {
        self.defaults = try #require(UserDefaults(suiteName: self.suite))
        let store = DefaultsCIConfigurationStore(defaults: self.defaults)
        if connected {
            let connection = GitLabConnection(baseURL: try #require(URL(string: "https://gitlab.example.invalid")), projectID: 42, projectPath: "fixture")
            var configuration = CIConfiguration()
            configuration.connections = [connection]; configuration.checkouts[self.project.path] = connection.id
            store.save(configuration)
        }
        let settings = CISettingsModel(credentials: RedesignCredentials(), store: store, client: client)
        self.model = TaskCoordinator(directory: self.directory, usageStore: usage, defaults: self.defaults, ciClient: client, ciSettings: settings)
        self.model.projects = [self.project]; self.model.selectedProjectPath = self.project.path
        settings.selectCheckout(self.project.path)
    }
    func cleanUp() {
        self.model.ci.setVisible(false)
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.directory)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct PanelRedesignTests {
    private func device(_ name: String, booted: Bool = true, runtime: String = "iOS 26.5") -> SimulatorDevice {
        SimulatorDevice(id: UUID(), name: name, runtime: runtime, state: booted ? "Booted" : "Shutdown")
    }

    @Test
    func footerResolvesRunningPreparationQueueAndOriginalCheckout() throws {
        let fixture = try RedesignFixture(); defer { fixture.cleanUp() }
        var running = TaskRecord(action: .format, project: fixture.project)
        running.status = .running; running.startedAt = Date().addingTimeInterval(-60)
        let queued = TaskRecord(action: .bootstrap, project: fixture.project)
        let resolve: ([TaskRecord], LaunchPreparationState, TaskRecord?) -> FooterActivity? = { records, launch, preparing in
            FooterActivity.resolve(records: records, launch: launch, preparing: preparing, checkout: "/other-checkout")
        }
        let active = try #require(resolve([queued, running], .checking(queued.id), queued))
        #expect(active.record.id == running.id && active.phase == .running && active.showsTimer && active.otherCheckout)
        #expect(active.help.contains(fixture.project.path))
        let phases: [(LaunchPreparationState, FooterActivity.Phase)] = [(.checking(queued.id), .checking), (.closingXcode(queued.id), .closingXcode), (.blockedByXcode(queued.id), .blocked)]
        for (launch, phase) in phases {
            let activity = try #require(resolve([queued], launch, nil))
            #expect(activity.record.id == queued.id && activity.phase == phase && !activity.showsTimer)
        }
        #expect(resolve([], .idle, queued)?.phase == .preparing)
        #expect(resolve([queued], .idle, nil)?.phase == .queued)
        #expect(resolve([], .idle, nil) == nil)
        running.startedAt = nil
        #expect(resolve([running], .idle, nil)?.showsTimer == false)
    }

    @Test
    func footerNavigationRevealsOriginalTaskThroughFiltersAndPreservesDrafts() throws {
        let fixture = try RedesignFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        var record = TaskRecord(action: .format, project: fixture.project); record.status = .running
        model.records = [record]; model.taskSearch = "hidden"; model.taskFilter = .failed
        model.generatorName = "ProfileHeader"; model.simulatorSearch = "iOS 26"
        model.openSettings(); model.openFooterActivity()
        #expect(model.expandedSection == .tasks && model.selectedTaskID == record.id)
        #expect(model.taskSearch.isEmpty && model.taskFilter == .all)
        #expect(model.terminalFocusTaskID == nil)
        #expect(model.generatorName == "ProfileHeader" && model.simulatorSearch == "iOS 26")
        model.records = []; model.taskSearch = "preserved"
        model.openFooterActivity()
        #expect(model.expandedSection == nil)
        model.openFooterActivity()
        #expect(model.expandedSection == .tasks && model.taskSearch == "preserved")
        model.toggleFooterCI()
        #expect(model.panelPage == .settings)
    }

    @Test
    func simulatorSelectionIsIsolatedByXcodeAndSurvivesRestart() throws {
        let usage = RedesignUsage()
        let first = self.device("iPhone A"), recent = self.device("iPhone B"), off = self.device("iPad", booted: false)
        usage.value.record(recent.id, developer: "/Xcode-A", at: Date())
        let fixture = try RedesignFixture(usage: usage); defer { fixture.cleanUp() }
        let model = fixture.model
        model.installSimulatorPreview([first, off, recent, first], developer: "/Xcode-A")
        #expect(model.selectedSimulator?.id == recent.id && model.bootedSimulators.count == 2)
        model.selectSimulator(first)
        #expect(model.selectedSimulator?.id == first.id)
        #expect(model.simulators.allSatisfy { $0.id != off.id || !$0.isBooted })
        #expect(model.records.isEmpty)
        model.installSimulatorPreview([first, recent], developer: "/Xcode-B")
        #expect(model.selectedSimulator?.id == first.id)
        model.selectSimulator(recent)
        model.installSimulatorPreview([first, recent], developer: "/Xcode-A")
        #expect(model.selectedSimulator?.id == first.id)
        let savedUsage = usage.value.dates
        // Empty project defaults avoid any automatic inspection of the real machine.
        let restored = TaskCoordinator(directory: fixture.directory, usageStore: usage, defaults: fixture.defaults)
        restored.installSimulatorPreview([first, recent], developer: "/Xcode-B")
        #expect(restored.selectedSimulator?.id == recent.id)
        restored.installSimulatorPreview([first, recent], developer: "/Xcode-A")
        #expect(restored.selectedSimulator?.id == first.id)
        #expect(usage.value.dates == savedUsage)
    }

    @Test
    func simulatorFallbackExcludesShutdownDeletedAndUnavailableSelections() throws {
        let fixture = try RedesignFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        let first = self.device("iPhone A", runtime: "iOS 18"), newest = self.device("iPhone B")
        model.installSimulatorPreview([first, newest])
        #expect(model.selectedSimulator?.id == newest.id)
        model.selectSimulator(first)
        let shutdown = SimulatorDevice(id: first.id, name: first.name, runtime: first.runtime, state: "Shutdown")
        model.installSimulatorPreview([shutdown, newest])
        #expect(model.selectedSimulator?.id == newest.id)
        model.selectSimulator(shutdown)
        #expect(model.selectedSimulatorIDs["/fixture/Xcode/Contents/Developer"] == first.id.uuidString)
        model.installSimulatorPreview([newest])
        #expect(model.selectedSimulator?.id == newest.id)
        model.installSimulatorPreview([shutdown])
        #expect(model.selectedSimulator == nil)
        model.installSimulatorPreview([])
        #expect(model.selectedSimulator == nil && model.orderedSimulators.isEmpty)
        let fallbackDefaults = try #require(UserDefaults(suiteName: fixture.suite + "-invalid"))
        defer { fallbackDefaults.removePersistentDomain(forName: fixture.suite + "-invalid") }
        fallbackDefaults.set(["/Xcode": "not-a-uuid"], forKey: "selectedSimulatorIDs")
        let malformed = TaskCoordinator(directory: fixture.directory, defaults: fallbackDefaults)
        malformed.installSimulatorPreview([first], developer: "/Xcode")
        #expect(malformed.selectedSimulator?.id == first.id)
    }

    @Test(arguments: ["success", "failed", "running", "manual", "canceled", "waiting_for_manual_approval"])
    func footerCIKeepsStatusAndRemoteIdentityVisible(_ status: String) throws {
        let pipeline = try redesignPipeline(status: status, sha: "remote-sha")
        let value = FooterCIStatus(connected: true, loading: false, error: nil, pipeline: pipeline, commit: "local-sha", loadedAt: Date(), branch: "fixture")
        #expect(value.otherCommit && !value.stale)
        #expect(value.help.contains("remote-s") && value.help.contains("#42"))
        #expect(!value.title.contains("ci.status."))
        #expect(value.symbol == FooterCIStatus.pipelineSymbol(status))
    }

    @Test
    func footerCIOtherBranchKeepsHealthyColorAndDisclosesIncompleteHistory() throws {
        let pipeline = try redesignPipeline(status: "success", sha: "remote-sha")
        let value = FooterCIStatus(connected: true, loading: false, error: nil, pipeline: pipeline, commit: "local-sha", loadedAt: Date(), branch: "other-branch", historyIncomplete: true)
        #expect(!value.otherCommit && value.color == .green)
        #expect(value.help.contains(text("ci.history.incomplete")))
    }

    @Test
    func footerCIDistinguishesDisconnectedLoadingEmptyErrorAndStale() throws {
        let pipeline = try redesignPipeline()
        let disconnected = FooterCIStatus(connected: false, loading: false, error: nil, pipeline: nil, commit: nil, loadedAt: nil)
        let loading = FooterCIStatus(connected: true, loading: true, error: nil, pipeline: nil, commit: "fixture-sha", loadedAt: nil)
        let empty = FooterCIStatus(connected: true, loading: false, error: nil, pipeline: nil, commit: "fixture-sha", loadedAt: nil)
        let error = FooterCIStatus(connected: true, loading: false, error: .network, pipeline: nil, commit: "fixture-sha", loadedAt: nil)
        let stale = FooterCIStatus(connected: true, loading: false, error: .authentication, pipeline: pipeline, commit: "fixture-sha", loadedAt: Date(), branch: "fixture")
        #expect(Set([disconnected.title, loading.title, empty.title, error.title, stale.title]).count == 5)
        #expect(stale.stale && !stale.otherCommit && stale.symbol == "exclamationmark.triangle")
        #expect(stale.help.contains(text("ci.error.authentication")))
        #expect(!error.stale && !error.otherCommit)
        let refreshing = FooterCIStatus(connected: true, loading: true, error: nil, pipeline: pipeline, commit: pipeline.sha, loadedAt: Date(), branch: "fixture")
        #expect(refreshing.loading && !refreshing.stale && !refreshing.otherCommit)
    }

    @Test
    func footerUsesExistingCIOwnerWithoutAdditionalRequests() async throws {
        let client = RedesignGitLab([.success([try redesignPipeline()]), .failure(.network)])
        let fixture = try RedesignFixture(client: client, connected: true); defer { fixture.cleanUp() }
        let state = fixture.model.ci
        let connection = try #require(fixture.model.ciSettings.connection)
        state.select(CIContext(project: fixture.project, connection: connection)); state.setVisible(true)
        try await self.waitUntil { !state.loading }
        let first = state.loadedAt
        state.refresh(manual: true); try await self.waitUntil { !state.loading }
        let value = FooterCIStatus(connected: true, loading: state.loading, error: state.error, pipeline: state.pipelines.first, commit: state.context?.commit, loadedAt: state.loadedAt, branch: state.context?.branch)
        #expect(value.stale && value.loadedAt == first)
        let host = NSHostingView(rootView: MimicFooter(model: fixture.model))
        host.layoutSubtreeIfNeeded()
        #expect(await client.requests == 2)
        fixture.model.taskSearch = "preserved"
        fixture.model.toggleFooterCI()
        #expect(fixture.model.expandedSection == .ci)
        fixture.model.toggleFooterCI()
        #expect(fixture.model.expandedSection == nil && fixture.model.taskSearch == "preserved")
        state.setVisible(false)
        #expect(await client.requests == 2)
    }

    /// Render real views at their shipped widths; all data and defaults are disposable.
    @Test
    func rendersHomeFooterAndBootstrapWithWorstCaseAndAccessibility() async throws {
        let fixture = try RedesignFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        let cardFixture = try RedesignFixture(); defer { cardFixture.cleanUp() }
        cardFixture.model.installBootstrapPreview()
        let output = URL(fileURLWithPath: "/private/tmp/MimicRedesignRenders-20261003")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dataset in ["demo", "worst", "empty", "many"] {
            model.installBootstrapPreview(configuration: true)
            model.records = []; model.expandedSection = nil
            model.readiness = [.bootstrap: [], .generation: [], .localization: [], .proto: [], .format: [], .simulatorBoot: ["fixture"]]
            let longName = "iPad Pro 13-inch Mobile Platform Infrastructure Development"
            let devices = dataset == "empty" ? [] : [self.device(dataset == "worst" ? longName : "iPhone 17 Pro"), self.device("iPad Air 11-inch", booted: false)]
            model.installSimulatorPreview(dataset == "many" ? devices + (0..<1000).map { self.device("iPad Development \($0 + 1)", booted: false) } : devices)
            if dataset == "worst" {
                let project = ProjectContext(path: "/private/tmp/MobilePlatformInfrastructureDevelopmentCheckout", branch: "feature/infrastructure/dependency-registry-bootstrap-diagnostics", commit: "fixture-sha")
                model.projects = [project]; model.selectedProjectPath = project.path
                var running = TaskRecord(action: .fullCleanup, project: fixture.project)
                running.status = .running; running.startedAt = Date().addingTimeInterval(-6000)
                model.records = [running]
            }
            if dataset == "empty" { model.projects = []; model.selectedProjectPath = "" }
            for mode in ["normal", "opaque", "contrast", "motion"] {
                for dark in [false, true] {
                    let appearance = MimicAppearancePreview(reduceTransparency: mode == "opaque", reduceMotion: mode == "motion", increasedContrast: mode == "contrast")
                    let name = dataset + "-" + mode + (dark ? "-dark" : "-light")
                    let panel = MimicPanel(model: model).environment(appearance).environment(\.colorScheme, dark ? .dark : .light).frame(width: 440, height: 660)
                    try await self.render(panel, size: NSSize(width: 440, height: 660), name: "panel-" + name, output: output)
                    if dataset == "worst", mode == "normal" {
                        try await self.render(panel.frame(height: 420), size: NSSize(width: 440, height: 420), name: "reduced-" + name, output: output)
                    }
                    let footer = NSHostingView(rootView: MimicFooter(model: model).environment(appearance))
                    #expect(abs(footer.fittingSize.height - 76) < 1)
                    for primary in [false, true] {
                        let control = NSHostingView(rootView: Button(text("bootstrap.run")) {}.buttonStyle(BootstrapControlStyle(primary: primary)).environment(appearance))
                        control.layoutSubtreeIfNeeded()
                        #expect(control.fittingSize.height >= 32 && control.fittingSize.height <= 34)
                    }
                    let card = QuickBootstrapView(model: cardFixture.model, showMimic: {}).environment(appearance).environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: card)
                    #expect(abs(host.fittingSize.width - 320) < 1)
                    try await self.render(card, size: host.fittingSize, name: "bootstrap-" + name, output: output)
                }
            }
        }
    }

    @Test
    func expandedCIFitsItsTopicWithMixedStatusesAndExternalActions() async throws {
        let statuses = ["success", "failed", "running", "manual", "waiting_for_manual_approval"]
        let pipelines = try statuses.enumerated().map { try redesignPipeline(status: $0.element, sha: "other-commit", id: 2811446 - $0.offset) }
        let fixture = try RedesignFixture(client: RedesignGitLab([.success(pipelines)]), connected: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let connection = try #require(model.ciSettings.connection)
        model.ci.select(CIContext(project: fixture.project, connection: connection))
        model.ci.setVisible(true)
        try await self.waitUntil { model.ci.pipelines.count == statuses.count }
        model.expandedSection = .ci
        let output = URL(fileURLWithPath: "/private/tmp/MimicTheme-20261005/ci")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for contrast in [false, true] {
            for dark in [false, true] {
                let view = Surface {
                    CISection(state: model.ci, settings: model.ciSettings, expanded: .constant(true))
                }.font(MimicMetrics.body).tint(.indigo)
                    .environment(MimicAppearancePreview(increasedContrast: contrast))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: 408)
                let host = NSHostingView(rootView: view)
                let size = host.fittingSize
                #expect(abs(size.width - 408) < 1)
                #expect(size.height > 200 && size.height < 950)
                try await self.render(view, size: size, name: "ci-\(contrast ? "contrast" : "normal")-\(dark ? "dark" : "light")", output: output)
            }
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(predicate())
    }

    private func render<V: View>(_ content: V, size: NSSize, name: String, output: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: name.hasSuffix("-dark") ? .darkAqua : .aqua)
        defer { window.close() }
        let host = NSHostingView(rootView: content)
        window.contentView = host; host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(2))
        #expect(host.fittingSize.width <= size.width + 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}
