//
//  BuildCoordinator.swift
//  Mimic
//
//  Created by Василий Маслов on 04.10.2026.
import AppKit
import Combine
import Foundation
import MimicCore
import os

/// Build execution outlives every observer. TaskCoordinator admits it to the same global queue.
@MainActor final class BuildCoordinator: ObservableObject {
    @Published private(set) var records: [BuildActivity] = []
    @Published var draft = BuildParameters()
    @Published private(set) var catalogue = BuildCatalogue()
    @Published private(set) var loading = false
    @Published private(set) var catalogueProgress: BuildCatalogueProgress?
    @Published var message = ""
    @Published var pinned = false
    @Published var overlayWidth: CGFloat = BuildActivityPanel.preferredWidth
    @Published private(set) var manualSubmitting = false
    @Published var selectedID: UUID?
    @Published private(set) var revision = UUID()
    @Published var xcodeSimulatorConfirmed = false
    let xcode = XcodeBuildConnection()
    private let store: BuildHistoryStore
    private let helper: URL
    private let defaults: UserDefaults
    private let inspect: @Sendable (ProjectContext) async throws -> ProjectContext
    private let resolveDeveloper: @Sendable (ProjectContext) async throws -> String
    private let makeCommand: @Sendable (BuildActivity, String?) throws -> CommandSpec
    private let makeStageCommand: @Sendable (BuildActivity, BuildStage, CommandSpec) throws -> CommandSpec
    private let presentationDiscover: @Sendable (ProjectContext, String, Bool, String?, String?) async throws -> BuildCatalogue
    private let discover: @Sendable (ProjectContext, String, Bool, String?, String?) async throws -> BuildCatalogue
    private let validateSelection: @Sendable (ProjectContext, String, Bool, String?, String?) async throws -> BuildCatalogue
    private let discoveryService: BuildDiscovery
    private let usesDiscoveryService: Bool
    var artifactLeases: Set<UUID> = []
    var checkPreparation: (ProjectContext, BuildParameters) async throws -> Void = { _, _ in }
    var artifactRoot: URL { store.directory }
    private var sourceMonitor: Task<Void, Never>?
    private var changeSnapshots: [UUID: GitActivitySnapshot] = [:]
    private var outputs: [UUID: BuildOutput] = [:]
    private var testProgress: [UUID: BuildTestProgress] = [:]
    private var buildEvents: BuildEventStream?
    private var buildEventsMonitor: Task<Void, Never>?
    private var savedTails: [UUID: [String]] = [:]
    private var workers: [UUID: BuildOutputWorker] = [:]
    private var logTruncation = Set<UUID>()
    private var ledger: [String: Admission] = [:]
    private var session: PTYSession?
    private var continuationTask: Task<Void, Never>?
    private var productChoice: CheckedContinuation<BuildProduct, Error>?
    private var preparation: Task<Void, Never>?
    private var updateTimer: Task<Void, Never>?
    private var launchID: UUID?
    private var catalogueRevision = UUID()
    private var catalogueContext: ProjectContext?
    private var catalogueScheme = ""
    private var catalogueDeveloper = ""
    private var restoredContext: ProjectContext?
    private var restoredProfile = ""
    private var presentationRequest: (profile: String, project: ProjectContext, scheme: String, tests: Bool, task: Task<Void, Never>)?
    private var preloadTask: Task<Void, Never>?
    @Published private(set) var catalogueLoadedAt: Date?
    var catalogueStale: Bool { catalogueLoadedAt.map { Date().timeIntervalSince($0) >= 600 } ?? true }

    private var stopped = false
    private var draftKey: String?
    private var renderBatch = Data()
    private let signposter = OSSignposter(subsystem: "local.vmaslov.Mimic", category: "BuildOutput")
    var schedule: () -> Void = { }
    var currentProject: () -> ProjectContext? = { nil }
    /// Additional registered chat contexts may enter the same FIFO without changing desktop selection.
    var currentProfile: () -> ProfileSnapshot? = { nil }
    var acceptsProject: (ProjectContext) -> Bool = { _ in false }
    private func accepts(_ project: ProjectContext) -> Bool { currentProject() == project || acceptsProject(project) }
    var mayAdmit: () -> Bool = { true }
    var showResult: (UUID) -> Void = { _ in }
    var showSimulator: (BuildActivity) -> Void = { _ in }
    /// Fresh evidence that the Xcode owning an uncertain activity is idle; unset keeps the manual acknowledgement only.
    var confirmsXcodeIdle: ((BuildActivity) async -> Bool)?
    private var unknownResolver: Task<Void, Never>?
    var terminalOutput: ((UUID, Data) -> Void)?
    private var terminalOwner: UUID?
    struct Admission: Codable { let project: ProjectContext; let parameters: BuildParameters; let source: String; var record: BuildActivity? = nil }

