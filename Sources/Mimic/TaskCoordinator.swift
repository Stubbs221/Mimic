//
//  TaskCoordinator.swift
//  Mimic
//
//  Created by Василий Маслов on 01.10.2026.
import AppKit
import Combine
import Foundation
import MimicCore
import UniformTypeIdentifiers

func text(_ key: String) -> String { NSLocalizedString(key, bundle: MimicResources.bundle, comment: "") }

/// The single owner of queued jobs and PTY sessions; view lifetime never controls execution.
@MainActor
final class TaskCoordinator: ObservableObject {
    @Published
    var projects: [ProjectContext] = []
    @Published var activeProfile: ProfileSnapshot?
    @Published private(set) var importingProfile = false
    @Published var profileProgress: [UUID: String] = [:]
    @Published var awaitingInput: Set<UUID> = []
    @Published var profilePreviews: [String: ProfilePreview] = [:]
    private let profileStore: ProfileStore
    private var sanitizedLogPending: [UUID: Data] = [:]
    private var sanitizedLogDropping: Set<UUID> = []
    private var pipelineCommands: [UUID: [CommandSpec]] = [:]
    @Published
    var selectedProjectPath = "" {
        didSet { if oldValue != self.selectedProjectPath { self.resetTaskHistory() } }
    }
    @Published
    var records: [TaskRecord] = []
    @Published
    var selectedTaskID: UUID?
    /// Transient UI state is independent of execution and persisted history.
    @Published
    var expandedAnalysisIDs: Set<UUID> = []
    @Published
    private(set) var analysisFocusRequest = UUID()
    private(set) var analysisEditorFocusTaskID: UUID?
    @Published
    var diagnostic = ""
    @Published
    var message = ""
    @Published
    var bootstrapOptions = BootstrapOptions.standard()
    @Published
    var unreadFailure = false
    @Published
    var launchState = LaunchPreparationState.idle
    @Published
    private(set) var requestingBootstrap = false
    @Published
    var bootstrapProgress = BootstrapProgress()
    private(set) var bootstrapProgressID: UUID?
    @Published
    private(set) var quickBootstrapActivity: QuickBootstrapActivity?
    @Published
    var expandedSection: PanelSection? {
        didSet { if self.expandedSection == .tasks, oldValue != .tasks { self.resetTaskHistory() } }
    }
    @Published
    private(set) var panelPage = PanelPage.home
    @Published
    private(set) var settingsGroup: SettingsGroup? = .application
    @Published
    var settingsDiagnosticsExpanded = false
    let settingsScroll = MimicPanelScroll()
    let motionSettings = MimicMotionSettings()
    private(set) var navigationSource = MimicMotionSource.automatic
    let panelScroll = MimicPanelScroll()
    let panelLayout: PanelLayoutController
    var scrollSource: MimicMotionSource { panelScroll.source }
    @Published
    var branchSearch = ""
    @Published
    var simulatorSearch = ""
    @Published
    var taskSearch = "" {
        didSet { if oldValue != self.taskSearch { self.resetTaskHistory() } }
    }
    @Published
    var taskFilter = TaskHistoryFilter.all {
        didSet { if oldValue != self.taskFilter { self.resetTaskHistory() } }
    }
    /// One shared window for local tasks and builds; never persisted with execution history.
    @Published private(set) var taskHistoryLimit = 2
    var panelScrollRequest: UUID { panelScroll.request }
    var panelScrollTarget: String { panelScroll.target }
    @Published
    private(set) var terminalFocusRequest = UUID()
    private(set) var terminalFocusTaskID: UUID?
    @Published
    private(set) var switchingBranch = false
    @Published
    var localBranches: [LocalBranch] = []
    @Published
    var loadingBranches = false
    @Published
    var branchError = ""
    @Published
    private(set) var hasGitOperation = false
    @Published
    var readiness: [MimicAction: [String]] = [:]
    @Published
    var checking = false
    @Published
    var gitSummary: GitSummary?
    @Published
    var simulators: [SimulatorDevice] = []
    @Published
    var loadingSimulators = false
    @Published
    var simulatorError = ""
    @Published
    private(set) var simulatorDeveloper = ""
    @Published
    private(set) var simulatorUsage = SimulatorUsage()
    @Published
    private(set) var selectedSimulatorIDs: [String: String] = [:]
    @Published
    var generatorKind: GeneratorKind = .ui {
        didSet {
            guard oldValue != generatorKind else { return }
            generatorDraftNames[oldValue] = generatorName
            generatorName = generatorDraftNames[generatorKind] ?? ""
            invalidateGeneration()
        }
    }
    private var generatorDraftNames: [GeneratorKind: String] = [:]
    @Published
    var generatorName = "" { didSet { if oldValue != self.generatorName { self.invalidateGeneration() } } }
    @Published
    var generationPlan: GenerationPlan?
    @Published
    var generationError = ""
    @Published
    var planningGeneration = false
    private var generationRevision = UUID()
    private var previewProjectPath: String?
    private var readinessRevision = UUID()
    private var projectRevision = UUID()
    private var simulatorRevision = UUID()
    private let inspectBootstrapAdmission: @Sendable (ProjectContext, BootstrapOptions) async -> BootstrapAdmissionResult
    private let launchPreparation: LaunchPreparation
    private let taskHostURL: URL
    let profileRemote: ProfileRemoteCoordinator
    let builds: BuildCoordinator
    let simulatorScreen: SimulatorCoordinator
    private let history: HistoryStore
    private let defaults: UserDefaults
    private let branchService: any GitBranchService
    private let usageStore: any SimulatorUsageStore
    private let checkoutGate = CheckoutMutationGate()
    private var branchRevision = UUID()
    private var branchListRevision = UUID()
    let ciSettings: CISettingsModel
    let jenkinsSettings: JenkinsSettings
    let ciLaunchPreferences: CILaunchPreferences
    lazy var ciLaunch = CILaunchModel(preferences: self.ciLaunchPreferences, settings: self.jenkinsSettings, gitlabSettings: self.ciSettings, coordinator: self.profileRemote, snapshot: { [weak self] in self?.activeProfile },
        submitProfile: { [weak self] snapshot, action, parameters, requestID, contract, project in
            guard let self else { throw ProfileError.revision }
            return try await self.submitRemoteProfile(snapshot: snapshot, action: action, parameters: parameters, requestID: requestID, reviewed: contract, expected: project)
        }, client: self.jenkinsSettings.authenticatedClient, gitlab: self.ciSettings.authenticatedClient,
        project: { [weak self] in self?.project }, validate: { [weak self] project in
            guard let self, self.project == project, !self.switchingBranch, !self.stoppingForExit else { throw CIError.invalidConfiguration }
            let checked = try await Task.detached { try EnvironmentInspector.project(path: project.path, developerDirectory: project.developerDirectory, appleTarget: project.appleTarget) }.value
            guard checked == project, self.project == project else { throw CIError.invalidConfiguration }
        })
    let remoteTests: RemoteTestCoordinator
    @Published var integration: MimicIntegration?
    private let ciFallback: CIState
    let ciMonitor: CIActivityMonitor
    var ci: CIState { self.ciMonitor.desktopState ?? self.ciFallback }
    @Published private(set) var ciInspection: CICompactSummary?
    var ciPresentedState: CIState { self.ciInspection.flatMap { self.ciMonitor.state(for: $0) } ?? self.ci }
    private var panelVisible = false
    let analysis: AnalysisCoordinator
    let aiSettings: AISettingsModel
    let appIconSettings: AppIconSettings
    let aiUsage: AIUsageCoordinator
    private let diagnostics = DiagnosticMemory()
    private var session: PTYSession?
    private var log: BoundedLog?
    private var buffers: [UUID: Data] = [:]
    private var truncatedBuffers: Set<UUID> = []
    private var simulatorLaunchDevelopers: [UUID: String] = [:]
    private var terminalSubscribers: [UUID: (UUID, Data) -> Void] = [:]
    private var bootstrapTerminals: [UUID: BootstrapTerminalSession] = [:]
    /// Independent views and encrypted channels receive the same ordered bytes.
    var terminalOutput: ((UUID, Data) -> Void)? {
        guard !self.terminalSubscribers.isEmpty else { return nil }
        return { [weak self] id, bytes in
            guard let self else { return }
            for subscriber in Array(self.terminalSubscribers.values) { subscriber(id, bytes) }
        }
    }
    var showSetup: (() -> Void)?
    var showInterfaceMap: (() -> Void)?
    var releasePanelFocus: (() -> Void)?
    var showPanel: (() -> Void)?
    var showQuickActivity: (() -> Void)?
    var stateChanged: (() -> Void)?
    var afterStopped: (() -> Void)?
    private var stoppingForExit = false
    private var subscriptions = Set<AnyCancellable>()
    private var stateChangeQueued = false

    init(directory: URL? = nil, helperURL: URL? = nil, buildCoordinator: BuildCoordinator? = nil, simulatorCoordinator: SimulatorCoordinator? = nil, xcodeApplications: any XcodeApplicationService = SystemXcodeApplications(), branchService: any GitBranchService = LocalGitBranchService(), usageStore: (any SimulatorUsageStore)? = nil, defaults: UserDefaults = .standard, ciClient: (any GitLabService)? = nil, ciSettings: CISettingsModel? = nil, jenkinsSettings: JenkinsSettings? = nil, analysis: AnalysisCoordinator? = nil, inspectBootstrapAdmission: @escaping @Sendable (ProjectContext, BootstrapOptions) async -> BootstrapAdmissionResult = { await BootstrapAdmissionResult.inspect(project: $0, options: $1) }) {
        self.inspectBootstrapAdmission = inspectBootstrapAdmission
        self.launchPreparation = LaunchPreparation(applications: xcodeApplications)
        self.defaults = defaults; self.branchService = branchService
        self.panelLayout = PanelLayoutController(defaults: defaults)
        self.appIconSettings = AppIconSettings(defaults: defaults)
        self.usageStore = usageStore ?? DefaultsSimulatorUsageStore(defaults: defaults)
        self.simulatorUsage = self.usageStore.load()
        self.selectedSimulatorIDs = defaults.dictionary(forKey: "selectedSimulatorIDs") as? [String: String] ?? [:]
        let settings = ciSettings ?? CISettingsModel(store: DefaultsCIConfigurationStore(defaults: defaults), client: ciClient)
        self.ciSettings = settings
        self.ciFallback = CIState(client: ciClient ?? settings.client, trackingStore: DefaultsCITrackingStore(defaults: defaults)) { try settings.token(for: $0) }
        self.ciMonitor = CIActivityMonitor { _ in
            CIState(client: ciClient ?? settings.authenticatedClient, trackingStore: DefaultsCITrackingStore(defaults: defaults)) { try settings.token(for: $0) }
        }
        self.taskHostURL = helperURL ?? Self.resolveHelper()
        let helper = self.taskHostURL
        let aiSettings = AISettingsModel(defaults: defaults, helper: helper)
        self.aiSettings = aiSettings
        let locations = AIUsageLocations(), scanner = AIUsageActivityScanner()
        self.aiUsage = AIUsageCoordinator(defaults: defaults, fallback: aiSettings.settings.provider, adapters: [
            CodexUsageAdapter(executable: {
                if let configured = AIProviderAdapters.resolve(provider: .codex, configuredPath: aiSettings.settings.codexPath) { return configured }
                guard aiSettings.settings.codexPath.isEmpty, let app = MimicPluginInstaller.findCodex() else { return nil }
                return ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex", "Contents/Resources/codex-cli"].map { app.appendingPathComponent($0).path }.first { FileManager.default.isExecutableFile(atPath: $0) && !URL(fileURLWithPath: $0).hasDirectoryPath && (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            }, home: locations.codex),
            ClaudeUsageAdapter(credentials: NativeClaudeUsageCredentials(locations: locations))
        ], scanUsage: { await scanner.scanUsage() })
        self.analysis = analysis ?? AnalysisCoordinator(makeRunner: { AIProcessRunner(helper: helper) }, makeProbeRunner: { AIProcessRunner(helper: helper, timeLimit: 8) })
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mimic")
        self.history = HistoryStore(directory: directory)
        self.profileStore = ProfileStore(directory: directory.appendingPathComponent("Profiles"))
        self.activeProfile = try? self.profileStore.active()
        self.builds = buildCoordinator ?? BuildCoordinator(directory: directory, helper: helper, defaults: defaults)
        self.simulatorScreen = simulatorCoordinator ?? SimulatorCoordinator(directory: directory)
        let jenkinsSettings = jenkinsSettings ?? JenkinsSettings(defaults: defaults)
        self.jenkinsSettings = jenkinsSettings
        self.ciLaunchPreferences = CILaunchPreferences(defaults: defaults)
        self.profileRemote = ProfileRemoteCoordinator(directory: directory, jenkins: jenkinsSettings.authenticatedClient, gitlab: settings.authenticatedClient, jenkinsToken: { try jenkinsSettings.token(for: $0) }, gitlabToken: { try settings.token(for: $0) })
        self.remoteTests = RemoteTestCoordinator(directory: directory, jenkins: jenkinsSettings.authenticatedClient, gitlab: settings.authenticatedClient, jenkinsToken: { try jenkinsSettings.token(for: $0) }, gitlabToken: { try settings.token(for: $0) })
        do { self.records = try self.history.load(); try self.history.save(self.records) } catch { self.message = text("history.error") + ": " + error.localizedDescription }
        if let data = defaults.data(forKey: "projects"), let saved = try? JSONDecoder().decode([ProjectContext].self, from: data) { self.projects = saved }
        self.selectedProjectPath = defaults.string(forKey: "selectedProject") ?? self.projects.first?.path ?? ""
        self.launchPreparation.onStateChange = { [weak self] state in self?.launchState = state }
        settings.onConnectionChange = { [weak self] in
            guard let self else { return }
            self.ciLaunch.contextChanged()
            let previous = self.ci.context
            self.updateCIContext()
            self.profileRemote.stop(); self.profileRemote.resume()
            self.ciMonitor.credentialsChanged()
            if self.ciMonitor.desktopState == nil, self.ci.context == previous { self.ci.credentialsChanged() }
        }
        objectWillChange.sink { [weak self] in
            guard let self, !self.stateChangeQueued else { return }
            self.stateChangeQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateChangeQueued = false; self.stateChanged?()
            }
        }.store(in: &self.subscriptions)
        if !self.projects.isEmpty { self.refresh() }
        self.updateCIContext()
        self.ciMonitor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.analysis.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.aiSettings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.aiUsage.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.analysis.onInferenceStarted = { [weak self] provider, date in self?.aiUsage.record(AIUsageActivity(provider: provider, date: date)) }
        self.aiSettings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.aiUsage.setFallback(self.aiSettings.settings.provider)
            }
        }.store(in: &self.subscriptions)
        self.analysis.onIdle = { [weak self] in
            guard let self else { return }
            self.analysis.retain(ids: Set(self.records.map(\.id)))
            self.analysis.retainBootstrap(ids: self.diagnostics.ids); self.finishExitIfReady()
        }
        jenkinsSettings.onChange = { [weak self] in
            guard let self else { return }
            self.ciLaunch.contextChanged()
            self.updateProfileCIFeed()
            self.profileRemote.stop(); self.profileRemote.resume()
        }
        self.profileRemote.$runs.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updateProfileCIFeed() }
        }.store(in: &self.subscriptions)
        self.profileRemote.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.applyProfileServices()
        self.profileRemote.resume()
        self.remoteTests.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.jenkinsSettings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.builds.currentProject = { [weak self] in self?.project }
        self.builds.currentProfile = { [weak self] in self?.activeProfile }
        self.builds.acceptsProject = { [weak self] in self?.projects.contains($0) == true }
        self.builds.mayAdmit = { [weak self] in self.map { !$0.stoppingForExit && !$0.switchingBranch && !$0.hasGitOperation } ?? false }
        self.builds.schedule = { [weak self] in self?.startNext(); self?.finishExitIfReady() }
        self.builds.showResult = { [weak self] in self?.showBuildResult($0) }
        self.builds.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.builds.xcode.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.simulatorScreen.currentProject = { [weak self] in self?.project }
        self.simulatorScreen.currentProfile = { [weak self] in self?.activeProfile }
        self.simulatorScreen.acceptsProject = { [weak self] in self?.projects.contains($0) == true }
        self.simulatorScreen.mayAdmit = { [weak self] in self.map { !$0.stoppingForExit && !$0.switchingBranch && !$0.hasGitOperation } ?? false }
        self.simulatorScreen.schedule = { [weak self] in self?.startNext(); self?.finishExitIfReady() }
        self.simulatorScreen.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &self.subscriptions)
        self.aiSettings.onIdle = { [weak self] in self?.finishExitIfReady() }
    }

    var project: ProjectContext? { self.projects.first { $0.path == self.selectedProjectPath } }
    /// Refreshes only Git identity for MCP polling, without probing tools or starting project commands.
    func refreshMCPContext() async {
        guard let current = self.project, !self.switchingBranch, !self.hasGitOperation else { return }
        guard let checked = try? await Task.detached(operation: { try EnvironmentInspector.project(path: current.path, developerDirectory: current.developerDirectory, appleTarget: current.appleTarget) }).value,
              self.project == current, !self.switchingBranch, checked != current,
              let index = self.projects.firstIndex(where: { $0.path == current.path }) else { return }
        self.projects[index] = checked; self.profilePreviews = [:]; self.saveProjects(); self.updateCIContext()
    }

    var activeID: UUID? { self.records.first { $0.status == .running }?.id }
    var preparing: Bool { self.launchState.holdsQueue }
    var busy: Bool { self.activeID != nil || self.preparing || self.builds.busy || self.simulatorScreen.busy }
    /// Development replacement waits for admissions, queued work and simulator ownership; it never cancels them.
    var canQuitForDevelopmentUpdate: Bool { self.developmentUpdateBlockers.isEmpty }
    /// Only fixed lifecycle labels are exposed to the development installer, never task contents.
    var developmentUpdateBlockers: [String] {
        var blockers: [String] = []
        if self.stoppingForExit { blockers.append("shutdown") }
        if self.busy || self.pendingCount > 0 || self.session != nil { blockers.append("tasks") }
        if self.requestingBootstrap || self.checkoutGate.admissions != 0 { blockers.append("admission") }
        // An external checkout's merge/rebase marker is not work owned by Mimic.
        if self.switchingBranch { blockers.append("git") }
        if self.builds.hasPending || self.builds.admittingCount != 0 { blockers.append("builds") }
        if self.simulatorScreen.hasPending || !self.simulatorScreen.canExit { blockers.append("simulator") }
        if self.analysis.isActive || self.aiSettings.checking != nil { blockers.append("ai") }
        // Submitted CI jobs live on the server; restart restores their observers without another POST.
        if self.ciLaunch.submitting { blockers.append("ci") }
        return blockers
    }
    var canSwitchBranch: Bool {
        !self.builds.hasPending && !self.simulatorScreen.hasPending && self.gitSummary.map { $0.changed == 0 && $0.untracked == 0 } == true && !self.hasGitOperation && !self.checking && self.checkoutGate.canSwitch(records: self.records, preparing: self.preparing)
    }

    var orderedSimulators: [SimulatorDevice] {
        self.simulatorUsage.recent(self.simulators, developer: self.simulatorDeveloper, limit: self.simulators.count)
    }
    var bootedSimulators: [SimulatorDevice] { self.orderedSimulators.filter(\.isBooted) }
    var selectedSimulator: SimulatorDevice? {
        let booted = self.bootedSimulators
        let selected = self.selectedSimulatorIDs[self.simulatorDeveloper]
        return booted.first { $0.id.uuidString == selected } ?? booted.first
    }

    /// Selecting a device changes presentation only; it never starts or shuts down a device.
    func selectSimulator(_ device: SimulatorDevice) {
        guard !self.simulatorDeveloper.isEmpty, self.simulators.contains(where: { $0.id == device.id && $0.isBooted }) else { return }
        self.rememberSimulator(device.id, developer: self.simulatorDeveloper)
    }

    private func rememberSimulator(_ id: UUID, developer: String) {
        guard !developer.isEmpty else { return }
        self.selectedSimulatorIDs[developer] = id.uuidString
        self.defaults.set(self.selectedSimulatorIDs, forKey: "selectedSimulatorIDs")
    }
    var bootstrapStage: String? { self.bootstrapProgress.stage.map { text("stage." + $0.rawValue) } }
    var bootstrapRecord: TaskRecord? {
        if let id = launchState.taskID, let record = records.first(where: { $0.id == id && $0.action == .bootstrap }) { return record }
        if let live = records.first(where: { $0.action == .bootstrap && ($0.status == .running || $0.status == .queued) }) { return live }
        return self.records.last { $0.action == .bootstrap && $0.project.path == self.selectedProjectPath }
    }

    /// Active tasks retain their original options; new launches use the script defaults.
    var bootstrapDisplayedOptions: BootstrapOptions {
        if self.requestingBootstrap, let activity = self.quickBootstrapActivity { return activity.request.options }
        if let record = self.bootstrapRecord, record.status == .queued || record.status == .running { return record.options }
        return self.bootstrapOptions
    }

    var bootstrapDisplayedProject: ProjectContext? {
        if self.requestingBootstrap, let activity = self.quickBootstrapActivity { return activity.request.project }
        if let record = self.bootstrapRecord, record.status == .queued || record.status == .running { return record.project }
        return self.project
    }

    var bootstrapLocked: Bool { self.requestingBootstrap || (self.bootstrapRecord.map { $0.status == .running || $0.status == .queued } ?? false) }
    var bootstrapIsBlocked: Bool {
        if case .blockedByXcode = self.launchState { return true }
        return false
    }

    var canOpenXcode: Bool {
        self.activeRecord?.requiresXcodeQuit != true && self.launchState.taskID.flatMap { id in self.records.first { $0.id == id } }?.requiresXcodeQuit != true
    }

    func selectBootstrapPlatform(_ platform: BootstrapPlatform) {
        guard !self.bootstrapLocked, !self.switchingBranch else { return }
        self.bootstrapOptions = BootstrapOptions.standard(platform: platform)
    }

    func retryBootstrap(id: UUID) { self.launchPreparation.retry(id: id) }
    func activateBlockingXcode() { self.launchPreparation.activateXcode() }
    var pendingCount: Int { self.records.filter { $0.status == .queued }.count }
    var selectedRecord: TaskRecord? { self.records.first { $0.id == self.selectedTaskID } }
    var helper: URL { self.taskHostURL }
    private static func resolveHelper() -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TaskHost")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("TaskHost")
    }

    var adapter: URL { URL(fileURLWithPath: "/nonexistent/mimic-profile-adapter") }
    var summary: ActivitySummary { ActivitySummary(records: self.records, path: self.selectedProjectPath) }
    var activeRecord: TaskRecord? { self.records.first { $0.status == .running } }

    // MARK: - Panel pages and inline navigation

    /// Retains the home document and its disclosure state; navigation never owns running work.
    func openSettings(group: SettingsGroup? = nil, source: MimicMotionSource = .current) {
        self.navigationSource = source
        self.releasePanelFocus?()
        self.terminalFocusTaskID = nil; self.analysisEditorFocusTaskID = nil
        self.cancelPanelScroll(); self.settingsScroll.cancel()
        AIUsageTrendPopoverController.dismissAll()
        self.panelPage = .settings
        if let group {
            self.settingsGroup = group
            self.settingsScroll.begin(target: group.scrollID, source: source)
        }
    }

    func toggleSettings(source: MimicMotionSource = .current) {
        if self.panelPage == .settings { self.returnHome(source: source) }
        else { self.openSettings(source: source) }
    }

    /// Back restores the retained scroll position without issuing a new reveal request.
    func returnHome(source: MimicMotionSource = .current) {
        self.navigationSource = source
        self.releasePanelFocus?()
        self.terminalFocusTaskID = nil; self.analysisEditorFocusTaskID = nil
        self.cancelPanelScroll(); self.settingsScroll.cancel()
        self.panelPage = .home
    }

    func toggleSettingsGroup(_ group: SettingsGroup, source: MimicMotionSource = .current) {
        self.navigationSource = source; self.releasePanelFocus?()
        self.settingsScroll.cancel()
        self.settingsGroup = self.settingsGroup == group ? nil : group
    }

    /// Opening and collapsing areas never invalidate drafts or cancel work.
    func toggleSection(_ section: PanelSection, source: MimicMotionSource = .current) {
        self.navigationSource = source; self.releasePanelFocus?()
        if self.panelPage == .home, self.expandedSection == section {
            self.expandedSection = nil; self.terminalFocusTaskID = nil; self.analysisEditorFocusTaskID = nil
        } else { self.revealSection(section, source: source) }
    }

    func revealSection(_ section: PanelSection, source: MimicMotionSource = .current) {
        self.navigationSource = source; self.releasePanelFocus?()
        self.terminalFocusTaskID = nil; self.analysisEditorFocusTaskID = nil
        if self.panelPage != .home { self.returnHome(source: source) }
        self.expandedSection = section
        self.scrollPanel(to: section.scrollID, source: source)
    }

    /// Inspect an exact remote run without changing checkout admission or local Git state.
    func showCI(_ summary: CICompactSummary) {
        guard let state = self.ciMonitor.state(for: summary) else { return }
        self.ciPresentedState.setVisible(false)
        self.ciInspection = summary
        self.panelLayout.expanded = .ci
        self.revealSection(.ci)
        self.showPanel?()
        state.setVisible(true); state.setFeedPresented(true)
        if let id = summary.pipelineID { state.revealPipeline(id) }
    }

    func clearCIInspection() {
        self.ciPresentedState.setVisible(false); self.ciInspection = nil
        self.ci.setVisible(self.panelVisible)
    }

    func scrollPanel(to target: String, source: MimicMotionSource = .current) {
        self.panelScroll.begin(target: target, source: source)
    }

    /// Manual scrolling invalidates queued reveals and their last target.
    @discardableResult func cancelPanelScroll() -> Bool { self.panelScroll.cancel() }

    func openTool(_ action: MimicAction, source: MimicMotionSource = .current) {
        self.navigationSource = source
        if action == .bootstrap {
            self.panelLayout.expanded = .bootstrap
            if self.panelPage != .home { self.returnHome(source: source) }
            self.releasePanelFocus?()
            self.expandedSection = nil; self.terminalFocusTaskID = nil; self.analysisEditorFocusTaskID = nil
            self.scrollPanel(to: "section.bootstrap", source: source)
        } else { self.revealSection(.tool(action), source: source) }
    }

    var filteredTaskRecords: [TaskRecord] {
        self.records.reversed().filter { record in
            let matchesState = self.taskFilter == .all || (self.taskFilter == .active && (record.status == .running || record.status == .queued)) || (self.taskFilter == .failed && (record.status == .failed || record.status == .interrupted))
            let content = text(record.action.titleKey) + record.project.path + record.project.branch + (record.generation?.name ?? "") + (record.simulator?.name ?? "")
            return matchesState && (self.taskSearch.isEmpty || content.localizedCaseInsensitiveContains(self.taskSearch))
        }
    }

    func toggleHistory(source: MimicMotionSource = .current) {
        if self.panelPage == .home, self.expandedSection == .tasks { self.toggleSection(.tasks, source: source) }
        else { self.showHistory(source: source) }
    }

    /// All entry points select the original task in the same panel. Terminal focus is explicit.
    func showHistory(id: UUID? = nil, focusTerminal: Bool = false, source: MimicMotionSource = .current) {
        self.navigationSource = source
        var selected = id ?? self.selectedTaskID ?? self.activeID ?? self.summary.last?.id ?? self.records.last?.id
        if let candidate = selected, !self.filteredTaskRecords.contains(where: { $0.id == candidate }) {
            if id != nil { self.taskSearch = ""; self.taskFilter = .all }
            else { selected = self.filteredTaskRecords.first?.id }
        }
        self.builds.selectedID = nil
        self.revealSection(.tasks, source: source)
        if let id { self.revealHistoryEntry(id) }
        else if !self.visibleTaskHistory.contains(where: { $0.id == selected }) {
            selected = self.visibleTaskHistory.first(where: { $0.task != nil })?.id
        }
        self.selectedTaskID = selected
        if let selected {
            if focusTerminal, let record = self.selectedRecord,
               record.status != .failed, record.status != .interrupted, record.status != .queued,
               !record.metadataOnly || record.status == .running {
                self.terminalFocusTaskID = selected; self.terminalFocusRequest = UUID()
                self.scrollPanel(to: "terminal." + selected.uuidString, source: source)
            } else { self.scrollPanel(to: "task." + selected.uuidString, source: source) }
        }
        self.unreadFailure = false; self.showPanel?()
    }

    func toggleTask(_ id: UUID, source: MimicMotionSource = .current) {
        self.navigationSource = source; self.releasePanelFocus?()
        self.terminalFocusTaskID = nil; self.analysisEditorFocusTaskID = nil
        self.builds.selectedID = nil
        self.selectedTaskID = self.selectedTaskID == id ? nil : id
        if self.selectedTaskID != nil { self.scrollPanel(to: "task." + id.uuidString, source: source) }
    }

    func showBuildResult(_ id: UUID) {
        guard builds.records.contains(where: { $0.id == id }) else { return }
        selectedTaskID = nil; taskSearch = ""; taskFilter = .all
        revealSection(.tasks); revealHistoryEntry(id); builds.selectedID = id
        scrollPanel(to: "build." + id.uuidString); showPanel?()
    }
    func toggleBuild(_ id: UUID) {
        selectedTaskID = nil; releasePanelFocus?(); builds.selectedID = builds.selectedID == id ? nil : id
        if builds.selectedID != nil { scrollPanel(to: "build." + id.uuidString) }
    }
    var filteredBuildRecords: [BuildActivity] {
        builds.records.reversed().filter { record in
            let state = taskFilter == .all || taskFilter == .active && record.status.isPending || taskFilter == .failed && [.failed, .interrupted, .unknown].contains(record.status)
            return state && (taskSearch.isEmpty || (buildTitle(record) + record.project.path + record.project.branch + record.parameters.scheme).localizedCaseInsensitiveContains(taskSearch))
        }
    }

    // MARK: - Combined history window

    var taskHistory: [TaskHistoryEntry] {
        (self.filteredTaskRecords.map(TaskHistoryEntry.local) + self.filteredBuildRecords.map(TaskHistoryEntry.build))
            .sorted { $0.date > $1.date }
    }
    var visibleTaskHistory: [TaskHistoryEntry] { Array(self.taskHistory.prefix(self.taskHistoryLimit)) }
    var hasMoreTaskHistory: Bool { self.taskHistory.count > self.taskHistoryLimit }

    func showMoreTaskHistory() {
        guard self.hasMoreTaskHistory else { return }
        self.taskHistoryLimit += 3
    }

    private func resetTaskHistory() {
        self.taskHistoryLimit = 2
        let visible = Set(self.visibleTaskHistory.map(\.id))
        if let id = self.selectedTaskID, !visible.contains(id) {
            self.selectedTaskID = nil; self.terminalFocusTaskID = nil; self.analysisEditorFocusTaskID = nil
            self.releasePanelFocus?(); self.cancelPanelScroll()
        }
        if let id = self.builds.selectedID, !visible.contains(id) { self.builds.selectedID = nil; self.cancelPanelScroll() }
    }

    /// Explicit navigation exposes whole pages before the scroll driver seeks the original row.
    private func revealHistoryEntry(_ id: UUID) {
        guard let index = self.taskHistory.firstIndex(where: { $0.id == id }), index >= self.taskHistoryLimit else { return }
        self.taskHistoryLimit = 2 + ((index - 2) / 3 + 1) * 3
    }

    // MARK: - Project discovery

    var canSelectProject: Bool { !self.switchingBranch && !self.builds.hasPending && !self.simulatorScreen.hasPending }

    func chooseProject() {
        guard self.canSelectProject else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = false
        if panel.runModal() == .OK, let path = panel.url?.path { self.addProject(path: path) }
    }

    func addProject(path: String) {
        guard self.canSelectProject else { return }
        let target = self.activeProfile?.profile.appleTarget
        Task {
            let found = await Task.detached { try? EnvironmentInspector.project(path: path, appleTarget: target) }.value
            guard let found, !self.builds.hasPending && !self.simulatorScreen.hasPending, !self.switchingBranch else { self.message = text("project.invalid"); return }
            if !self.projects.contains(where: { $0.path == found.path }) { self.projects.append(found) }
            self.selectedProjectPath = found.path; self.saveProjects(); self.refresh()
            self.updateCIContext()
        }
    }

    func selectProject(_ project: ProjectContext) {
        guard self.canSelectProject else { return }
        self.selectedProjectPath = project.path; self.branchRevision = UUID(); self.branchListRevision = UUID(); self.loadingBranches = false; self.branchError = ""; self.localBranches = []
        self.saveProjects(); self.updateCIContext(); self.refresh()
    }

    // MARK: - Local branches and panel lifecycle

    func panelVisibilityChanged(_ visible: Bool) {
        self.panelVisible = visible
        self.ciPresentedState.setVisible(visible)
        if visible { self.refreshGit() }
        else { self.cancelPanelScroll(); self.settingsScroll.cancel(); self.terminalFocusTaskID = nil; self.analysisEditorFocusTaskID = nil }
    }

    func refreshGit() {
        guard let current = self.project, !self.switchingBranch else { return }
        let revision = UUID(); self.branchRevision = revision
        Task {
            do {
                let snapshot = try await self.branchService.inspect(current)
                guard self.branchRevision == revision, self.selectedProjectPath == current.path, !self.switchingBranch else { return }
                self.applyGit(snapshot)
            } catch {
                guard self.branchRevision == revision, self.selectedProjectPath == current.path else { return }
                self.gitSummary = nil; self.branchError = self.branchErrorText(error)
            }
        }
    }

    func loadBranches() {
        guard let current = self.project, !self.loadingBranches, !self.switchingBranch else { return }
        self.loadingBranches = true; self.branchError = ""
        let revision = UUID(); self.branchListRevision = revision
        Task {
            defer { if self.branchListRevision == revision { self.loadingBranches = false } }
            do {
                let snapshot = try await self.branchService.inspect(current)
                let branches = try await self.branchService.branches(current)
                guard self.branchListRevision == revision, self.selectedProjectPath == current.path, !self.switchingBranch else { return }
                self.applyGit(snapshot); self.localBranches = branches
            } catch { if self.branchListRevision == revision, self.selectedProjectPath == current.path { self.branchError = self.branchErrorText(error) } }
        }
    }

    func switchBranch(_ name: String) {
        guard let current = self.project, current.branch != name else { return }
        guard self.canSwitchBranch, self.checkoutGate.beginSwitch(records: self.records, preparing: self.preparing) else { self.branchError = text("branch.blocked"); return }
        self.switchingBranch = true; self.branchRevision = UUID(); self.projectRevision = UUID(); self.readinessRevision = UUID()
        self.branchError = ""; self.invalidateGeneration()
        Task {
            defer {
                self.checkoutGate.finishSwitch(); self.switchingBranch = false
                if self.stoppingForExit { self.finishExitIfReady() } else { self.refresh(); self.startNext() }
            }
            do { try self.applyGit(await self.branchService.switchBranch(name, project: current)) }
            catch { self.branchError = self.branchErrorText(error) }
        }
    }

    private func branchErrorText(_ error: any Error) -> String {
        switch error {
        case BranchError.dirty: text("branch.dirty")
        case BranchError.operation: text("branch.operation")
        case BranchError.missing: text("branch.missing")
        case let BranchError.command(output): output
        default: text("branch.error")
        }
    }

    private func applyGit(_ snapshot: GitCheckoutState) {
        guard let index = self.projects.firstIndex(where: { $0.path == snapshot.project.path }) else { return }
        let changed = !QueuePolicy.matches(self.projects[index], request: snapshot.project)
        if changed {
            self.projectRevision = UUID(); self.readinessRevision = UUID(); self.checking = false
            self.invalidateGeneration()
        }
        self.projects[index] = snapshot.project; self.gitSummary = snapshot.summary; self.hasGitOperation = snapshot.hasOperation
        self.saveProjects(); self.updateCIContext()
        if changed, !self.switchingBranch { self.checkReadiness() }
    }

    private func updateCIContext() {
        self.ciSettings.selectCheckout(self.selectedProjectPath)
        self.ciMonitor.setDesktop(self.project.flatMap { project in self.ciSettings.connection.map { CIContext(project: project, connection: $0) } })
        self.ciPresentedState.setVisible(self.panelVisible)
    }

    func refresh() {
        guard let current = project, !self.switchingBranch, !self.builds.hasPending && !self.simulatorScreen.hasPending else { return }
        let revision = UUID(); projectRevision = revision
        self.diagnostic = text("diagnostic.loading"); self.checking = true; self.readiness = [:]; self.gitSummary = nil; self.invalidateGeneration()
        // Device discovery depends on checkout/Xcode, not the Git revision of the full diagnostic.
        self.refreshSimulators()
        Task {
            let result = await Task.detached { () -> (ProjectContext?, [String], GitSummary?) in
                guard let updated = try? EnvironmentInspector.project(path: current.path, developerDirectory: current.developerDirectory, appleTarget: current.appleTarget) else { return (nil, [], nil) }
                let status = EnvironmentInspector.capture("/usr/bin/git", ["-C", updated.path, "status", "--porcelain=v1", "-z"], trim: false)
                return (updated, EnvironmentInspector.diagnostic(project: updated), status.0 == 0 ? GitSummary(porcelain: status.1) : nil)
            }.value
            guard self.projectRevision == revision, self.project == current else { return }
            if let updated = result.0, let index = projects.firstIndex(where: { $0.path == current.path }) {
                self.projects[index] = updated; self.diagnostic = result.1.joined(separator: "\n"); self.gitSummary = result.2; self.saveProjects()
            } else { self.diagnostic = text("project.invalid") }
            self.checking = false; self.checkReadiness()
            self.refreshGit()
        }
    }

    func chooseXcode() {
        guard let current = project, !self.switchingBranch else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            let developer = url.appendingPathComponent("Contents/Developer").path
            guard FileManager.default.fileExists(atPath: developer + "/usr/bin/xcodebuild"), let index = projects.firstIndex(where: { $0.path == current.path }) else { self.message = text("xcode.invalid"); return }
            self.projects[index].developerDirectory = developer; self.saveProjects(); self.refresh()
        }
    }

    func resetXcode() {
        guard !self.builds.hasPending && !self.simulatorScreen.hasPending, !self.switchingBranch else { return }
        if let index = projects.firstIndex(where: { $0.path == selectedProjectPath }) { self.projects[index].developerDirectory = nil; self.saveProjects(); self.refresh() }
    }

    func saveProjects() {
        if let data = try? JSONEncoder().encode(projects) { self.defaults.set(data, forKey: "projects") }
        self.defaults.set(self.selectedProjectPath, forKey: "selectedProject")
    }

    // MARK: - Tool readiness and Generation preview

    var hasCompatibleProfile: Bool { self.activeProfile?.profile.schemaVersion == 2 && self.activeProfile?.profile.interface != nil }

    func profileExecution(_ action: MimicAction, options: BootstrapOptions? = nil, generation: GenerationRequest? = nil, preview: Bool = false) throws -> ProfileExecution {
        guard let snapshot = self.activeProfile, hasCompatibleProfile else { throw ProfileError.interface }
        let role: ProfileToolRole
        switch action {
        case .bootstrap: role = .bootstrap
        case .localization: role = .localization
        case .proto: role = .protocols
        case .format: role = .format
        case .fullCleanup: role = .fullCleanup
        case .derivedDataCleanup: role = .derivedDataCleanup
        case .generation:
            switch generation?.kind ?? generatorKind { case .ui: role = .generateUI; case .module: role = .generateSicilia; case .feature: role = .generateGalera }
        default: throw ProfileError.action
        }
        let values: [ProfileFormField: String] = action == .bootstrap ? (options ?? bootstrapOptions).profileValues : action == .generation ? [.name: generation?.name ?? generatorName] : [:]
        let execution = try snapshot.execution(role: role, values: values, preview: preview)
        if let generation, !preview {
            var values = execution.parameters; values["expectedDigest"] = generation.digest
            return ProfileExecution(snapshot: snapshot, actionID: execution.actionID, parameters: values)
        }
        return execution
    }

    func checkReadiness() {
        guard let current = project else { return }
        self.readiness = [:]; self.checking = false
        for action in [MimicAction.bootstrap, .localization, .proto, .format, .generation, .fullCleanup, .derivedDataCleanup] {
            do {
                let execution = try self.profileExecution(action, preview: action == .generation)
                let missing = execution.missingTools(project: current)
                self.readiness[action] = missing
            } catch { self.readiness[action] = hasCompatibleProfile && action == .generation ? [] : [text("profile.action.required")] }
        }
    }

    func invalidateGeneration() {
        self.profilePreviews = self.profilePreviews.filter { $0.key.contains("|") }
        self.generationRevision = UUID(); self.generationPlan = nil; self.generationError = ""; self.planningGeneration = false; self.previewProjectPath = nil
    }

    func previewGeneration() {
        guard GenerationRequest.validName(generatorName), !planningGeneration else { return }
        do {
            let execution = try profileExecution(.generation, preview: true)
            self.planningGeneration = true; self.generationPlan = nil; self.generationError = ""
            self.requestProfile(execution: execution, reveal: false) { record in
                if record == nil { self.planningGeneration = false; self.generationError = self.message }
            }
        } catch { self.generationError = text("profile.action.required") }
    }

    func generateFromPreview() {
        guard let plan = generationPlan, plan.canGenerate, previewProjectPath == selectedProjectPath else { return }
        let request = GenerationRequest(kind: generatorKind, name: generatorName, digest: plan.digest)
        self.request(.generation, generation: request)
    }

    // MARK: - iOS simulators

    func refreshSimulators() {
        guard let current = project else { return }
        let revision = UUID(); simulatorRevision = revision
        self.loadingSimulators = true; self.simulatorError = ""; self.simulators = []
        Task {
            let result = await Task.detached {
                let developer = current.developerDirectory ?? EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
                var env = EnvironmentInspector.environment(project: current); env["DEVELOPER_DIR"] = developer
                return (EnvironmentInspector.capture("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], environment: env), developer)
            }.value
            guard self.simulatorRevision == revision, self.project?.path == current.path, self.project?.developerDirectory == current.developerDirectory else { return }
            self.loadingSimulators = false
            do {
                guard result.0.0 == 0, !result.1.isEmpty else { throw MimicError.invalidSimulator }
                self.simulatorDeveloper = result.1
                self.simulators = try SimulatorCatalog.parse(Data(result.0.1.utf8))
            } catch { self.simulators = []; self.simulatorError = text("simulators.error") }
        }
    }

    func openSimulator(_ device: SimulatorDevice) {
        guard let current = project else { return }
        Task { [self] in
            let developer: String
            if let selected = current.developerDirectory { developer = selected }
            else { developer = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1 }.value }
            guard self.project == current else { return }
            let url = URL(fileURLWithPath: developer).appendingPathComponent("Applications/Simulator.app")
            guard FileManager.default.fileExists(atPath: url.path) else { self.message = text("simulators.error"); return }
            let config = NSWorkspace.OpenConfiguration(); config.arguments = ["-CurrentDeviceUDID", device.id.uuidString]
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                Task { @MainActor [weak self] in
                    if error != nil { self?.message = text("simulators.open.error") }
                    else { self?.recordSimulatorUsage(device.id, developer: developer) }
                }
            }
        }
    }

    private func recordSimulatorUsage(_ id: UUID, developer: String) {
        self.simulatorUsage.record(id, developer: developer); self.usageStore.save(self.simulatorUsage)
        self.rememberSimulator(id, developer: developer)
    }

    // MARK: - Task lifecycle

    var canRequestQuickBootstrap: Bool {
        self.hasCompatibleProfile && self.canRequestQuickCleanup && !self.bootstrapLocked
    }

    var canRequestQuickCleanup: Bool {
        self.hasCompatibleProfile && self.project != nil && !self.stoppingForExit && !self.switchingBranch && self.checkoutGate.admissions == 0 && self.pendingCount < 100
    }

    func requestQuickCleanup(_ action: MimicAction) {
        guard action.isCleanup, self.canRequestQuickCleanup else { return }
        self.request(action, options: .standard(platform: .ios), quick: true)
    }

    /// Menu and main-card launches use the same unmodified Bootstrap CLI defaults.
    func requestQuickBootstrap(platform: BootstrapPlatform) {
        guard self.canRequestQuickBootstrap else { return }
        self.request(.bootstrap, options: .standard(platform: platform), quick: true, navigate: false)
    }

    func request(_ action: MimicAction, options: BootstrapOptions? = nil, generation: GenerationRequest? = nil, simulator: SimulatorDevice? = nil, quick: Bool = false, expected: ProjectContext? = nil, recordID: UUID = UUID(), reveal: Bool = true, navigate: Bool = true, completion: ((TaskRecord?) -> Void)? = nil) {
        if action != .simulatorBoot && action != .simulatorShutdown {
            do {
                let captured = options ?? self.bootstrapOptions
                guard action != .bootstrap || (!self.bootstrapLocked && captured.isValid) else { completion?(nil); return }
                let execution = try self.profileExecution(action, options: captured, generation: generation)
                self.requestProfile(execution: execution, expected: expected, recordID: recordID, quick: quick, reveal: reveal, navigate: navigate, completion: completion)
            } catch { self.message = text("profile.action.required"); completion?(nil) }
            return
        }
        guard action == .simulatorBoot || action == .simulatorShutdown || action.isCleanup else { completion?(nil); self.message = text("profile.action.required"); return }
        guard let current = project, !self.stoppingForExit, !self.switchingBranch else { completion?(nil); return }
        guard self.pendingCount < 100 else { self.message = text("queue.full"); completion?(nil); return }
        guard expected == nil || expected == current else { completion?(nil); return }
        let options = options ?? (action == .bootstrap ? .standard(platform: self.bootstrapOptions.platform) : self.bootstrapOptions)
        guard action != .bootstrap || (!self.bootstrapLocked && options.isValid) else { completion?(nil); return }
        guard self.checkoutGate.admitTask() else { completion?(nil); return }
        self.objectWillChange.send()
        if action == .bootstrap { self.requestingBootstrap = true }
        let navigationSource = MimicMotionSource.current
        var request = TaskRecord(id: recordID, action: action, project: current, options: options, generation: generation, simulator: simulator)
        if action == .bootstrap { self.quickBootstrapActivity = QuickBootstrapActivity(request: request) }
        Task {
            var admitted: TaskRecord?
            defer {
                completion?(admitted)
                if action == .bootstrap { self.requestingBootstrap = false }
                self.checkoutGate.finishAdmission(); self.objectWillChange.send()
                if self.stoppingForExit { self.finishExitIfReady() }
            }
            let checked: ProjectContext
            if action == .bootstrap {
                let admission = await self.inspectBootstrapAdmission(current, options)
                guard !self.stoppingForExit, self.quickBootstrapActivity?.request.status != .cancelled else { return }
                switch admission {
                case let .ready(project):
                    guard project.path == current.path, project.developerDirectory == current.developerDirectory else { self.rejectRequest("checkout.changed", quick: quick); return }
                    checked = project
                case let .failed(error): self.rejectRequest(error, quick: quick); return
                }
            } else {
                guard let project = await Task.detached(operation: { try? EnvironmentInspector.project(path: current.path, developerDirectory: current.developerDirectory, appleTarget: current.appleTarget) }).value else {
                    self.rejectRequest("project.invalid", quick: quick); return
                }
                checked = project
            }
            guard !self.stoppingForExit else { return }
            guard expected == nil || (checked == expected && self.project == current) else { self.rejectRequest("checkout.changed", quick: quick); return }
            guard self.pendingCount < 100 else { self.rejectRequest("queue.full", quick: quick); return }
            // Refresh Git metadata before queueing; retain the original request ID and options.
            if action == .bootstrap {
                request.project = checked
                self.quickBootstrapActivity?.request = request
                if let index = self.projects.firstIndex(where: { $0.path == current.path }), self.projects[index] == current {
                    self.projects[index] = checked
                    self.saveProjects(); self.updateCIContext()
                }
            }
            request.project = checked
            request.selectedDeveloperDirectory = checked.developerDirectory ?? EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
            let record = request
            admitted = record
            self.records.append(record); if navigate { self.selectedTaskID = record.id }; self.persist()
            if reveal && navigate, action == .bootstrap { self.openTool(.bootstrap, source: navigationSource) }
            else if reveal && navigate { self.showHistory(id: record.id, source: navigationSource) }
            self.startNext()
        }
    }

    /// Admission can be cancelled before a queue record exists; late results cannot launch it.
    func cancelQuickBootstrap(id: UUID) {
        if self.records.contains(where: { $0.id == id }) { self.cancel(id: id); return }
        guard self.quickBootstrapActivity?.request.id == id else { return }
        self.quickBootstrapActivity?.request.status = .cancelled
        self.quickBootstrapActivity?.request.finishedAt = Date()
    }

    private func rejectRequest(_ error: String, quick: Bool) {
        let message = error.hasPrefix("missing: ") ? text("tools.missing") + String(error.dropFirst(9)) : text(error)
        if self.requestingBootstrap { self.quickBootstrapActivity?.error = message; self.unreadFailure = true }
        else { self.message = message }
    }

    func repeatTask(_ record: TaskRecord) {
        if let execution = record.profileExecution {
            if execution.action?.presentation == .generator {
                self.generatorKind = record.generation?.kind ?? .ui; self.generatorName = record.generation?.name ?? ""
                self.invalidateGeneration(); self.openTool(.generation); self.generationError = text("generator.review.again"); return
            }
            self.requestProfile(execution: execution, expected: record.project); return
        }
        guard !self.switchingBranch, record.project.path == self.project?.path else { return }
        if record.action == .generation {
            self.invalidateGeneration(); self.openTool(.generation)
            self.generatorKind = record.generation?.kind ?? .ui; self.generatorName = record.generation?.name ?? ""
            self.generationError = text("generator.review.again"); self.showPanel?(); return
        }
        self.request(record.action, options: record.options, generation: record.generation, simulator: record.simulator)
    }

    private func startNext() {
        guard !self.busy, !self.switchingBranch, !self.stoppingForExit else { return }
        guard let choice = QueuePolicy.nextActivity(in: records, builds: builds.records, simulators: simulatorScreen.records) else { return }
        if case let .simulator(id) = choice, let record = simulatorScreen.records.first(where: { $0.id == id }) { simulatorScreen.start(record); return }
        if case let .build(id) = choice, let build = builds.records.first(where: { $0.id == id }) { builds.start(build); return }
        guard case let .legacy(id) = choice, let next = records.first(where: { $0.id == id }) else { return }
        let adapterPath = self.adapter.path
        let profileStore = self.profileStore
        self.launchPreparation.start(record: next, inspect: { next in
            await Task.detached { () -> CommandPreparation in
                do {
                    var actual = try EnvironmentInspector.project(path: next.project.path, developerDirectory: next.project.developerDirectory, appleTarget: next.project.appleTarget)
                    guard QueuePolicy.matches(actual, request: next.project) else { return .failed("checkout.changed") }
                    actual.developerDirectory = next.selectedDeveloperDirectory ?? actual.developerDirectory
                    var env = EnvironmentInspector.environment(project: actual)
                    if let execution = next.profileExecution {
                        try profileStore.verify(execution.snapshot)
                        try ProfileGeneratorValidation.revalidate(execution, project: actual)
                        return try .ready(execution.commands(project: actual)[0])
                    }
                    let missing = EnvironmentInspector.missing(action: next.action, options: next.options, project: actual, environment: env)
                    if !missing.isEmpty { return .failed("missing: " + missing.joined(separator: ", ")) }
                    if let device = next.simulator {
                        let developer = actual.developerDirectory ?? EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
                        guard !developer.isEmpty else { return .failed("simulators.error") }
                        env["DEVELOPER_DIR"] = developer
                        let result = EnvironmentInspector.capture("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], environment: env)
                        guard result.0 == 0, let catalog = try? SimulatorCatalog.parse(Data(result.1.utf8)),
                              let actualDevice = catalog.first(where: { $0.id == device.id }),
                              next.action == .simulatorBoot ? actualDevice.state == "Shutdown" : actualDevice.isBooted else { return .failed("simulators.changed") }
                    }
                    return try .ready(CommandSpec.make(action: next.action, project: actual, options: next.options, environment: env, generation: next.generation, simulator: next.simulator, adapter: adapterPath))
                } catch { return .failed("project.invalid") }
            }.value
        }, launch: { [weak self] command in
            guard let self, self.records.contains(where: { $0.id == next.id && $0.status == .queued }), !self.stoppingForExit else { return }
            if let execution = next.profileExecution {
                do { self.pipelineCommands[next.id] = Array(try execution.commands(project: next.executionProject).dropFirst()) }
                catch { self.cancel(id: next.id); return }
            }
            self.launch(id: next.id, command: command)
        }, failure: { [weak self] error in
            guard let self, let index = self.records.firstIndex(where: { $0.id == next.id && $0.status == .queued }), !self.stoppingForExit else { return }
            self.records[index].status = .failed
            self.records[index].error = error.hasPrefix("missing:") ? text("tools.missing") + String(error.dropFirst(8)) : text(error)
            self.records[index].finishedAt = Date(); self.unreadFailure = true
            self.captureBootstrapDiagnostic(id: next.id, output: Data())
            self.persist(); self.startNext()
        })
    }

    private func launch(id: UUID, command: CommandSpec) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let firstStep = self.records[index].startedAt == nil
        self.records[index].status = .running
        if firstStep { self.records[index].startedAt = Date() }; self.persist()
        if self.records[index].simulator != nil { self.simulatorLaunchDevelopers[id] = command.environment["DEVELOPER_DIR"] }
        if firstStep, self.records[index].action == .bootstrap {
            self.bootstrapProgress = BootstrapProgress(options: self.records[index].options, matchers: self.records[index].profileExecution?.action?.progress ?? []); self.bootstrapProgressID = id
        }
        if firstStep {
            self.buffers[id] = Data()
            if self.records[index].action == .bootstrap { _ = self.bootstrapTerminal(for: self.records[index]) }
        }
        if firstStep, !self.records[index].metadataOnly {
            do {
                let path = self.history.directory.appendingPathComponent(id.uuidString + ".log")
                self.log = try BoundedLog(url: path); self.records[index].logPath = path.path
            } catch { self.message = text("log.error") + ": " + error.localizedDescription }
        }
        let runner = PTYSession(); session = runner
        runner.onOutput = { [weak self] bytes in
            guard let self else { return }
            if self.records.first(where: { $0.id == id })?.action == .bootstrap {
                self.bootstrapProgress.consume(bytes)
                if self.quickBootstrapActivity?.request.id == id { self.quickBootstrapActivity?.progress = self.bootstrapProgress }
            }
            if let matchers = self.records.first(where: { $0.id == id })?.profileExecution?.action?.progress {
                let tail = String(decoding: (self.buffers[id] ?? Data()).suffix(4096) + bytes, as: UTF8.self)
                if self.records.first(where: { $0.id == id })?.action == .bootstrap {
                    self.profileProgress[id] = self.bootstrapProgress.currentStep.map { text("bootstrap.step." + $0.rawValue) }
                } else if let matcher = matchers.compactMap({ matcher in tail.range(of: matcher.contains, options: .backwards).map { (matcher, $0.lowerBound) } }).max(by: { $0.1 < $1.1 }) {
                    self.profileProgress[id] = matcher.0.title
                }
            }
            let prompt = DiagnosticText.clean(String(decoding: bytes.suffix(512), as: UTF8.self))
            if prompt.range(of: #"(?i)(?:password|passphrase|verification code|enter[^\n]{0,80}|\[y/n\]|\(y/n\))[:? >]\s*$"#, options: .regularExpression) != nil { self.awaitingInput.insert(id) }
            var buffered = self.buffers[id] ?? Data(); buffered.append(bytes)
            if buffered.count > 512 * 1024 { buffered = Data(buffered.suffix(512 * 1024)); self.truncatedBuffers.insert(id) }
            self.buffers[id] = buffered; self.terminalOutput?(id, bytes)
            do {
                if self.records.first(where: { $0.id == id }).map({ $0.profileExecution != nil && !$0.metadataOnly }) == true {
                    var incoming = bytes
                    // Keep discarding an oversized line until its boundary; its tail may still contain a credential.
                    if self.sanitizedLogDropping.contains(id) {
                        guard let newline = incoming.firstIndex(of: 10) else { return }
                        incoming = Data(incoming.suffix(from: incoming.index(after: newline)))
                        self.sanitizedLogDropping.remove(id)
                    }
                    var pending = self.sanitizedLogPending[id, default: Data()]; pending.append(incoming)
                    if let newline = pending.lastIndex(of: 10) {
                        let complete = pending.prefix(through: newline)
                        try self.log?.append(Data(DiagnosticText.clean(String(decoding: complete, as: UTF8.self)).utf8))
                        pending = Data(pending.suffix(from: pending.index(after: newline)))
                    }
                    if pending.count > 64 * 1024 {
                        pending = Data(); self.sanitizedLogDropping.insert(id); self.truncatedBuffers.insert(id)
                    }
                    self.sanitizedLogPending[id] = pending
                } else { try self.log?.append(bytes) }
            } catch { self.log?.close(); self.log = nil; self.message = text("log.error") }
        }
        runner.onCompletion = { [weak self] event in self?.finished(id: id, event: event) }
        do { try runner.start(helper: self.helper, command: command) }
        catch { self.records[index].error = error.localizedDescription; self.finished(id: id, event: nil) }
    }

    private func finished(id: UUID, event: HostEvent?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if event?.cancelled != true, event?.code == 0, event?.signal == 0, event?.launchError == 0,
           var remaining = self.pipelineCommands[id], !remaining.isEmpty, !self.stoppingForExit {
            let next = remaining.removeFirst(); self.pipelineCommands[id] = remaining
            self.session = nil; self.launch(id: id, command: next); return
        }
        self.pipelineCommands.removeValue(forKey: id)
        self.awaitingInput.remove(id)
        self.records[index].finishedAt = Date(); self.records[index].exitCode = event?.code; self.records[index].signal = event?.signal
        if event?.cancelled == true { self.records[index].status = .cancelled }
        else if event?.code == 0, event?.signal == 0, event?.launchError == 0 { self.records[index].status = .succeeded }
        else { self.records[index].status = .failed; self.unreadFailure = true }
        if let code = event?.launchError, code != 0 { self.records[index].error = text("process.launch.error") + " \(code)" }
        if let pending = self.sanitizedLogPending.removeValue(forKey: id) { try? self.log?.append(Data(DiagnosticText.clean(String(decoding: pending, as: UTF8.self)).utf8)) }
        self.sanitizedLogDropping.remove(id)
        self.records[index].truncated = (self.log?.truncated ?? false) || self.truncatedBuffers.contains(id)
        self.log?.close(); self.log = nil; self.session = nil
        if self.records[index].action == .bootstrap { self.bootstrapProgress.finish(succeeded: self.records[index].status == .succeeded) }
        self.captureBootstrapDiagnostic(id: id, output: self.buffers[id] ?? Data())
        let keep = Set(records.suffix(8).map(\.id)); self.buffers = self.buffers.filter { keep.contains($0.key) }; self.truncatedBuffers.formIntersection(keep)
        if let execution = self.records[index].profileExecution, execution.preview, self.records[index].status == .succeeded {
            do {
                let plan = try JSONDecoder().decode(GenerationPlan.self, from: self.buffers[id] ?? Data())
                try ProfileGeneratorValidation.validate(plan, project: self.records[index].project)
                if self.activeProfile == execution.snapshot {
                    self.profilePreviews[ProfilePreview.cacheKey(project: self.records[index].project, execution: execution)] = ProfilePreview(plan: plan, project: self.records[index].project, execution: execution)
                    if self.project == self.records[index].project {
                    self.profilePreviews[execution.actionID] = ProfilePreview(plan: plan, project: self.records[index].project, execution: execution)
                    if execution.binding?.role.generator == self.generatorKind,
                       execution.binding?.parameter(.name).flatMap({ execution.parameters[$0] }) == self.generatorName {
                        self.generationPlan = plan; self.previewProjectPath = self.selectedProjectPath
                    }
                    }
                }
            } catch { self.records[index].status = .failed; self.records[index].error = text("profile.preview.invalid") }
        }
        if self.records[index].profileExecution?.preview == true {
            self.planningGeneration = false
            if self.records[index].status != .succeeded { self.generationError = self.records[index].error ?? text("profile.preview.invalid") }
        }
        // Completed secrets-capable output is not kept in replay history.
        if self.records[index].metadataOnly { self.buffers.removeValue(forKey: id); self.truncatedBuffers.remove(id) }
        else if self.records[index].profileExecution != nil, let buffered = self.buffers[id] {
            self.buffers[id] = Data(DiagnosticText.clean(String(decoding: buffered, as: UTF8.self)).utf8)
        }
        let isSimulator = self.records[index].simulator != nil
        if self.records[index].action == .simulatorBoot, self.records[index].status == .succeeded,
           let device = self.records[index].simulator, let developer = self.simulatorLaunchDevelopers[id] {
            self.recordSimulatorUsage(device.id, developer: developer)
        }
        self.simulatorLaunchDevelopers.removeValue(forKey: id)
        self.persist()
        if isSimulator { self.refreshSimulators() }
        if self.stoppingForExit { self.finishExitIfReady() } else { self.startNext() }
    }

    func cancel(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if self.records[index].status == .running { self.session?.cancel() }
        else if self.records[index].status == .queued {
            self.records[index].status = .cancelled; self.records[index].finishedAt = Date()
            self.launchPreparation.cancel(id: id); self.persist(); self.startNext()
        }
    }

    func stopAndExit() {
        self.aiUsage.stop()
        self.profileRemote.stop()
        self.ciMonitor.stop(); self.ciFallback.setVisible(false); self.ciSettings.invalidate()
        self.simulatorScreen.stop()
        self.builds.stop()
        self.stoppingForExit = true; self.launchPreparation.cancelAll()
        self.clearDiagnosticsForExit(); self.aiSettings.stop()
        for index in self.records.indices where self.records[index].status == .queued {
            records[index].status = .cancelled; records[index].finishedAt = Date()
        }
        self.persist()
        self.session?.cancel(); self.finishExitIfReady()
    }

    // MARK: - Ephemeral error analysis

    /// Captures the failed fragment before sensitive terminal replay is discarded.
    func captureBootstrapDiagnostic(id: UUID, output: Data) {
        guard let record = self.records.first(where: { $0.id == id }) else { return }
        self.diagnostics.capture(record: record, output: output, wasTruncated: self.truncatedBuffers.contains(id))
        self.analysis.retainBootstrap(ids: self.diagnostics.ids)
    }

    func diagnosticUnavailable(id: UUID) -> Bool {
        self.records.first { $0.id == id }?.metadataOnly == true && self.diagnostics.fragment(id: id) == nil
    }

    /// Viewing diagnostics does not create an AI session or invoke a provider.
    func diagnosticSnapshot(for record: TaskRecord) -> DiagnosticSnapshot {
        if let session = self.analysis.sessions[record.id] { return session.snapshot }
        let output = record.metadataOnly ? self.diagnostics.fragment(id: record.id) : String(decoding: self.replay(id: record.id), as: UTF8.self)
        let unavailable = output?.isEmpty != false
        return DiagnosticSnapshot(record: record, output: unavailable ? record.error ?? "" : output ?? "", wasTruncated: self.diagnostics.isTruncated(id: record.id) || self.truncatedBuffers.contains(record.id), outputUnavailable: unavailable)
    }

    /// Freezes original task identity and reveals the same editor from every entry point.
    func prepareAnalysis(_ record: TaskRecord, inline: Bool = false) {
        guard record.status == .failed || record.status == .interrupted else { return }
        self.analysis.prepare(snapshot: self.diagnosticSnapshot(for: record), provider: self.aiSettings.settings.provider)
        self.expandedAnalysisIDs.insert(record.id)
        if inline { return }
        self.showHistory(id: record.id)
        self.analysisEditorFocusTaskID = record.id
        self.analysisFocusRequest = UUID()
        self.scrollPanel(to: "analysis." + record.id.uuidString)
    }

    /// Clipboard text is exactly the preview/submitted prompt, not a separate handoff draft.
    @discardableResult
    func copyAnalysisRequest(id: UUID, pasteboard: NSPasteboard = .general) -> Bool {
        guard let prompt = self.analysis.sessions[id]?.prompt else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(prompt, forType: .string)
    }

    func commandDisplay(for record: TaskRecord) -> String? {
        if let execution = record.profileExecution { return try? execution.commands(project: record.executionProject).map(\.display).joined(separator: "\n") }
        return try? CommandSpec.make(action: record.action, project: record.project, options: record.options, environment: [:], generation: record.generation, simulator: record.simulator, adapter: self.adapter.path).display
    }

    func clearDiagnosticsForExit() {
        for terminal in self.bootstrapTerminals.values { terminal.stop() }
        self.bootstrapTerminals.removeAll()
        self.diagnostics.clear(); self.truncatedBuffers.removeAll(); self.analysis.clearForExit(); self.expandedAnalysisIDs.removeAll()
    }

    private func finishExitIfReady() {
        guard self.stoppingForExit, self.builds.active == nil, self.simulatorScreen.canExit, !self.requestingBootstrap, self.session == nil, !self.switchingBranch, !self.analysis.isActive, self.aiSettings.checking == nil else { return }
        self.afterStopped?()
    }

    // MARK: - Terminal and history

    /// A subscription is disposable; removing it cannot affect another view or the PTY.
    func attachTerminal(owner: UUID, output: @escaping (UUID, Data) -> Void) {
        self.terminalSubscribers[owner] = output
    }

    func detachTerminal(owner: UUID) { self.terminalSubscribers.removeValue(forKey: owner) }

    /// Bootstrap presentation is memory-only and survives live replay-buffer cleanup.
    func bootstrapTerminal(for record: TaskRecord) -> BootstrapTerminalSession {
        if let terminal = self.bootstrapTerminals[record.id] { return terminal }
        let terminal = BootstrapTerminalSession(model: self, record: record)
        self.bootstrapTerminals[record.id] = terminal
        let keep = Set(self.records.filter { $0.action == .bootstrap }.suffix(8).map(\.id)).union([record.id])
        for id in Array(self.bootstrapTerminals.keys) where !keep.contains(id) && !self.records.contains(where: { $0.id == id && ($0.status == .queued || $0.status == .running) }) {
            self.bootstrapTerminals.removeValue(forKey: id)?.stop()
        }
        return terminal
    }

    func terminalSnapshot(id: UUID) -> Data {
        self.bootstrapTerminals[id]?.snapshot ?? self.replay(id: id)
    }

    /// Echoed input must not become a durable log or a diagnostic fragment.
    func input(id: UUID, data: Data) {
        guard id == activeID, !data.isEmpty, let index = records.firstIndex(where: { $0.id == id }) else { return }
        if records[index].hasPrivateInput != true {
            records[index].hasPrivateInput = true; log?.close(); log = nil
            if let path = records[index].logPath { try? FileManager.default.removeItem(atPath: path) }
            records[index].logPath = nil; sanitizedLogPending[id] = nil; sanitizedLogDropping.remove(id); persist()
        }
        self.bootstrapTerminals[id]?.discardReplayAfterPrivateInput()
        self.awaitingInput.remove(id); self.session?.send(data)
    }
    func resize(id: UUID, columns: Int, rows: Int) { if id == self.activeID { self.session?.resize(columns: columns, rows: rows) } }
    func replay(id: UUID) -> Data {
        if let data = buffers[id] { return data }
        if let path = records.first(where: { $0.id == id })?.logPath, let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            if let end = try? handle.seekToEnd() {
                if end > 512 * 1024 { self.truncatedBuffers.insert(id) }
                try? handle.seek(toOffset: end > 512 * 1024 ? end - 512 * 1024 : 0)
            }
            return (try? handle.readToEnd()) ?? Data()
        }
        return Data()
    }

    func copyCommand(record: TaskRecord) {
        if let command = self.commandDisplay(for: record) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        }
    }

    private func persist() {
        if let id = self.quickBootstrapActivity?.request.id, let record = self.records.first(where: { $0.id == id }) { self.quickBootstrapActivity?.request = record; if self.bootstrapProgressID == id { self.quickBootstrapActivity?.progress = self.bootstrapProgress } }
        let live = self.records.filter { $0.status == .queued || $0.status == .running }
        let completed = self.records.filter { $0.status != .queued && $0.status != .running }.suffix(max(0, 100 - live.count))
        self.records = (Array(completed) + live).sorted { $0.createdAt < $1.createdAt }
        let ids = Set(self.records.map(\.id))
        self.expandedAnalysisIDs.formIntersection(ids)
        self.diagnostics.retain(ids: ids); self.truncatedBuffers.formIntersection(ids); self.analysis.retain(ids: ids)
        do { try self.history.save(self.records) } catch { self.message = text("history.error") + ": " + error.localizedDescription }
    }

    #if DEBUG
    /// Injects catalogue data for isolated previews; boot commands remain disabled.
    func installSimulatorPreview(_ devices: [SimulatorDevice], developer: String = "/fixture/Xcode/Contents/Developer") {
        self.simulatorRevision = UUID()
        self.simulatorDeveloper = developer
        self.simulators = devices
        self.loadingSimulators = false
        self.simulatorError = ""
        self.readiness[.simulatorBoot] = ["fixture"]
    }

    /// Read-only manual acceptance fixture, isolated from the user's checkout and settings.
    func installInlinePanelPreview() {
        self.installTaskResultPreview()
        self.readiness = [.generation: [], .localization: [], .proto: ["protoc"], .format: [], .simulatorBoot: ["preview"]]
        self.generatorName = "ProfileHeader"
        let data = Data(#"{"files":[{"path":"Frameworks/Component/Sources/ProfileHeaderConfiguration.swift","exists":false}],"digest":"fixture"}"#.utf8)
        self.generationPlan = try? JSONDecoder().decode(GenerationPlan.self, from: data)
        self.installSimulatorPreview([
            SimulatorDevice(id: UUID(), name: "iPhone 17 Pro", runtime: "iOS 26.5", state: "Booted"),
            SimulatorDevice(id: UUID(), name: "iPad Air 11-inch", runtime: "iOS 26.5", state: "Booted"),
            SimulatorDevice(id: UUID(), name: "iPad Pro 13-inch Development", runtime: "iOS 26.5", state: "Shutdown")
        ])
        var success = TaskRecord(action: .format, project: self.projects[0]); success.status = .succeeded
        success.startedAt = Date().addingTimeInterval(-10); success.finishedAt = Date(); success.exitCode = 0
        self.records.append(success)
        self.buffers[success.id] = Data("Fixture terminal output\r\nNo project command was executed.\r\n".utf8)
    }

    /// A result-only fixture; the configured CLI cannot send data and no project process runs.
    func installTaskResultPreview() {
        let project = ProjectContext(path: "/private/tmp/Mimic-Result-Fixture", branch: "feature/bootstrap-diagnostics", commit: "fixture-sha")
        self.projects = [project]; self.selectedProjectPath = project.path
        var record = TaskRecord(action: .bootstrap, project: project, options: .standard())
        record.status = .failed; record.exitCode = 1
        record.startedAt = Date().addingTimeInterval(-12); record.finishedAt = Date()
        self.records = [record]; self.selectedTaskID = record.id
        self.captureBootstrapDiagnostic(id: record.id, output: Data(Array(repeating: "fastlane/fastfiles/emcee:223: invalid multibyte char (US-ASCII)", count: 8).joined(separator: "\n").utf8))
        self.aiSettings.settings.codexPath = "/nonexistent/Mimic-preview-Codex"
        self.aiSettings.settings.claudePath = "/nonexistent/Mimic-preview-Claude"
    }

    /// Motion scenarios mutate fixture presentation only; task admission and PTYs are never invoked.
    func installMotionPreview(_ scenario: String) {
        switch scenario {
        case "disclosure": if self.panelPage == .settings { self.revealSection(.tasks, source: .pointer) } else { self.openSettings(source: .pointer) }
        case "device":
            if let selected = self.selectedSimulator, let next = self.bootedSimulators.first(where: { $0.id != selected.id }) { self.selectSimulator(next) }
        case "status", "result":
            if self.quickBootstrapActivity == nil { self.installBootstrapPreview() }
            guard let id = self.quickBootstrapActivity?.request.id, let index = self.records.firstIndex(where: { $0.id == id }) else { return }
            if scenario == "result" {
                self.records[index].status = self.records[index].status == .failed ? .succeeded : .failed
                self.records[index].finishedAt = Date(); self.records[index].exitCode = self.records[index].status == .succeeded ? 0 : 1
                self.records[index].error = self.records[index].status == .failed ? "Fixture: dependency registry configuration failed; no project command was executed." : nil
            } else {
                self.records[index].status = self.records[index].status == .running ? .queued : .running
                self.records[index].startedAt = self.records[index].status == .running ? Date() : nil
                self.records[index].finishedAt = nil; self.records[index].error = nil
                self.records.removeAll { $0.action == .format }
                self.bootstrapProgressID = id
                self.bootstrapProgress = BootstrapProgress(options: self.records.first(where: { $0.id == id })!.options)
                let markers = try! JSONDecoder().decode([ProgressMatcher].self, from: Data(#"[{"title":"Fixture","contains":"fixture-brew","step":"brew","event":"complete"},{"title":"Fixture","contains":"fixture-mint","step":"mint","event":"start"}]"#.utf8))
                self.bootstrapProgress = BootstrapProgress(options: self.records.first(where: { $0.id == id })!.options, matchers: markers)
                self.bootstrapProgress.consume(Data("fixture-brew\nfixture-mint\n".utf8))
            }
            self.stateChanged?()
        default: break
        }
    }

    /// A disposable UI fixture: no process, Bootstrap, Xcode request or checkout mutation.
    func installBootstrapPreview(configuration: Bool = false) {
        let project = ProjectContext(path: "/private/tmp/Mimic-UI-Fixture")
        self.projects = [project]; self.selectedProjectPath = project.path
        var barrier = TaskRecord(action: .format, project: project); barrier.status = .running
        let record = TaskRecord(action: .bootstrap, project: project, options: .standard())
        self.records = configuration ? [barrier] : [barrier, record]
        self.quickBootstrapActivity = configuration ? nil : QuickBootstrapActivity(request: record)
    }
    #endif

}


// MARK: - Profile admission and setup

extension TaskCoordinator {
    func importProfile(checkout: String? = nil) {
        guard !self.importingProfile else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "mimicprofile") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = self.profileStore
        self.importingProfile = true
        Task {
            defer { self.importingProfile = false }
            do {
                let snapshot = try await Task.detached { try store.importArchive(url, requireInterface: true) }.value
                self.activeProfile = snapshot; self.invalidateGeneration(); self.applyProfileServices(); self.ciLaunch.contextChanged(); self.checkReadiness()
                if let index = self.projects.firstIndex(where: { $0.path == (checkout ?? self.selectedProjectPath) }), let target = snapshot.profile.appleTarget {
                    self.projects[index].appleTarget = target; self.saveProjects(); self.refresh()
                }
            } catch { self.message = text("profile.import.error") + ": " + String(describing: error) }
        }
    }

    func chooseAppleTarget() {
        guard let current = self.project, !self.busy, self.pendingCount == 0 else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "xcworkspace") ?? .data, .init(filenameExtension: "xcodeproj") ?? .data]
        panel.directoryURL = URL(fileURLWithPath: current.path)
        guard panel.runModal() == .OK, let url = panel.url, url.path.hasPrefix(current.path + "/") else { return }
        var configurationProject: String?
        if url.pathExtension == "xcworkspace" {
            panel.allowedContentTypes = [.init(filenameExtension: "xcodeproj") ?? .data]
            panel.message = text("profile.configuration.project")
            guard panel.runModal() == .OK, let project = panel.url, project.path.hasPrefix(current.path + "/") else { return }
            configurationProject = String(project.path.dropFirst(current.path.count + 1))
        }
        guard let index = self.projects.firstIndex(where: { $0.path == current.path }) else { return }
        self.projects[index].appleTarget = AppleTarget(path: String(url.path.dropFirst(current.path.count + 1)), configurationProject: configurationProject)
        self.saveProjects(); self.refresh()
    }

    func requestProfile(execution: ProfileExecution, expected: ProjectContext? = nil, recordID: UUID = UUID(), quick: Bool = false, reveal: Bool = true, navigate: Bool = true, completion: ((TaskRecord?) -> Void)? = nil) {
        guard expected != nil || execution.binding?.role != .bootstrap || !self.bootstrapLocked else { completion?(nil); return }
        guard let current = expected ?? self.project, let action = execution.action, action.remote == nil,
              expected == nil || self.projects.contains(current), !self.stoppingForExit, !self.switchingBranch,
              self.pendingCount < 100, self.checkoutGate.admitTask() else { completion?(nil); return }
        if action.presentation == .generator, !execution.preview {
            guard let reviewed = self.profilePreviews[ProfilePreview.cacheKey(project: current, execution: execution)] ?? self.profilePreviews[action.id], reviewed.project == current,
                  reviewed.execution.snapshot == execution.snapshot,
                  reviewed.execution.parameters == execution.parameters.filter({ $0.key != "expectedDigest" }),
                  reviewed.plan.digest == execution.parameters["expectedDigest"], reviewed.plan.canGenerate else { completion?(nil); self.checkoutGate.finishAdmission(); return }
        }
        let store = self.profileStore
        let bootstrap = execution.binding?.role == .bootstrap
        let navigationSource = MimicMotionSource.current
        var request = execution.record(id: recordID, project: current)
        if bootstrap && reveal {
            self.requestingBootstrap = true
            self.quickBootstrapActivity = QuickBootstrapActivity(request: request)
        }
        Task {
            var admitted: TaskRecord?
            defer {
                if bootstrap && reveal { self.requestingBootstrap = false }
                self.checkoutGate.finishAdmission(); self.objectWillChange.send(); completion?(admitted)
                if self.stoppingForExit { self.finishExitIfReady() }
            }
            do {
                try store.verify(execution.snapshot)
                let checked: ProjectContext
                if bootstrap {
                    let result = await self.inspectBootstrapAdmission(current, execution.bootstrapOptions)
                    guard !self.stoppingForExit, !reveal || self.quickBootstrapActivity?.request.status != .cancelled else { return }
                    switch result {
                    case .ready(let project): checked = project
                    case .failed(let error): self.rejectRequest(error, quick: quick); return
                    }
                } else {
                    checked = try await Task.detached { try EnvironmentInspector.project(path: current.path, developerDirectory: current.developerDirectory, appleTarget: current.appleTarget) }.value
                }
                guard !self.stoppingForExit, self.pendingCount < 100 else { return }
                guard checked.path == current.path, checked.developerDirectory == current.developerDirectory,
                      expected == nil || (checked == current && self.projects.contains(current)) else { throw MimicError.changedCheckout }
                _ = try execution.commands(project: checked)
                request.project = checked
                request.selectedDeveloperDirectory = checked.developerDirectory ?? EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
                let record = request
                if bootstrap && reveal {
                    self.quickBootstrapActivity?.request = record
                    if let index = self.projects.firstIndex(where: { $0 == current }) {
                        self.projects[index] = checked; self.saveProjects(); self.updateCIContext()
                    }
                }
                self.records.append(record); if reveal && navigate { self.selectedTaskID = record.id }; self.persist(); admitted = record
                if reveal && navigate {
                    if bootstrap { self.openTool(.bootstrap, source: navigationSource) }
                    else { self.showHistory(id: record.id, source: navigationSource) }
                }
                self.startNext()
            } catch {
                let message = (error as? MimicError) == .changedCheckout ? text("checkout.changed") : text("profile.action.error") + ": " + String(describing: error)
                if bootstrap && reveal { self.quickBootstrapActivity?.error = message; self.unreadFailure = true }
                else { self.message = message }
            }
        }
    }
}