    init(directory: URL, helper: URL, defaults: UserDefaults, inspect: @escaping @Sendable (ProjectContext) async throws -> ProjectContext = { project in
        try await Task.detached { try EnvironmentInspector.project(path: project.path, developerDirectory: project.developerDirectory, appleTarget: project.appleTarget) }.value
    }, resolveDeveloper: @escaping @Sendable (ProjectContext) async throws -> String = { project in
        let directory: String
        if let selected = project.developerDirectory { directory = selected } else { directory = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1 }.value }
        guard !directory.isEmpty else { throw BuildError.configuration }; return directory
    }, makeCommand: @escaping @Sendable (BuildActivity, String?) throws -> CommandSpec = { record, resultPath in
        var project = record.project; project.developerDirectory = record.selectedDeveloperDirectory
        let base = resultPath.map { URL(fileURLWithPath: $0).deletingPathExtension().path }
        return try record.parameters.command(project: project, resultBundlePath: resultPath, derivedDataPath: record.compilationDerivedDataPath ?? record.preparedDerivedDataPath ?? base.map { $0 + "-DerivedData" }, enumerationPath: base.map { $0 + ".tests.json" })
    }, makeStageCommand: @escaping @Sendable (BuildActivity, BuildStage, CommandSpec) throws -> CommandSpec = { _, _, command in command }, discover: (@Sendable (ProjectContext, String, Bool, String?, String?) async throws -> BuildCatalogue)? = nil,
       validateSelection: (@Sendable (ProjectContext, String, Bool, String?, String?) async throws -> BuildCatalogue)? = nil, discoveryService: BuildDiscovery = .shared) {
        self.store = BuildHistoryStore(directory: directory); self.helper = helper; self.defaults = defaults; self.inspect = inspect
        self.discoveryService = discoveryService
        self.usesDiscoveryService = discover == nil
        self.discover = discover ?? { project, scheme, tests, id, revision in try await discoveryService.catalogue(project: project, scheme: scheme, includeTestPlans: tests, profileID: id, profileRevision: revision) };
        self.presentationDiscover = discover ?? { project, scheme, tests, id, revision in try await discoveryService.catalogue(project: project, scheme: scheme, includeTestPlans: tests, profileID: id, profileRevision: revision, useCache: true) }
        self.validateSelection = validateSelection ?? discover ?? { project, scheme, tests, id, revision in try await discoveryService.selectionCatalogue(project: project, scheme: scheme, includeTestPlans: tests, profileID: id, profileRevision: revision) }
        self.resolveDeveloper = resolveDeveloper; self.makeCommand = makeCommand; self.makeStageCommand = makeStageCommand
        do {
            records = try store.load()
            let path = store.directory.appendingPathComponent("requests.json")
            if FileManager.default.fileExists(atPath: path.path) { ledger = try JSONDecoder().decode([String: Admission].self, from: Data(contentsOf: path)) }
            for record in records { ledger[record.id.uuidString]?.record = record }
            try store.save(records, retainedIDs: Set(ledger.keys))
        } catch { message = text("history.error") }
    }
    /// Preflight awaits happen before a queued record exists; development replacement must wait for them too.
    @Published private(set) var admittingCount = 0
    var busy: Bool { launchID != nil || records.contains { $0.status == .unknown && $0.queueReleased != true } }
    var hasPending: Bool { busy || records.contains { $0.status.isPending } }
    var next: BuildActivity? { records.filter { $0.status == .queued }.min { $0.createdAt < $1.createdAt } }
    var active: BuildActivity? { records.first { $0.id == launchID } }
    var pendingCount: Int { records.filter { $0.status == .queued }.count }
    var overlayActivity: BuildActivity? { active ?? records.last { $0.startedAt != nil } }
    /// History is immutable presentation input; viewing a failure only changes its durable acknowledgement.
    func panelActivity(project: ProjectContext) -> BuildActivity? {
        let scoped = records.filter { $0.project == project }
        if let pending = scoped.first(where: { $0.status == .running || $0.status == .preparing }) ?? scoped.first(where: { $0.status == .queued }) { return pending }
        if let unknown = scoped.last(where: { $0.status == .unknown && $0.queueReleased != true }) { return unknown }
        guard let failure = scoped.last(where: { [.failed, .interrupted, .unknown].contains($0.status) }),
              defaults.string(forKey: failureViewedKey(project)) != failure.id.uuidString else { return nil }
        return failure
    }
    var panelActivity: BuildActivity? { currentProject().flatMap { panelActivity(project: $0) } }
    private func failureViewedKey(_ project: ProjectContext) -> String {
        "build.failureViewed." + project.path + "|" + project.branch + "|" + (project.appleTarget?.path ?? "")
    }
    func markResultViewed(_ id: UUID) {
        guard let record = activity(id), [.failed, .interrupted, .unknown].contains(record.status),
              records.last(where: { $0.project == record.project && [.failed, .interrupted, .unknown].contains($0.status) })?.id == id else { return }
        defaults.set(id.uuidString, forKey: failureViewedKey(record.project)); revision = UUID()
    }
    var panelBusy: Bool { manualSubmitting || admittingCount > 0 || records.contains { $0.project == currentProject() && ($0.status.isPending || $0.status == .unknown && $0.queueReleased != true) } }
    var draftCompatible: Bool {
        return catalogueContext == currentProject() && catalogueScheme == draft.scheme && (try? catalogue.validate(draftFor(.build))) != nil
    }
    var testsCompatible: Bool {
        guard catalogueContext == currentProject(), draft.testTarget != nil else { return false }
        let parameters = draftFor(.test)
        return (try? parameters.validate()) != nil && (try? catalogue.validate(parameters)) != nil
    }
    var availableTests: BuildTestCatalogue? {
        guard let project = currentProject() else { return nil }
        return testCatalogue(project: project, parameters: draft, developer: catalogueDeveloper)
    }

    /// Compact actions use the same draft and admission ledger; opening a picker never submits work.
    func draftFor(_ operation: BuildOperation, intent: BuildIntent? = nil) -> BuildParameters {
        var parameters = draft; parameters.operation = operation; parameters.intent = intent
        parameters.backend = .cli; parameters.workspaceTab = ""
        parameters.platform = catalogue.destinations.first { $0.id == parameters.destinationID }?.platform
        if operation == .test, let target = parameters.testTarget {
            parameters.backend = .cli; parameters.workspaceTab = ""; parameters.testIdentifiers = []
            parameters.testPlan = catalogue.testTargets?.first(where: { $0.name == target })?.testPlan ?? parameters.testPlan
        }
        if operation == .build { parameters.testTarget = nil; parameters.testIdentifiers = []; if intent != .catalogue { parameters.testPlan = "" } }
        if parameters.backend == .xcodeMCP, intent != .run { parameters.scheme = ""; parameters.configuration = ""; parameters.destinationID = ""; parameters.testPlan = ""; parameters.platform = nil }
        if intent == .run { parameters.backend = .xcodeMCP; parameters.workspaceTab = "" }
        return parameters
    }
    func perform(_ operation: BuildOperation = .build, intent: BuildIntent? = nil) {
        guard !panelBusy, let project = currentProject() else { return }
        manualSubmitting = true
        saveDraft(project: project)
        Task {
            defer { manualSubmitting = false }
            do {
                if self.draft.backend == .cli && (self.catalogueContext != project || self.catalogueScheme != self.draft.scheme) {
                    await self.refreshCatalogue(project: project)
                }
                let parameters = self.draftFor(operation, intent: intent)
                try parameters.validate()
                if parameters.backend == .cli, try await resolveDeveloper(project) != catalogueDeveloper {
                    await refreshCatalogue(project: project); throw BuildError.configuration
                }
                _ = try await submit(id: UUID(), project: project, parameters: parameters, source: "Mimic", simulatorConfirmed: parameters.backend == .xcodeMCP && (parameters.intent == .run || xcodeSimulatorConfirmed))
            }
            catch { message = text("build.error." + ((error as? BuildError)?.rawValue ?? "unavailable")) }
        }
    }
    func chooseProduct(_ productID: String, activityID: UUID) throws {
        guard launchID == activityID, active?.stage == .products, let product = active?.products?.first(where: { $0.id == productID }), let choice = productChoice else { throw BuildError.context }
        productChoice = nil; update(activityID) { $0.selectedProductID = productID }; choice.resume(returning: product)
    }
    var selected: BuildActivity? { records.first { $0.id == selectedID } }
    func lastLines(_ id: UUID) -> [String] {
        let interval = signposter.beginInterval("Tail")
        defer { signposter.endInterval("Tail", interval) }
        if let output = outputs[id] { return output.lastLines }
        if let tail = savedTails[id] { return tail }
        let tail = BuildOutput.savedTail(output(id))
        savedTails[id] = tail; return tail
    }
    func output(_ id: UUID) -> Data {
        if let output = outputs[id] { return output.bytes }
        guard let handle = FileHandle(forReadingAtPath: store.logURL(id).path) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        let bytes = (try? handle.readToEnd()) ?? Data()
        return Data(BuildOutput.slice(bytes, after: 0, limit: bytes.count).text.utf8)
    }

    // MARK: - Configuration and admission

    /// Startup and checkout selection restore saved data before validating the catalogue in the background.
    func preloadCatalogue(project: ProjectContext) {
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            guard let self, !self.stopped else { return }
            await self.restoreDraft(project: project)
            guard !Task.isCancelled, self.currentProject() == project, self.draft.backend == .cli else { return }
            await self.refreshCatalogue(project: project)
        }
    }

    /// View creation only restores local preferences. Discovery reuses unchanged saved metadata.
    func refreshCatalogue(project: ProjectContext, scheme: String? = nil, includeTestPlans: Bool = false, force: Bool = false) async {
        let chosen = scheme ?? draft.scheme
        let profile = currentProfile().map { $0.id + ":" + $0.revision } ?? ""
        if let request = presentationRequest, request.profile == profile, request.project == project, request.scheme == chosen, request.tests == includeTestPlans {
            await request.task.value; return
        }
        let task = Task { await self.loadCatalogue(project: project, scheme: scheme, includeTestPlans: includeTestPlans, force: force) }
        presentationRequest = (profile, project, chosen, includeTestPlans, task)
        await task.value
        if presentationRequest?.profile == profile, presentationRequest?.project == project, presentationRequest?.scheme == chosen, presentationRequest?.tests == includeTestPlans { presentationRequest = nil }
    }

    private func loadCatalogue(project: ProjectContext, scheme: String?, includeTestPlans: Bool, force: Bool) async {
        let token = UUID(), profile = currentProfile(); catalogueRevision = token; loading = true; message = ""
        catalogueProgress = .init()
        var progressMonitor: Task<Void, Never>?
        defer { progressMonitor?.cancel(); if catalogueRevision == token { loading = false; catalogueProgress = nil } }
        do {
            let developer = try await resolveDeveloper(project)
            let key = "build.configuration." + project.path + "|" + developer
            guard catalogueRevision == token, currentProject() == project, currentProfile() == profile else { return }
            if draftKey != key {
                draftKey = key
                draft = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BuildParameters.self, from: $0) } ?? .init()
                if defaults.data(forKey: key + ".selectionContext").flatMap({ try? JSONDecoder().decode(ProjectContext.self, from: $0) }) != project { draft.testIdentifiers = [] }
            }
            let chosen = scheme ?? draft.scheme
            var captured = project; captured.developerDirectory = developer
            let tests = true
            if usesDiscoveryService {
                progressMonitor = Task { [captured] in
                    while !Task.isCancelled {
                        let progress = await discoveryService.progress(project: captured, scheme: chosen, includeTestPlans: tests, profileID: profile?.id, profileRevision: profile?.revision)
                        guard !Task.isCancelled, catalogueRevision == token, currentProject() == project, currentProfile() == profile else { return }
                        if let progress, catalogueProgress != progress { catalogueProgress = progress }
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    }
                }
            }
            let result = try await (force ? discover : presentationDiscover)(captured, chosen, true, profile?.id, profile?.revision)
            guard catalogueRevision == token, currentProject() == project, currentProfile() == profile else { return }
            let cached = await discoveryService.cachedCatalogue(project: captured, scheme: chosen, includeTestPlans: true, profileID: profile?.id, profileRevision: profile?.revision)
            guard catalogueRevision == token, currentProject() == project, currentProfile() == profile else { return }
            catalogueLoadedAt = cached?.loadedAt ?? Date(); catalogue = result; catalogueContext = project; catalogueScheme = chosen; catalogueDeveloper = developer
            if let targets = result.testTargets, !targets.contains(where: { $0.name == draft.testTarget }) { draft.testTarget = targets.first?.name }
            if !result.schemes.contains(draft.scheme) { draft.scheme = "" }
            if !result.configurations.contains(draft.configuration) { draft.configuration = result.configurations.contains("Debug") ? "Debug" : "" }
            if !result.destinations.contains(where: { $0.id == draft.destinationID }) { draft.destinationID = "" }
            if includeTestPlans || draft.operation == .test, !result.testPlans.contains(draft.testPlan) { if !draft.testPlan.isEmpty { draft.testIdentifiers = [] }; draft.testPlan = "" }
        } catch { if catalogueRevision == token { message = text("build.error." + ((error as? BuildError)?.rawValue ?? "catalogue")) } }
        if catalogueRevision == token { loading = false }
    }
    func restoreDraft(project: ProjectContext) async {
        let profile = currentProfile().map { $0.id + ":" + $0.revision } ?? ""
        guard restoredContext != project || restoredProfile != profile else { return }
        presentationRequest = nil
        restoredContext = project; restoredProfile = profile
        catalogueLoadedAt = nil
        catalogueRevision = UUID(); loading = false; catalogueProgress = nil; catalogueContext = nil; catalogue = .init(); xcodeSimulatorConfirmed = false
        guard let developer = try? await resolveDeveloper(project), currentProject() == project, restoredProfile == profile else { return }
        let key = "build.configuration." + project.path + "|" + developer; draftKey = key
        draft = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BuildParameters.self, from: $0) } ?? .init()
        draft.backend = .cli; draft.workspaceTab = ""
        if defaults.data(forKey: key + ".selectionContext").flatMap({ try? JSONDecoder().decode(ProjectContext.self, from: $0) }) != project { draft.testIdentifiers = [] }
        var captured = project; captured.developerDirectory = developer
        let cached = await discoveryService.cachedCatalogue(project: captured, scheme: draft.scheme, profileID: currentProfile()?.id, profileRevision: currentProfile()?.revision)
        guard currentProject() == project, restoredProfile == profile else { return }
        if let cached { if let targets = cached.value.testTargets, !targets.contains(where: { $0.name == draft.testTarget }) { draft.testTarget = targets.first?.name }; catalogue = cached.value; catalogueLoadedAt = cached.loadedAt; catalogueContext = project; catalogueScheme = draft.scheme; catalogueDeveloper = developer }
    }
    func saveDraft(project: ProjectContext) {
        guard currentProject() == project, let key = draftKey else { return }
        defaults.set(try? JSONEncoder().encode(draft), forKey: key)
        defaults.set(try? JSONEncoder().encode(project), forKey: key + ".selectionContext")
    }
    func testCatalogue(project: ProjectContext, parameters: BuildParameters, developer: String) -> BuildTestCatalogue? {
        records.reversed().compactMap(\.testCatalogue).first { $0.matches(project: project, parameters: parameters, developer: developer) }
    }
    func panelDraft(project: ProjectContext, developer: String) -> BuildParameters {
        let key = "build.configuration." + project.path + "|" + developer
        var value = currentProject() == project && draftKey == key ? draft : defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BuildParameters.self, from: $0) } ?? .init()
        let savedContext = defaults.data(forKey: key + ".selectionContext").flatMap { try? JSONDecoder().decode(ProjectContext.self, from: $0) }
        if savedContext != project { value.testIdentifiers = [] }
        value.intent = nil; value.backend = .cli; value.workspaceTab = ""
        return value
    }
    func savePanelDraft(_ parameters: BuildParameters, project: ProjectContext, developer: String) {
        let key = "build.configuration." + project.path + "|" + developer
        defaults.set(try? JSONEncoder().encode(parameters), forKey: key)
        defaults.set(try? JSONEncoder().encode(project), forKey: key + ".selectionContext")
        if currentProject() == project { draftKey = key; draft = parameters }
    }
    func submitDraft() {
        guard let project = currentProject() else { return }
        var parameters = draft
        parameters.platform = catalogue.destinations.first(where: { $0.id == parameters.destinationID })?.platform
        if parameters.backend == .xcodeMCP { parameters.scheme = ""; parameters.configuration = ""; parameters.destinationID = ""; parameters.testPlan = "" }
        if parameters.operation == .build { parameters.testIdentifiers = []; parameters.testPlan = "" }
        saveDraft(project: project)
        Task {
            do { _ = try await submit(id: UUID(), project: project, parameters: parameters, source: "Mimic", simulatorConfirmed: xcodeSimulatorConfirmed) }
            catch { message = text("build.error." + ((error as? BuildError)?.rawValue ?? "unavailable")) }
        }
    }
    /// Ledger survives history eviction. A known ID can never start a second operation.
    func submit(id: UUID, project: ProjectContext, parameters: BuildParameters, source: String, simulatorConfirmed: Bool = false, workflowID: String? = nil, sourceRevision: SourceRevision? = nil, selectionID: UUID? = nil, cleanupArtifacts: [ManagedArtifact]? = nil, cleanupActivityID: UUID? = nil, expectedCases: [String: [String]]? = nil) async throws -> BuildActivity {
        let admittedProfile = currentProfile()
        self.admittingCount += 1
        defer { self.admittingCount -= 1 }
        try parameters.validate()
        if let workflowID {
            guard UUID(uuidString: workflowID) != nil else { throw BuildError.arguments }
        }
        guard parameters.backend != .cli || !simulatorConfirmed else { throw BuildError.arguments }
        if let admission = ledger[id.uuidString] {
            guard admission.project == project, admission.parameters == parameters, admission.record?.workflowID == workflowID, admission.record?.selectionID == selectionID, admission.record?.cleanupArtifacts == cleanupArtifacts, admission.record?.cleanupActivityID == cleanupActivityID, admission.record?.requestedTestCases == expectedCases, sourceRevision == nil || admission.record?.sourceProvenance?.admitted == sourceRevision else { throw BuildError.duplicate }
            guard let record = records.first(where: { $0.id == id }) ?? admission.record else { throw BuildError.stopped }; return record
        }
        guard !stopped, mayAdmit(), accepts(project) else { throw BuildError.context }
        let actual = try await inspect(project)
        let developer = try await resolveDeveloper(project)
        guard actual == project, accepts(project), mayAdmit(), !stopped else { throw BuildError.context }
        // Re-check after suspension: simultaneous callers may already have admitted this ID.
        if ledger[id.uuidString] != nil { return try await submit(id: id, project: project, parameters: parameters, source: source, simulatorConfirmed: simulatorConfirmed, workflowID: workflowID, sourceRevision: sourceRevision, selectionID: selectionID, cleanupArtifacts: cleanupArtifacts, cleanupActivityID: cleanupActivityID, expectedCases: expectedCases) }
        if let blocker = readinessBlocker(project: project, parameters: parameters, simulatorConfirmed: simulatorConfirmed) { throw blocker }
        if parameters.intent != .cleanup { try await checkPreparation(project, parameters) }
        let exclusions = admittedProfile?.profile.sourceExclusions ?? []
        let revision = try? await Task.detached { try SourceRevisionReader.capture(path: project.path, exclusions: exclusions) }.value
        guard sourceRevision == nil || revision == sourceRevision else { throw BuildError.sourceChanged }
        guard accepts(project), mayAdmit(), !stopped, currentProfile() == admittedProfile else { throw BuildError.context }
        if ledger[id.uuidString] != nil { return try await submit(id: id, project: project, parameters: parameters, source: source, simulatorConfirmed: simulatorConfirmed, workflowID: workflowID, sourceRevision: sourceRevision, selectionID: selectionID, cleanupArtifacts: cleanupArtifacts, cleanupActivityID: cleanupActivityID, expectedCases: expectedCases) }
        var record = BuildActivity(id: id, project: project, parameters: parameters, source: source)
        record.sourceProvenance = SourceProvenance(admitted: revision); record.sourceExclusions = exclusions; record.selectionID = selectionID; record.strictSource = sourceRevision != nil; record.requestedTestCases = expectedCases
        record.cleanupArtifacts = cleanupArtifacts; record.cleanupActivityID = cleanupActivityID
        if parameters.backend == .cli, parameters.intent != .cleanup {
            record.compilationDerivedDataPath = try BuildCompilationCache.directory(root: store.directory, project: project, developer: developer, parameters: parameters, profileRevision: admittedProfile?.revision).path
        }
        if parameters.operation == .test, parameters.backend == .cli, let prepared = records.last(where: { $0.testCatalogue?.matches(project: project, parameters: parameters, developer: developer) == true && revision != nil && $0.sourceProvenance?.finished == revision && $0.sourceProvenance?.stability == "unchangedObserved" }) {
            let path = prepared.compilationDerivedDataPath ?? store.directory.appendingPathComponent(prepared.id.uuidString + "-DerivedData").path
            if FileManager.default.fileExists(atPath: path) { record.preparedDerivedDataPath = path }
        }
        record.destinationName = catalogue.destinations.first { $0.id == parameters.destinationID }?.name
        record.workflowID = workflowID; record.stateRevision = 1
        record.selectedDeveloperDirectory = developer; record.profileID = admittedProfile?.id; record.profileRevision = admittedProfile?.revision
        ledger[id.uuidString] = Admission(project: project, parameters: parameters, source: source, record: record)
        do {
            let path = store.directory.appendingPathComponent("requests.json")
            try JSONEncoder().encode(ledger).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch { ledger[id.uuidString] = nil; throw error }
        records.append(record)
        do { try store.save(records) } catch {
            records.removeAll { $0.id == id }; ledger[id.uuidString] = nil
            try? JSONEncoder().encode(ledger).write(to: store.directory.appendingPathComponent("requests.json"), options: .atomic)
            throw error
        }
        schedule(); return records.first { $0.id == id } ?? record
    }

    // MARK: - Execution

    func start(_ record: BuildActivity) {
        guard !busy, !stopped, record.status == .queued else { return }
        launchID = record.id; update(record.id) { $0.status = .preparing; $0.phase = "build.phase.preparing" }; persist()
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                if record.parameters.intent != .cleanup { try await checkPreparation(record.project, record.parameters) }
                let actual = try await inspect(record.project)
                let developer = try await resolveDeveloper(record.project)
                guard !Task.isCancelled, launchID == record.id else { return }
                guard actual == record.project, accepts(record.project), developer == record.selectedDeveloperDirectory else { throw BuildError.context }
                if record.parameters.intent == .cleanup {
                    try await observeStart(record); try await begin(record); try await performManagedCleanup(record)
                    await finish(record.id, status: .succeeded); return
                }
                if record.parameters.backend == .cli {
                    var captured = record.project; captured.developerDirectory = record.selectedDeveloperDirectory
                    let catalog = try await validateSelection(captured, record.parameters.scheme, record.parameters.operation == .test || record.parameters.intent == .catalogue, record.profileID, record.profileRevision)
                    guard !Task.isCancelled, launchID == record.id else { return }
                    try catalog.validate(record.parameters)
                    try await verifyStartContext(record)
                    try await observeStart(record)
                    try await launchCLI(record)
                } else if record.parameters.intent == .run {
                    try await verifyStartContext(record)
                    try await observeStart(record); try await launchXcodeRun(record)
                } else { try await observeStart(record); try await launchXcode(record) }
            } catch {
                guard launchID == record.id else { return }
                let started = records.first { $0.id == record.id }?.startedAt != nil
                let remoteStarted = active?.xcodeRequestID != nil
                let failure = error as? XcodeRunFailure
                // Xcode's explicit build failure is a known outcome even after the remote request started.
                let status: BuildStatus = Task.isCancelled && (!started || record.parameters.intent == .run && !remoteStarted) ? .cancelled : failure?.buildFailed == true ? .failed : started && record.parameters.backend == .xcodeMCP && (record.parameters.intent != .run || remoteStarted) ? .unknown : .failed
                // The failed step and Xcode's own error text are the diagnostic; the public code stays coarse.
                if let failure, started { await consume(record.id, bytes: Data((failure.summary + "\n" + (failure.issues.isEmpty ? "" : failure.issues + "\n")).utf8)) }
                let code: String? = failure?.buildFailed == true ? nil : failure?.code.rawValue ?? (error as? BuildError)?.rawValue ?? "unavailable"
                await finish(record.id, status: status, error: active?.xcodeCancellationRequested == true ? "xcodeCancellationUnconfirmed" : status == .cancelled ? nil : code)
            }
        }
    }
    private func verifyStartContext(_ record: BuildActivity) async throws {
        let actual = try await inspect(record.project)
        let developer = try await resolveDeveloper(record.project)
        guard !Task.isCancelled, launchID == record.id, actual == record.project, accepts(record.project), developer == record.selectedDeveloperDirectory else { throw BuildError.context }
    }
    /// Strict checks bind admission to execution; legacy calls still record provenance without inventing it.
    private func observeStart(_ record: BuildActivity) async throws {
        let revision = try? await Task.detached { try SourceRevisionReader.capture(path: record.project.path, exclusions: record.sourceExclusions ?? []) }.value
        guard launchID == record.id, !Task.isCancelled else { throw CancellationError() }
        if record.selectionID != nil || record.strictSource == true {
            guard revision != nil, revision == record.sourceProvenance?.admitted else { throw BuildError.sourceChanged }
        }
        let snapshot = try? await Task.detached { try GitActivitySnapshot.capture(path: record.project.path) }.value
        guard launchID == record.id, !Task.isCancelled else { throw CancellationError() }
        changeSnapshots[record.id] = snapshot
        update(record.id) { $0.sourceProvenance?.started = revision; $0.sourceProvenance?.observe(revision) }
        sourceMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                let next = try? await Task.detached { try SourceRevisionReader.capture(path: record.project.path, exclusions: record.sourceExclusions ?? []) }.value
                guard !Task.isCancelled, let self, self.launchID == record.id else { return }
                self.update(record.id) { $0.sourceProvenance?.observe(next) }; self.persist()
            }
        }
    }
    private func begin(_ record: BuildActivity) async throws {
        outputs[record.id] = BuildOutput()
        let worker = BuildOutputWorker()
        try await worker.open(store.logURL(record.id))
        guard launchID == record.id, !Task.isCancelled else { throw CancellationError() }
        workers[record.id] = worker
        update(record.id) { $0.status = .running; $0.startedAt = Date(); $0.stage = record.parameters.intent == .cleanup ? .cleanup : record.parameters.intent == .catalogue ? .catalogue : .compilation; $0.phase = record.parameters.intent == .cleanup ? "build.phase.cleanup" : record.parameters.intent == .catalogue ? "build.phase.catalogue" : "build.phase.running" }; persist()
    }
    private func launchCLI(_ record: BuildActivity) async throws {
        let resultPath = store.directory.appendingPathComponent(record.id.uuidString + ".xcresult").path
        var command = try makeCommand(record, resultPath)
        try await begin(record)
        if record.strictSource == true {
            let current = try? await Task.detached { try SourceRevisionReader.capture(path: record.project.path, exclusions: record.sourceExclusions ?? []) }.value
            guard current != nil, current == record.sourceProvenance?.admitted else { throw BuildError.sourceChanged }
            try await verifyStartContext(record)
        }
        guard !Task.isCancelled, launchID == record.id else { throw CancellationError() }
        if let stream = try? BuildEventStream() {
            if let observed = stream.attaching(to: command) {
                command = observed; buildEvents = stream
                buildEventsMonitor = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.launchID == record.id, self.active?.hasPrivateInput != true else { return }
                        if let progress = stream.snapshot, self.active?.executionProgress != progress {
                            self.update(record.id) { $0.executionProgress = progress }
                        }
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    }
                }
            } else { stream.stop() }
        }
        let runner = PTYSession(); session = runner
        runner.onOutputAsync = { [weak self] in await self?.consume(record.id, bytes: $0) }
        runner.onCompletion = { [weak self] event in
            guard let self, self.launchID == record.id else { return }
            continuationTask = Task {
            await finishBuildEvents(record.id)
            guard self.launchID == record.id else { return }
            update(record.id) { $0.exitCode = event?.code; $0.signal = event?.signal; if FileManager.default.fileExists(atPath: resultPath) { $0.resultBundlePath = resultPath } }
            let status: BuildStatus = event?.cancelled == true ? .cancelled : event?.code == 0 && event?.signal == 0 && event?.launchError == 0 ? .succeeded : .failed
            guard status == .succeeded, record.parameters.intent != nil else { await finish(record.id, status: status, error: status == .failed && record.parameters.intent != nil ? "stage." + (record.parameters.intent == .catalogue ? "catalogue" : "compilation") : nil); return }
            do {
                try await completeWorkflow(record, resultPath: resultPath)
                try Task.checkCancellation()
                await finish(record.id, status: .succeeded)
                if record.parameters.intent == .run { showSimulator(record) }
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                await finish(record.id, status: cancelled ? .cancelled : .failed, error: cancelled ? nil : "stage." + (active?.stage?.rawValue ?? "compilation"))
            }
            }
        }
        try runner.start(helper: helper, command: command)
    }

    // MARK: - Private panel workflows

    /// Queue ownership covers product selection too; cancelling a picker releases its suspended continuation.
    private func completeWorkflow(_ record: BuildActivity, resultPath: String) async throws {
        try await verifyStartContext(record)
        let base = URL(fileURLWithPath: resultPath).deletingPathExtension().path
        if record.parameters.intent == .catalogue {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: base + ".tests.json")); defer { try? handle.close() }
            let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 16 * 1024 * 1024 else { throw BuildError.catalogueResponse }
            let tests = try BuildTestCatalogue.parse(data)
            try await verifyStartContext(record)
            let catalogue = BuildTestCatalogue(project: record.project, developerDirectory: record.selectedDeveloperDirectory ?? "", parameters: record.parameters, tests: tests)
            update(record.id) { $0.testCatalogue = catalogue; $0.completedStages = 1 }; persist(); return
        }
        update(record.id) { $0.completedStages = 1; $0.stage = .products; $0.phase = "build.phase.products" }; persist()
        var project = record.project; project.developerDirectory = record.selectedDeveloperDirectory
        let derived = record.compilationDerivedDataPath ?? base + "-DerivedData"
        let build = try record.parameters.command(project: project, derivedDataPath: derived)
        let settings = CommandSpec(executable: build.executable, arguments: Array(build.arguments.dropLast()) + ["-showBuildSettings", "-json"], directory: build.directory, environment: build.environment)
        let raw = try await workflowCommand(record, command: settings)
        let output = String(decoding: raw, as: UTF8.self)
        let products = try BuildProduct.parse(output: output, derivedData: URL(fileURLWithPath: derived))
        try await verifyStartContext(record)
        update(record.id) { $0.products = products }; persist()
        let product: BuildProduct
        if products.count == 1 { product = products[0] }
        else { product = try await withCheckedThrowingContinuation { productChoice = $0 } }
        try await verifyStartContext(record)
        let info = try Data(contentsOf: URL(fileURLWithPath: product.path).appendingPathComponent("Info.plist"))
        guard let dictionary = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any], dictionary["CFBundleIdentifier"] as? String == product.bundleIdentifier else { throw BuildError.configuration }
        update(record.id) { $0.selectedProductID = product.id; $0.stage = .installation; $0.phase = "build.phase.installation" }; persist()
        func simctl(_ arguments: [String]) -> CommandSpec { .init(executable: "/usr/bin/xcrun", arguments: ["simctl"] + arguments, directory: project.path, environment: EnvironmentInspector.environment(project: project)) }
        _ = try await workflowCommand(record, command: simctl(["boot", record.parameters.destinationID]), acceptedCodes: [0, 149])
        _ = try await workflowCommand(record, command: simctl(["bootstatus", record.parameters.destinationID, "-b"]))
        _ = try await workflowCommand(record, command: simctl(["install", record.parameters.destinationID, product.path]))
        try await verifyStartContext(record)
        update(record.id) { $0.completedStages = 2; $0.stage = .launch; $0.phase = "build.phase.launch" }; persist()
        _ = try await workflowCommand(record, command: simctl(["launch", record.parameters.destinationID, product.bundleIdentifier]))
        try await verifyStartContext(record)
        update(record.id) { $0.completedStages = 3 }
    }

    private func workflowCommand(_ record: BuildActivity, command: CommandSpec, acceptedCodes: Set<Int> = [0]) async throws -> Data {
        try Task.checkCancellation()
        guard launchID == record.id else { throw CancellationError() }
        let command = try makeStageCommand(record, active?.stage ?? .compilation, command)
        let runner = PTYSession(); session = runner
        var captured = Data()
        var overflow = false, timedOut = false
        var deadline: Task<Void, Never>?
        defer { deadline?.cancel() }
        runner.onOutputAsync = { [weak self] bytes in
            if captured.count + bytes.count > 4 * 1024 * 1024 { overflow = true }
            if captured.count < 4 * 1024 * 1024 { captured.append(bytes.prefix(4 * 1024 * 1024 - captured.count)) }
            await self?.consume(record.id, bytes: bytes)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runner.onCompletion = { event in
                    if timedOut { continuation.resume(throwing: BuildError.catalogueTimeout) }
                    else if overflow { continuation.resume(throwing: BuildError.catalogueResponse) }
                    else if event?.cancelled == true { continuation.resume(throwing: CancellationError()) }
                    else if let code = event?.code, acceptedCodes.contains(code), event?.signal == 0, event?.launchError == 0 { continuation.resume(returning: captured) }
                    else { continuation.resume(throwing: BuildError.unavailable) }
                }
                do {
                    try runner.start(helper: helper, command: command)
                    if active?.stage == .products {
                        deadline = Task { try? await Task.sleep(for: .seconds(120)); guard !Task.isCancelled else { return }; timedOut = true; runner.cancel() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { Task { @MainActor in runner.cancel() } }
    }
    private func launchXcode(_ record: BuildActivity) async throws {
        try await xcode.refreshWindows()
        try await verifyStartContext(record)
        guard xcode.project == record.project, xcode.developerDirectory == record.selectedDeveloperDirectory, xcode.hasWorkspace(record.parameters.workspaceTab, path: record.project.workspace), xcode.supports(record.parameters.operation) else { throw BuildError.configuration }
        try await begin(record)
        update(record.id) { $0.tracking = .unavailable }
        let result = try await xcode.run(record, requestStarted: { [weak self] requestID in self?.update(record.id) { $0.xcodeRequestID = requestID }; self?.persist() }, progress: { [weak self] message in
            guard let self, self.launchID == record.id else { return }
            if self.active?.tracking != .live { update(record.id) { $0.tracking = .live } }
            await consume(record.id, bytes: Data((message + "\n").utf8))
        })
        await consume(record.id, bytes: Data((result.text + "\n").utf8))
        update(record.id) { $0.errorCount = result.errors; $0.warningCount = result.warnings; $0.resultSummaryPath = result.summaryPath; $0.truncated = result.truncated }
        await finish(record.id, status: result.status)
    }
    private func launchXcodeRun(_ record: BuildActivity) async throws {
        try await begin(record)
        let result = try await xcode.runWithDebugger(record, requestStarted: { [weak self] requestID in
            self?.update(record.id) { $0.xcodeRequestID = requestID }; self?.persist()
        }, progress: { [weak self] progress in
            guard let self, self.launchID == record.id, self.active?.stage == .compilation else { return }
            self.update(record.id) {
                var value = progress
                if value.fraction == nil { value.fraction = $0.executionProgress?.fraction }
                if value.operation == nil { value.operation = $0.executionProgress?.operation }
                $0.executionProgress = value
            }
        }, authorize: { [weak self] in
            guard let self else { throw BuildError.stopped }
            try Task.checkCancellation(); try await self.verifyStartContext(record)
        }, stage: { [weak self] stage, completed in
            guard let self, self.launchID == record.id else { return }
            self.update(record.id) { $0.stage = stage; $0.completedStages = completed; $0.phase = "build.phase." + stage.rawValue }
        }, phase: { [weak self] key in
            guard let self, self.launchID == record.id else { return }
            self.update(record.id) { $0.phase = key }
        })
        guard active?.xcodeCancellationRequested != true else { throw BuildError.stopped }
        try await verifyStartContext(record)
        update(record.id) { $0.completedStages = 3; $0.debuggerProcessID = result.processID; $0.debuggerAttached = true }
        await consume(record.id, bytes: Data((result.detail + "\n").utf8))
        await finish(record.id, status: .succeeded)
        showSimulator(record)
    }
    private func consume(_ id: UUID, bytes: Data, final: Bool = false) async {
        guard let worker = workers[id] else { return }
        let prompt = String(decoding: bytes.suffix(4096), as: UTF8.self)
        if prompt.range(of: #"(?i)(?:password|passphrase|verification code|enter[^\n]{0,80}|\[y/n\]|\(y/n\))[:? >]\s*$"#, options: .regularExpression) != nil { update(id) { $0.needsInput = true } }
        // Pipe chunks are <=64 KiB. Large MCP results are sliced before UI delivery.
        var offset = 0
        repeat {
            let end = min(bytes.count, offset + 64 * 1024)
            let batch = await worker.append(Data(bytes[offset..<end]), final: final && end == bytes.count)
            guard launchID == id else { return }
            outputs[id] = batch.output
            if let record = active, record.id == id, record.parameters.operation == .test {
                var progress = testProgress[id] ?? BuildTestProgress()
                let count = progress.append(String(decoding: batch.emitted, as: UTF8.self), selected: record.parameters.testIdentifiers)
                testProgress[id] = progress
                if count > 0 { update(id) { $0.completedTestCount = count } }
            }
            if batch.logTruncated { logTruncation.insert(id) }
            if batch.logFailed { message = text("log.error") }
            renderBatch.append(batch.emitted)
            if renderBatch.count > 512 * 1024 {
                let tail = BuildOutput.slice(renderBatch, after: renderBatch.count - 512 * 1024, limit: 512 * 1024)
                renderBatch = Data(tail.text.utf8); logTruncation.insert(id)
            }
            if updateTimer == nil {
                updateTimer = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.launchID == id else { return }
                    self.deliverOutput(id)
                    if self.active?.stage == .compilation, let phase = self.outputs[id]?.phase, self.active?.phase != "build.phase." + phase {
                        self.signposter.emitEvent("PhaseChanged")
                        self.update(id) { $0.phase = "build.phase." + phase }
                    }
                    self.revision = UUID(); self.updateTimer = nil
                }
            }
            offset = end
        } while offset < bytes.count
    }
    private func deliverOutput(_ id: UUID) {
        let interval = signposter.beginInterval("UIBatch")
        defer { signposter.endInterval("UIBatch", interval) }
        var cursor = 0
        while cursor < renderBatch.count {
            let slice = BuildOutput.slice(renderBatch, after: cursor)
            terminalOutput?(id, Data(slice.text.utf8)); cursor = slice.nextCursor
        }
        renderBatch.removeAll(keepingCapacity: true)
    }
    /// The activity, rather than any visible card, owns the event channel through process exit.
    private func finishBuildEvents(_ id: UUID) async {
        guard launchID == id else { return }
        buildEventsMonitor?.cancel(); buildEventsMonitor = nil
        let stream = buildEvents; buildEvents = nil
        let progress = await stream?.finish()
        guard launchID == id, active?.hasPrivateInput != true, let progress else { return }
        update(id) { $0.executionProgress = progress }
    }
    private func finish(_ id: UUID, status: BuildStatus, error: String? = nil) async {
        guard launchID == id else { return }
        await finishBuildEvents(id)
        guard launchID == id else { return }
        let record = active
        sourceMonitor?.cancel(); sourceMonitor = nil
        if let record {
            let revision = try? await Task.detached { try SourceRevisionReader.capture(path: record.project.path, exclusions: record.sourceExclusions ?? []) }.value
            let after = try? await Task.detached { try GitActivitySnapshot.capture(path: record.project.path) }.value
            guard launchID == id else { return }
            let changes = changeSnapshots.removeValue(forKey: id).flatMap { before in after.map { before.changes(after: $0) } }
            update(id) { $0.sourceProvenance?.observe(revision); $0.changes = changes ?? { var value = ActivityChanges(); value.unavailable = true; return value }() }
        }
        await consume(id, bytes: Data(), final: true)
        guard launchID == id else { return }
        updateTimer?.cancel(); updateTimer = nil
        deliverOutput(id)
        let truncated = logTruncation.contains(id) || outputs[id]?.truncated == true || records.first { $0.id == id }?.truncated == true
        var finalStatus = status, finalError = error
        if status == .succeeded, var completed = active, completed.parameters.testTarget != nil {
            completed.status = .succeeded; completed.finishedAt = Date()
            let bytes = output(id)
            let result = await Task.detached { BuildResultReader.read(record: completed, output: bytes) }.value
            guard launchID == id else { return }
            if Task.isCancelled { finalStatus = .cancelled }
            else if result.verification?.verdict != "passed" { finalStatus = .failed; finalError = "testsUnverified" }
        }
        workers[id] = nil; testProgress[id] = nil; logTruncation.remove(id); session = nil; launchID = nil; preparation = nil; continuationTask = nil
        update(id) {
            $0.status = finalStatus; $0.finishedAt = Date(); $0.errorCode = finalError; $0.truncated = truncated; $0.needsInput = false
            $0.phase = "build.phase." + finalStatus.rawValue
            if finalStatus == .unknown { $0.tracking = .lost }
        }
        let ids = Set(records.suffix(8).map(\.id)); outputs = outputs.filter { ids.contains($0.key) }
        if records.first(where: { $0.id == id })?.hasPrivateInput == true { outputs[id] = nil; savedTails[id] = nil }
        revision = UUID(); persist(); schedule()
        if status == .unknown { resolveUnknownWhenIdle() }
        // Products and catalogue caches remain managed outputs until an explicit cleanup.
    }

    func cancel(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }), record.canCancel else { return }
        if record.status == .queued { update(id) { $0.status = .cancelled; $0.finishedAt = Date() }; persist(); schedule() }
        else if record.status == .preparing {
            preparation?.cancel(); Task { await finish(id, status: .cancelled) }
        } else {
            if record.parameters.backend == .xcodeMCP, record.parameters.intent == .run, record.xcodeRequestID == nil { preparation?.cancel(); return }
            if record.parameters.backend == .xcodeMCP, record.parameters.intent == .run {
                update(id) { $0.xcodeCancellationRequested = true }; persist()
                Task { [weak self] in
                    guard let self else { return }
                    do { try await self.xcode.requestRunCancellation(record) }
                    catch {
                        guard self.launchID == id else { return }
                        self.update(id) { $0.errorCode = "xcodeCancellationUnconfirmed" }; self.persist()
                    }
                }
                return
            }
            if record.parameters.intent == .cleanup { preparation?.cancel() }
            continuationTask?.cancel(); session?.cancel()
            if let choice = productChoice { productChoice = nil; choice.resume(throwing: CancellationError()) }
        }
    }
    /// Xcode-owned uncertain outcomes release the queue once Xcode itself shows no work in progress.
    /// Nothing is retried; other backends keep the manual acknowledgement.
    func resolveUnknownWhenIdle() {
        guard unknownResolver == nil, confirmsXcodeIdle != nil else { return }
        unknownResolver = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let confirms = self.confirmsXcodeIdle else { return }
                let pending = self.records.filter { $0.status == .unknown && $0.queueReleased != true && $0.parameters.backend == .xcodeMCP }
                guard !pending.isEmpty else { self.unknownResolver = nil; return }
                for record in pending where self.launchID == nil {
                    if await confirms(record), self.launchID == nil { self.acknowledgeUnknown(record.id) }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
    /// Explicit acknowledgement releases an uncertain operation; it never asserts that Xcode stopped.
    func acknowledgeUnknown(_ id: UUID) {
        guard records.first(where: { $0.id == id })?.status == .unknown else { return }
        update(id) { $0.queueReleased = true }; persist(); schedule()
    }
    func stop() {
        buildEventsMonitor?.cancel(); buildEventsMonitor = nil
        buildEvents?.stop(); buildEvents = nil
        preloadTask?.cancel(); preloadTask = nil
        if usesDiscoveryService { let discovery = discoveryService; Task { await discovery.stop() } }
        stopped = true
        for record in records where record.status == .queued { cancel(record.id) }
        if let active, active.canCancel { cancel(active.id) }
    }
    private func update(_ id: UUID, _ mutate: (inout BuildActivity) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }; mutate(&records[index])
        records[index].stateRevision = (records[index].stateRevision ?? 0) + 1
    }
    private func persist() {
        savedTails = savedTails.filter { id, _ in records.contains { $0.id == id } }
        let live = records.filter { $0.status.isPending || $0.status == .unknown }
        let completed = records.filter { !$0.status.isPending && $0.status != .unknown }.suffix(100)
        records = (Array(completed) + live).sorted { $0.createdAt < $1.createdAt }
        for record in records { ledger[record.id.uuidString]?.record = record }
        do {
            try store.save(records, retainedIDs: Set(ledger.keys))
            try JSONEncoder().encode(ledger).write(to: store.directory.appendingPathComponent("requests.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.directory.appendingPathComponent("requests.json").path)
        } catch { message = text("history.error") }
    }

    // MARK: - Independent observers and diagnostic review

    /// A read-only observer owns its deadline, never the underlying operation.
    /// Cancellation or a disconnected caller therefore cannot cancel a build.
    func waitForActivity(_ id: UUID, afterRevision: Int?, timeoutMs: Int) async throws -> (activity: BuildActivity, timedOut: Bool) {
        guard (0...25_000).contains(timeoutMs) else { throw BuildError.arguments }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while true {
            try Task.checkCancellation()
            guard let record = activity(id) else { throw BuildError.notFound }
            if !record.status.isPending || afterRevision.map({ (record.stateRevision ?? 0) != $0 }) == true {
                return (record, false)
            }
            if ContinuousClock.now >= deadline { return (record, true) }
            try await Task.sleep(for: min(.milliseconds(100), ContinuousClock.now.duration(to: deadline)))
        }
    }

    /// The admission ledger retains metadata after visible-history eviction.
    func activity(_ id: UUID) -> BuildActivity? { records.first { $0.id == id } ?? ledger[id.uuidString]?.record }
    /// Read-only settings extraction never builds and is restricted to this invocation's managed DerivedData.
    func productsFor(_ id: UUID) async throws -> [BuildProduct] {
        guard let record = activity(id), record.parameters.backend == .cli else { throw BuildError.notFound }
        if let cache = record.compilationDerivedDataPath {
            let owner = ledger.values.compactMap(\.record).filter { $0.compilationDerivedDataPath == cache && $0.startedAt != nil }.max { $0.createdAt < $1.createdAt }
            guard owner?.id == id else { throw BuildError.selectionExpired }
        }
        if let products = record.products { return products }
        guard record.status == .succeeded, record.parameters.operation == .build, record.parameters.intent != .catalogue else { throw BuildError.context }
        var project = record.project; project.developerDirectory = record.selectedDeveloperDirectory
        let derived = record.compilationDerivedDataPath.map { URL(fileURLWithPath: $0) } ?? store.directory.appendingPathComponent(id.uuidString + "-DerivedData")
        let command = try record.parameters.command(project: project, derivedDataPath: derived.path)
        let result = await Task.detached { EnvironmentInspector.boundedCapture(command.executable, Array(command.arguments.dropLast()) + ["-showBuildSettings", "-json"], directory: command.directory, environment: command.environment, timeout: 30, maximumBytes: 8 * 1024 * 1024) }.value
        guard result.0 == 0 else { throw BuildError.catalogueResponse }
        let products = try BuildProduct.parse(output: result.1, derivedData: derived)
        guard activity(id)?.stateRevision == record.stateRevision else { throw BuildError.context }
        update(id) { $0.products = products }; persist(); return products
    }
    func artifactCleanupReserved(_ id: UUID) -> Bool { records.contains { $0.cleanupActivityID == id && ($0.status.isPending || $0.status == .unknown) } }
    /// Deletion is a persisted build-queue activity, sharing FIFO and cancellation with every local operation.
    private func performManagedCleanup(_ record: BuildActivity) async throws {
        guard let target = record.cleanupActivityID, let manifest = record.cleanupArtifacts, !artifactLeases.contains(target) else { throw BuildError.context }
        let paths = try artifacts(target), root = store.directory
        let current = try await Task.detached { try paths.map { try ManagedArtifactReader.inspect($0, root: root) } }.value
        guard current == manifest, !artifactLeases.contains(target), !Task.isCancelled else { throw BuildError.sourceChanged }
        for artifact in manifest {
            guard !Task.isCancelled, !artifactLeases.contains(target), launchID == record.id else { throw CancellationError() }
            try await Task.detached {
                let url = URL(fileURLWithPath: artifact.path)
                guard try ManagedArtifactReader.inspect(url, root: root) == artifact else { throw BuildError.sourceChanged }
                try FileManager.default.removeItem(at: url)
            }.value
            update(record.id) { $0.cleanupRemoved = ($0.cleanupRemoved ?? []) + [artifact.id] }; persist()
        }
    }
    func artifacts(_ id: UUID) throws -> [URL] {
        guard let record = activity(id), !artifactLeases.contains(id), !record.status.isPending, record.status != .unknown else { throw BuildError.context }
        let base = store.directory.appendingPathComponent(id.uuidString)
        return [base.appendingPathExtension("xcresult"), base.appendingPathExtension("log"), URL(fileURLWithPath: base.path + ".tests.json"), URL(fileURLWithPath: base.path + "-DerivedData")].filter { url in
            FileManager.default.fileExists(atPath: url.path) && !records.contains { ($0.status.isPending || $0.status == .unknown) && $0.preparedDerivedDataPath == url.path }
        }
    }

    /// Admission preconditions are shared with the MCP readiness check. Queue occupancy alone is not a blocker.
    func readinessBlocker(project: ProjectContext, parameters: BuildParameters, simulatorConfirmed: Bool) -> BuildError? {
        guard !stopped, mayAdmit(), accepts(project) else { return .context }
        guard ledger.count < 10_000, pendingCount < 100 else { return .capacity }
        guard parameters.backend != .cli || !simulatorConfirmed else { return .arguments }
        if parameters.backend == .xcodeMCP, parameters.intent == .run {
            guard simulatorConfirmed, parameters.platform != .tvos else { return .configuration }
        } else if parameters.backend == .xcodeMCP {
            guard simulatorConfirmed, xcode.supports(parameters.operation), xcode.hasWorkspace(parameters.workspaceTab, path: project.workspace), xcode.project == project else { return .configuration }
        }
        return nil
    }

    /// Uses the same checkout inspector and Xcode resolver as admission without creating a record.
    func inspectReadiness(project: ProjectContext) async throws -> String {
        guard try await inspect(project) == project, accepts(project) else { throw BuildError.context }
        return try await resolveDeveloper(project)
    }

    func canInput(_ id: UUID) -> Bool { launchID == id && session != nil && active?.status == .running }
    func privateInput(_ id: UUID, bytes: Data) async throws {
        guard canInput(id), let worker = workers[id] else { throw BuildError.notFound }
        try await worker.makePrivate()
        guard canInput(id) else { throw BuildError.stopped }
        buildEvents?.makePrivate(); buildEventsMonitor?.cancel(); buildEventsMonitor = nil
        update(id) { $0.hasPrivateInput = true; $0.executionProgress = nil }
        let accepted = session?.send(bytes) == true
        if accepted { update(id) { $0.needsInput = false } }
        persist()
        guard accepted else { throw BuildError.capacity }
    }
    func resize(_ id: UUID, columns: Int, rows: Int) { if canInput(id) { session?.resize(columns: columns, rows: rows) } }

    func attachTerminal(owner: UUID, output: @escaping (UUID, Data) -> Void) { terminalOwner = owner; terminalOutput = output }
    func detachTerminal(owner: UUID) { if terminalOwner == owner { terminalOwner = nil; terminalOutput = nil } }
    func savedLogURL(_ id: UUID) -> URL? {
        guard records.contains(where: { $0.id == id }), FileManager.default.fileExists(atPath: store.logURL(id).path) else { return nil }
        return store.logURL(id)
    }
    func readLog(_ id: UUID, after cursor: Int, privateChannel: Bool = false) throws -> BuildLogSlice {
        guard records.contains(where: { $0.id == id }) else { throw BuildError.notFound }
        if records.first(where: { $0.id == id })?.hasPrivateInput == true && !privateChannel { return .init(text: "", nextCursor: cursor, gap: false) }
        if records.first(where: { $0.id == id })?.status.isPending == true, let output = outputs[id] { return output.read(after: cursor) }
        guard let handle = FileHandle(forReadingAtPath: store.logURL(id).path) else { return .init(text: "", nextCursor: cursor, gap: false) }
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd()); let offset = min(cursor, size)
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: 64 * 1024 + 4) ?? Data()
        return BuildOutput.slice(bytes, base: offset, after: cursor)
    }
    func diagnostic(_ id: UUID) throws -> String { try diagnosticPayload(id).prompt }
    /// The complete numbered prompt is bounded, including configuration; framing and identity remain intact.
    func diagnosticPayload(_ id: UUID) throws -> (prompt: String, truncated: Bool) {
        guard let record = records.first(where: { $0.id == id }), record.diagnosticAvailable else { throw BuildError.diagnostic }
        let configuration = DiagnosticText.bounded(record.parameters.scheme + " | " + record.parameters.configuration + " | " + record.parameters.destinationID + " | " + record.parameters.testPlan + " | " + record.parameters.workspaceTab + " | " + record.parameters.testIdentifiers.joined(separator: ", "), limit: 8192)
        let header = """
        \(text("build.diagnostic.instructions"))
        ID: \(record.id.uuidString)
        Checkout: \(record.project.path)
        Branch: \(record.project.branch); SHA: \(record.project.commit)
        Backend: \(record.parameters.backend.rawValue); operation: \(record.parameters.operation.rawValue)
        Xcode: \(record.selectedDeveloperDirectory ?? "unknown")
        Parameters: \(configuration.text)
        Preparation: \(record.errorCode ?? "none")
        Status: \(record.status.rawValue); exit: \(record.exitCode.map(String.init) ?? "unknown")
        """
        let raw = DiagnosticText.bounded(String(decoding: output(id), as: UTF8.self))
        let boundedHeader = DiagnosticText.bounded(header, limit: 16 * 1024)
        let fragment = DiagnosticText.bounded(DiagnosticText.numbered(raw.text), limit: DiagnosticText.maximumBytes - boundedHeader.text.utf8.count - 256)
        let truncated = configuration.truncated || boundedHeader.truncated || raw.truncated || fragment.truncated
        return (boundedHeader.text + (truncated ? "\n[TRUNCATED DIAGNOSTIC]" : "") + "\n<diagnostic-data>\n" + fragment.text + "\n</diagnostic-data>", truncated)
    }
}