extension TaskCoordinator {
    /// Read-only presentation adapter: historical feed widgets retain their navigation, never their executor.
    private func updateProfileCIFeed() {
        let current = self.profileRemote.runs.compactMap { run -> RemoteTestRun? in
            guard let binding = run.execution.binding, let gitlab = run.gitlab ?? self.ciSettings.connection else { return nil }
            let values = run.execution.parameters
            func value(_ field: ProfileFormField) -> String { binding.parameter(field).flatMap { values[$0] } ?? "" }
            let plan = UITestPlan(rawValue: value(.plan)) ?? .smoke
            var record = RemoteTestRun(id: run.id, requestID: run.requestID, checkout: run.checkout, branch: run.branch, plan: plan, jenkins: run.jenkins, gitlab: gitlab, createdAt: run.createdAt)
            switch binding.role {
            case .qualityGates: record.parameters = .qualityGates(Dictionary(uniqueKeysWithValues: QualityGate.allCases.map { ($0, value($0.profileField) == "true") }))
            case .beta: record.parameters = .beta(target: value(.target), rebase: value(.rebase), upload: value(.upload))
            default: record.parameters = .uiTests(plan)
            }
            record.status = run.status; record.queueURL = run.queueURL; record.buildURL = run.buildURL
            record.pipelineID = run.pipelineID; record.pipelineURL = run.pipelineURL; record.sha = run.sha
            record.jobs = run.jobs; record.allureURL = run.reportURL; record.error = run.error
            return record
        }
        self.ciMonitor.updateRuns(self.remoteTests.runs + current, jenkins: self.jenkinsSettings.connection)
    }
    private func applyProfileServices() {
        guard let services = self.activeProfile?.profile.services else { return }
        self.ci.branchOwnerPattern = services.branchOwnerPattern
        self.ciMonitor.branchOwnerPattern = services.branchOwnerPattern
        if let address = services.jenkinsURL { self.jenkinsSettings.address = address }
        if let address = services.gitLabURL { self.ciSettings.address = address }
        if let path = services.gitLabProject { self.ciSettings.projectPath = path }
    }
    func requestRemoteProfile(snapshot: ProfileSnapshot, action: ActionDefinition, parameters: [String: String], reviewed: ProfileRemoteContract? = nil) {
        Task {
            do { _ = try await self.submitRemoteProfile(snapshot: snapshot, action: action, parameters: parameters, reviewed: reviewed) }
            catch { self.message = text("profile.action.error") + ": " + String(describing: error) }
        }
    }
    func submitRemoteProfile(snapshot: ProfileSnapshot, action: ActionDefinition, parameters: [String: String], requestID: UUID = UUID(), reviewed: ProfileRemoteContract? = nil, expected: ProjectContext? = nil) async throws -> ProfileRemoteRun {
        guard let current = expected ?? self.project, expected == nil || self.projects.contains(current), let jenkins = self.jenkinsSettings.connection,
              snapshot.profile.services?.jenkinsURL == jenkins.baseURL.absoluteString,
              !self.switchingBranch, !self.stoppingForExit else { throw CIError.invalidConfiguration }
        let gitlab = self.ciSettings.connection(forCheckout: current.path, services: snapshot.profile.services)
        if action.remote?.tracking == .gitLabPipeline {
            guard let gitlab, snapshot.profile.services?.gitLabURL == gitlab.baseURL.absoluteString,
                  snapshot.profile.services?.gitLabProject == gitlab.projectPath else { throw CIError.invalidConfiguration }
        }
        try self.profileStore.verify(snapshot)
        let execution = ProfileExecution(snapshot: snapshot, actionID: action.id, parameters: parameters)
        return try await self.profileRemote.submit(id: requestID, checkout: current, execution: execution, jenkins: jenkins, gitlab: gitlab, reviewed: reviewed) {
            let checked = try await Task.detached { try EnvironmentInspector.project(path: current.path, developerDirectory: current.developerDirectory, appleTarget: current.appleTarget) }.value
            guard checked == current, self.projects.contains(current), self.activeProfile == snapshot,
                  self.jenkinsSettings.connection == jenkins, self.ciSettings.connection(forCheckout: current.path, services: snapshot.profile.services) == gitlab,
                  !self.switchingBranch, !self.stoppingForExit else { throw ProfileError.revision }
        }
    }
}


extension TaskCoordinator {
    /// Register a chat checkout without changing the desktop's selected project or active task.
    func bindPanelCheckout(_ path: String) async throws -> ProjectContext {
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let existing = projects.first { $0.path == normalized }
        let target = existing?.appleTarget ?? activeProfile?.profile.appleTarget
        let checked = try await Task.detached { try EnvironmentInspector.project(path: normalized, developerDirectory: existing?.developerDirectory, appleTarget: target) }.value
        if let index = projects.firstIndex(where: { $0.path == checked.path }) { projects[index] = checked }
        else { projects.append(checked) }
        saveProjects(); return checked
    }
    func refreshPanelContext(_ path: String) async {
        guard !switchingBranch, !hasGitOperation, let old = projects.first(where: { $0.path == path }),
              let checked = try? await Task.detached(operation: { try EnvironmentInspector.project(path: old.path, developerDirectory: old.developerDirectory, appleTarget: old.appleTarget) }).value,
              let index = projects.firstIndex(of: old) else { return }
        projects[index] = checked; saveProjects()
    }
    /// Explicit local branch switching uses the same checkout gate as the native branch picker.
    func switchPanelBranch(_ name: String, project: ProjectContext) async throws {
        guard !busy, pendingCount == 0, !builds.hasPending, !simulatorScreen.hasPending, !switchingBranch,
              checkoutGate.beginSwitch(records: records, preparing: preparing) else { throw MimicError.changedCheckout }
        switchingBranch = true
        defer { checkoutGate.finishSwitch(); switchingBranch = false; startNext() }
        let snapshot = try await branchService.switchBranch(name, project: project)
        guard let index = projects.firstIndex(of: project) else { throw MimicError.changedCheckout }
        projects[index] = snapshot.project; saveProjects()
    }
    /// Setup uses native system dialogs and can complete with the main Mimic window closed.
    func panelSetup(_ operation: String, project: ProjectContext?) async throws {
        if operation == "profile" { importProfile(checkout: project?.path); return }
        guard let project, let index = projects.firstIndex(of: project), !switchingBranch else { throw MimicError.changedCheckout }
        if operation == "xcode" {
            let panel = NSOpenPanel(); panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let developer = url.appendingPathComponent("Contents/Developer").path
            guard FileManager.default.fileExists(atPath: developer + "/usr/bin/xcodebuild") else { throw MimicError.changedCheckout }
            projects[index].developerDirectory = developer
        } else if operation == "target" {
            let panel = NSOpenPanel(); panel.directoryURL = URL(fileURLWithPath: project.path); panel.canChooseDirectories = false
            panel.allowedContentTypes = [.init(filenameExtension: "xcworkspace") ?? .data, .init(filenameExtension: "xcodeproj") ?? .data]
            guard panel.runModal() == .OK, let url = panel.url, url.path.hasPrefix(project.path + "/") else { return }
            var configurationProject: String?
            if url.pathExtension == "xcworkspace" {
                panel.allowedContentTypes = [.init(filenameExtension: "xcodeproj") ?? .data]; panel.message = text("profile.configuration.project")
                guard panel.runModal() == .OK, let source = panel.url, source.path.hasPrefix(project.path + "/") else { return }
                configurationProject = String(source.path.dropFirst(project.path.count + 1))
            }
            projects[index].appleTarget = AppleTarget(path: String(url.path.dropFirst(project.path.count + 1)), configurationProject: configurationProject)
        } else if operation == "xcodeMCP" { await builds.xcode.connect(project: project) }
        else { throw MimicError.changedCheckout }
        saveProjects()
    }
}

extension TaskCoordinator {
    func panelBranches(_ project: ProjectContext) async throws -> [String] { try await branchService.branches(project).map(\.name) }
}
