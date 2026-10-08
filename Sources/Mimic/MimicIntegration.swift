//
//  MimicIntegration.swift
//  Mimic
//
//  Created by Василий Маслов on 04.10.2026.
import AppKit
import Combine
import Foundation
import MimicCore

/// Constrained MCP facade over the native queue. No shell, terminal input, credentials or CI logs cross it.
@MainActor final class MimicIntegration: ObservableObject {
    @Published private(set) var connectionMessage = ""
    @Published private(set) var connecting = false
    unowned let model: TaskCoordinator
    private let listener = MimicBridgeListener()
    let discovery: BuildDiscovery
    let defaults: UserDefaults
    let workspaceStore: PanelWorkspaceStore
    let layoutStore: PanelLayoutStore
    var terminalChannels: [UUID: PanelTerminalSubscription] = [:]
    var credentialsWindow: NSWindow?
    var credentialSettings: CISettingsModel?
    let notifications: PanelNotifications
    private var admissions: [UUID: Task<BridgeValue, Error>] = [:]
    private var ledger: [String: BridgeValue] = [:]
    private struct CatalogueQuery {
        let context: BridgeValue
        let project: ProjectContext
        let pinned: ProjectContext
        let thread: String?
        var result: Result<BuildCatalogue, BuildError>?
    }
    private var catalogueQueries: [UUID: CatalogueQuery] = [:]
    private var activeRequests = 0
    /// Private development hook; deliberately absent from the public MCP tool catalog.
    private let developmentUpdateID = UUID()
    var developmentExit: (() -> Void)?
    var prepareUpdateBackup: (() async throws -> Void)?
    var developmentUpdateReady: Bool {
        self.developmentUpdateBlockers.isEmpty
    }
    var developmentUpdateBlockers: [String] {
        var blockers = self.model.developmentUpdateBlockers
        if self.connecting { blockers.append("plugin") }
        if catalogueQueries.values.contains(where: { if case .none = $0.result { return true }; return false }) { blockers.append("discovery") }
        if NSApp?.modalWindow != nil || self.credentialsWindow?.isVisible == true { blockers.append("dialog") }
        if self.credentialSettings?.checking == true { blockers.append("credentials") }
        if !self.admissions.isEmpty || self.activeRequests != 0 { blockers.append("requests") }
        if self.developmentExit == nil { blockers.append("owner") }
        return blockers
    }
    /// A single reservation covers native, CLI and MCP admission throughout backup and replacement.
    func prepareUpdate(owner: UUID) async throws -> Bool {
        guard self.developmentUpdateReady, self.model.reserveUpdate(owner: owner) else { return false }
        do {
            try await self.prepareUpdateBackup?()
            guard self.developmentUpdateReady else { self.model.releaseUpdate(owner: owner); return false }
            return true
        } catch { self.model.releaseUpdate(owner: owner); throw error }
    }
    func releaseUpdate(owner: UUID) { self.model.releaseUpdate(owner: owner) }
    init(model: TaskCoordinator, defaults: UserDefaults = .standard, discovery: BuildDiscovery = .shared) {
        self.model = model; self.defaults = defaults; self.discovery = discovery
        self.notifications = PanelNotifications(model: model, defaults: defaults)
        self.workspaceStore = PanelWorkspaceStore(defaults: defaults); self.layoutStore = PanelLayoutStore(defaults: defaults)
        if let data = defaults.data(forKey: "mcpLocalRequests"), let ledger = try? JSONDecoder().decode([String: BridgeValue].self, from: data) { self.ledger = ledger }
    }
    // MARK: - Bridge lifecycle

    func start() {
        do { try self.listener.start { [weak self] request in
            guard let self else { return .init(id: request.id, error: "unavailable") }
            do { return .init(id: request.id, result: try await self.handle(request)) }
            catch let error as IntegrationError { return .init(id: request.id, error: error.code, message: text("mcp.error." + error.code)) }
            catch let blocker as BranchSwitchBlocker { return .init(id: request.id, error: "branchSwitch", message: blocker.message) }
            catch let error as BranchSwitchError {
                let message: String
                if case let .command(output) = error { message = output }
                else { message = text("branch.error." + String(describing: error)) }
                return .init(id: request.id, error: "branchSwitch", message: message)
            }
            catch let error as BuildError { return .init(id: request.id, error: error.rawValue, message: text("build.error." + error.rawValue)) }
            catch let error as AppleSimulatorError { let code = String(describing: error); return .init(id: request.id, error: code, message: text("simulator.error." + code)) }
            catch let error as JenkinsConnectionError { return .init(id: request.id, error: error.localizationKey, message: text(error.localizationKey)) }
            catch let error as CIError { return .init(id: request.id, error: error.localizationKey, message: text(error.localizationKey)) }
            catch { return .init(id: request.id, error: "unavailable", message: text("mcp.error.unavailable")) }
        } } catch { self.connectionMessage = text("mcp.error.unavailable") }
    }
    func stop() {
        for subscription in self.terminalChannels.values { subscription.stop() }
        self.terminalChannels.removeAll(); self.listener.stop()
    }
    struct IntegrationError: Error { let code: String }
    func failure(_ code: String) -> IntegrationError { .init(code: code) }
    // MARK: - State and immutable identities

    static func context(_ project: ProjectContext, profile: ProfileSnapshot? = nil) -> BridgeValue {
        .object(["checkoutId": .string(project.path), "branch": .string(project.branch), "sha": .string(project.commit), "xcode": .string(project.developerDirectory ?? ""), "appleTarget": (try? BridgeValue.encode(project.appleTarget)) ?? .null, "profileID": profile.map { .string($0.id) } ?? .null, "profileRevision": profile.map { .string($0.revision) } ?? .null])
    }
    func task(_ record: TaskRecord) -> BridgeValue {
        var result: [String: BridgeValue] = ["id": .string(record.id.uuidString), "actionID": .string(record.profileExecution?.actionID ?? record.action.rawValue), "progress": self.model.profileProgress[record.id].map(BridgeValue.string) ?? .null, "title": .string(record.displayTitle ?? (record.action == .bootstrap ? text("quick.bootstrap." + record.options.platform.rawValue) : text(record.action.titleKey))), "status": .string(record.status.rawValue), "createdAt": .string(record.createdAt.ISO8601Format()), "context": Self.context(record.executionProject, profile: record.profileExecution?.snapshot), "diagnosticAvailable": .bool(record.status == .failed || record.status == .interrupted), "needsInput": .bool(model.awaitingInput.contains(record.id)), "canCancel": .bool(record.status == .queued || record.status == .running)]
        result["toolID"] = ProjectTool.identify(record).map { .string($0.rawValue) } ?? .null
        result["isPreview"] = .bool(record.profileExecution?.preview == true)
        result["startedAt"] = record.startedAt.map { .string($0.ISO8601Format()) } ?? .null
        result["finishedAt"] = record.finishedAt.map { .string($0.ISO8601Format()) } ?? .null
        if record.action == .bootstrap {
            let phase: String
            switch self.model.launchState {
            case .blockedByXcode(record.id): phase = "blocked"
            case .closingXcode(record.id): phase = "closing"
            case .checking(record.id): phase = "checking"
            default: phase = record.status.rawValue
            }
            // Additive presentation metadata uses the same observed stages as the native card.
            var progress = self.model.bootstrapProgressID == record.id ? self.model.bootstrapProgress
                : self.model.quickBootstrapActivity.flatMap { $0.request.id == record.id ? $0.progress : nil } ?? BootstrapProgress(options: record.options)
            if record.status == .succeeded { progress.finish(succeeded: true) }
            result["bootstrap"] = .object(["platform": .string(record.options.platform.rawValue), "phase": .string(phase),
                "fraction": .number(progress.fraction),
                "stages": .array(progress.stages.map { .string($0.rawValue) }),
                "currentStage": progress.stage.map { .string($0.rawValue) } ?? .null,
                "completedStages": .array(progress.stages.filter { progress.completed.contains($0) }.map { .string($0.rawValue) })])
            result["startedAt"] = record.startedAt.map { .string($0.ISO8601Format()) } ?? .null
            result["finishedAt"] = record.finishedAt.map { .string($0.ISO8601Format()) } ?? .null
            result["error"] = record.error.map(BridgeValue.string) ?? .null
        }
        return .object(result)
    }
    private func remote(_ run: RemoteTestRun) -> BridgeValue {
        .object(["id": .string(run.id.uuidString), "branch": .string(run.branch), "plan": .string(run.plan.rawValue), "status": .string(run.status), "createdAt": .string(run.createdAt.ISO8601Format()), "updatedAt": run.updatedAt.map { .string($0.ISO8601Format()) } ?? .null, "error": run.error.map { .string(text($0)) } ?? .null, "jenkinsURL": (run.buildURL ?? run.queueURL).map { .string($0.absoluteString) } ?? .null, "gitlabURL": run.pipelineURL.map { .string($0.absoluteString) } ?? .null, "allureURL": run.allureURL.map { .string($0.absoluteString) } ?? .null, "pipelineID": run.pipelineID.map { .number(Double($0)) } ?? .null, "sha": run.sha.map(BridgeValue.string) ?? .null, "jobs": .array(run.jobs.map { .object(["name": .string($0.name), "status": .string($0.status), "allowFailure": .bool($0.allowFailure), "url": .string($0.url.absoluteString)]) })])
    }
    func project(_ threadID: String?) -> ProjectContext? {
        guard let threadID else { return model.project }
        return model.projects.first { $0.path == workspaceStore.load(threadID).checkout }
    }
    static func compactCI(_ summary: CICompactSummary?) -> BridgeValue {
        guard let summary else { return .null }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return (try? JSONDecoder().decode(BridgeValue.self, from: encoder.encode(summary))) ?? .null
    }

    private func state(threadID: String? = nil, includeAppearance: Bool = false) -> BridgeValue {
        let current = project(threadID)
        let ciContext = current.flatMap { project in self.model.ciSettings.connection(forCheckout: project.path, services: self.model.activeProfile?.profile.services).map { CIContext(project: project, connection: $0) } }
        let ciSummaries = threadID.map { self.model.ciMonitor.heartbeatSummaries(threadID: $0, context: ciContext) } ?? self.model.ci.compactSummaries
        let ciSummary = ciSummaries.first
        let definitions = self.model.activeProfile?.profile.actions.filter { $0.allowsMCP } ?? []
        let actions: [BridgeValue] = definitions.map { .object(["id": .string($0.id), "title": .string($0.title), "presentation": .string($0.presentation.rawValue), "remote": .bool($0.remote != nil), "parameters": (try? BridgeValue.encode($0.parameters)) ?? .array([])]) }
        let simulatorQueue = model.simulatorScreen.records.filter { $0.status.isPending || $0.holdsQueue }.map { record -> BridgeValue in
            var item = record.metadata.object ?? [:]
            item["context"] = Self.context(record.project)
            item["title"] = .string(text("panel.block.simulators"))
            return .object(item)
        }
        var fields: [String: BridgeValue] = ["branchRebase": .bool(current.map { model.branchSwitch.rebaseEnabled(path: $0.path) } ?? false), "branchSwitch": current.flatMap { model.branchSwitch.latest(path: $0.path) }.map(Self.branchMetadata) ?? .null, "checkoutLocked": .bool(model.switchingBranch), "toolsPreferences": (try? BridgeValue.encode(model.toolsPreferences.value)) ?? .null, "ciSummaries": .array(ciSummaries.map { Self.compactCI($0) }), "ciSummary": Self.compactCI(ciSummary), "notices": .array(current.map { notifications.poll(checkout: $0.path) } ?? []), "layout": (try? BridgeValue.encode(layoutStore.load(.codex))) ?? .null, "workspace": threadID.flatMap { try? BridgeValue.encode(workspaceStore.load($0)) } ?? .null, "needsBinding": .bool(threadID != nil && current == nil), "queue": .array(self.model.records.filter { $0.status == .running || $0.status == .queued }.map(self.task) + self.model.builds.records.filter { $0.status == .running || $0.status == .queued || $0.status == .preparing }.map(BuildBridge.summary) + simulatorQueue), "simulator": self.model.simulatorScreen.viewerMetadata(thread: threadID, project: current), "context": current.map { Self.context($0, profile: self.model.activeProfile) } ?? .null, "version": .number(3), "profile": (try? BridgeValue.encode(self.model.activeProfile.map { ["id": $0.id, "revision": $0.revision, "title": $0.profile.title] })) ?? .null, "interface": (try? BridgeValue.encode(self.model.activeProfile?.profile.interface.map { interface in ProfileInterface(version: interface.version, bindings: interface.bindings.filter { binding in definitions.contains { $0.id == binding.actionID } }) })) ?? .null, "actions": .array(actions), "builds": .array(self.model.builds.records.filter { current == nil ? threadID == nil : $0.project.path == current?.path }.suffix(100).reversed().map(BuildBridge.summary)), "tasks": .array(self.model.records.filter { current == nil ? threadID == nil : $0.project.path == current?.path }.suffix(100).reversed().map(self.task)), "runs": .array(self.model.profileRemote.runs.filter { current == nil ? threadID == nil : $0.checkout.path == current?.path }.prefix(100).map(self.profileRemoteSummary)), "jenkinsConfigured": .bool(self.model.jenkinsSettings.connection != nil), "progress": .string(self.model.branchSwitch.active.map { text("branch.phase." + $0.phase.rawValue) } ?? (self.model.bootstrapIsBlocked ? text("bootstrap.xcode.waiting") : self.model.busy ? text("status.running") : text("status.idle")))]
        if includeAppearance { fields["appearance"] = .string(model.appearance.selection.rawValue) }
        return .object(fields)
    }
    func canAccess(_ project: ProjectContext, threadID: String?) -> Bool { threadID == nil || self.project(threadID)?.path == project.path }
    func expected(_ value: BridgeValue, threadID: String? = nil) throws -> ProjectContext {
        guard let current = project(threadID), value == Self.context(current, profile: self.model.activeProfile) else { throw self.failure("context") }
        return current
    }
    private func profileRemoteSummary(_ run: ProfileRemoteRun) -> BridgeValue {
        .object(["id": .string(run.id.uuidString), "actionID": .string(run.execution.actionID), "title": .string(run.execution.action?.title ?? run.execution.actionID), "branch": .string(run.branch), "plan": .string(run.execution.action?.title ?? ""), "status": .string(run.status), "createdAt": .string(run.createdAt.ISO8601Format()), "error": run.error.map(BridgeValue.string) ?? .null, "jenkinsURL": (run.buildURL ?? run.queueURL).map { .string($0.absoluteString) } ?? .null, "gitlabURL": run.pipelineURL.map { .string($0.absoluteString) } ?? .null, "allureURL": run.reportURL.map { .string($0.absoluteString) } ?? .null, "jobs": (try? BridgeValue.encode(run.jobs)) ?? .array([])])
    }
    // MARK: - Constrained tools

    /// Every method is checked again here: MCP schemas are advisory, not an authorization boundary.
    func handle(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        // Private developer inspection; available only while the user-enabled footer is sampling.
        if request.method == "get_frame_diagnostics" {
            guard request.threadID == nil, request.parameters.isEmpty || request.parameters == ["reset": .bool(true)] else { throw self.failure("arguments") }
            guard let view = FramePerformanceTrace.view, view.displayLink != nil else { return .object(["sampling": .bool(false)]) }
            if request.parameters["reset"] == .bool(true) { view.resetMeasurements() }
            return .object(["sampling": .bool(true), "cadence": try BridgeValue.encode(view.report), "mainThreadCPUSeconds": .number(view.mainThreadCPUSeconds)])
        }
        if ["prepare_development_update", "get_development_update_state"].contains(request.method) {
            guard request.parameters.isEmpty else { throw self.failure("arguments") }
            let ready = request.method == "prepare_development_update" ? try await self.prepareUpdate(owner: self.developmentUpdateID) : self.developmentUpdateReady
            if ready && request.method == "prepare_development_update" {
                // Recheck on the exit turn: another request may have arrived while the reply was sent.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.developmentUpdateReady else { self.model.releaseUpdate(owner: self.developmentUpdateID); return }
                    self.developmentExit?()
                }
            }
            return .object(["ready": .bool(ready), "blockers": .array(self.developmentUpdateBlockers.map(BridgeValue.string))])
        }
        if self.model.updateReserved {
            // Reads remain available to existing observers. Mutations fail before request-ledger admission.
            let reads = ["get_state", "get_action_configuration", "get_task", "get_task_log", "get_build_activity", "get_build_log", "get_simulator_activity", "get_simulator_screen", "get_panel_state"]
            guard reads.contains(request.method) else { throw self.failure("updating") }
        }
        self.activeRequests += 1
        defer { self.activeRequests -= 1 }
        if (SimulatorBridge.tools + SimulatorBridge.appTools + ["refresh_simulator_screen"]).contains(request.method) { return try await simulatorRequest(request) }
        if BuildBridge.tools.contains(request.method) || ["get_build_log", "cli_build_project", "cli_run_selected_tests"].contains(request.method) { return try await buildRequest(request) }
        let p = request.parameters
        if let method = ["preview_generator": "panel_preview_generator", "get_generator_preview": "panel_get_preview", "generate_files": "panel_generate"][request.method] {
            return try await panelRequest(.init(method: method, parameters: p, threadID: request.threadID))
        }
        if BranchSwitchBridge.tools.contains(request.method) { return try await branchRequest(request) }
        if BranchSwitchBridge.appTools.contains(request.method) { return try await panelBranchRequest(request) }
        if PanelBridge.appTools.contains(request.method) { return try await panelRequest(request) }
        if request.method == "open_native_task", Set(p.keys) == ["taskID"], let id = p["taskID"]?.string.flatMap(UUID.init(uuidString:)), let record = model.builds.records.first(where: { $0.id == id }), canAccess(record.project, threadID: request.threadID) { model.showBuildResult(id); return BuildBridge.metadata(record) }
        let allowed: [String: Set<String>] = ["open_panel": ["checkout"], "get_state": [], "get_task": ["taskID"], "get_task_diagnostic": ["taskID"], "cancel_local_task": ["taskID"], "open_native_task": ["taskID"], "list_remote_branches": ["query"], "run_local_action": ["actionID", "parameters", "context", "requestID"], "run_remote_action": ["actionID", "parameters", "context", "requestID"], "get_remote_run": ["runID"], "get_action_configuration": ["actionID"]]
        guard let keys = allowed[request.method], Set(p.keys).isSubset(of: keys), (["list_remote_branches", "open_panel"].contains(request.method) || Set(p.keys) == keys) else { throw self.failure("arguments") }
        switch request.method {
        case "open_panel", "get_state":
            if request.method == "open_panel", let checkout = p["checkout"]?.string {
                guard let threadID = request.threadID, !threadID.isEmpty, checkout.hasPrefix("/"), checkout.utf8.count <= 4096 else { throw failure("arguments") }
                let checked = try await model.bindPanelCheckout(checkout)
                var workspace = workspaceStore.load(threadID); workspace.checkout = checked.path
                try workspaceStore.save(workspace, for: threadID)
            }
            if let current = project(request.threadID) { await model.refreshPanelContext(current.path) }
            return self.state(threadID: request.threadID, includeAppearance: request.presentationMetadataVersion == 1)
        case "get_task", "get_task_diagnostic", "cancel_local_task", "open_native_task":
            guard let id = p["taskID"]?.string.flatMap(UUID.init(uuidString:)), let record = self.model.records.first(where: { $0.id == id }), canAccess(record.project, threadID: request.threadID) else { throw self.failure("notFound") }
            if request.method == "cancel_local_task" { self.model.cancel(id: id); return self.state(threadID: request.threadID) }
            if request.method == "open_native_task" { self.model.showHistory(id: id, focusTerminal: true); return self.task(record) }
            if request.method == "get_task" { return self.task(record) }
            guard record.status == .failed || record.status == .interrupted else { throw self.failure("diagnostic") }
            let snapshot = self.model.diagnosticSnapshot(for: record)
            return .object(["task": self.task(record), "text": .string(snapshot.text), "truncated": .bool(snapshot.truncated), "outputUnavailable": .bool(snapshot.outputUnavailable), "analysisPrompt": .string(snapshot.prompt(fragment: snapshot.text, comment: ""))])
        case "get_action_configuration":
            guard let current = project(request.threadID), let profile = model.activeProfile,
                  let id = p["actionID"]?.string, let action = profile.profile.actions.first(where: { $0.id == id && $0.allowsMCP && $0.remote != nil }), let connection = self.model.jenkinsSettings.connection else { throw self.failure("arguments") }
            let contract = try await self.model.profileRemote.contract(action: action, connection: connection)
            guard project(request.threadID) == current, model.activeProfile == profile, model.jenkinsSettings.connection == connection else { throw failure("context") }
            return .object(["actionID": .string(id), "context": Self.context(current, profile: profile), "fields": (try? BridgeValue.encode(contract.fields)) ?? .object([:])])
        case "run_local_action": return try await self.local(p, threadID: request.threadID)
        case "list_remote_branches":
            guard let current = project(request.threadID), let connection = self.model.ciSettings.connection(forCheckout: current.path, services: self.model.activeProfile?.profile.services) else { throw self.failure("credentials") }
            let query = p["query"]?.string ?? ""
            guard query.utf8.count <= 1024 else { throw self.failure("arguments") }
            let names = try await self.model.ciSettings.authenticatedClient.branches(connection: connection, search: query, token: self.model.ciSettings.token(for: connection))
            return .object(["branches": .array(names.map(BridgeValue.string))])
        case "run_remote_action": return try await self.remoteProfile(p, threadID: request.threadID)
        case "get_remote_run":
            guard let id = p["runID"]?.string.flatMap(UUID.init(uuidString:)), let run = self.model.profileRemote.runs.first(where: { $0.id == id }), canAccess(run.checkout, threadID: request.threadID) else { throw self.failure("notFound") }
            return self.profileRemoteSummary(run)
        default: throw self.failure("arguments")
        }
    }
    func local(_ p: [String: BridgeValue], threadID: String? = nil, preview: Bool = false, allowGenerator: Bool = false, preventToolRepeat: Bool = false) async throws -> BridgeValue {
        guard let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)), let actionName = p["actionID"]?.string, let values = p["parameters"]?.object, values.values.allSatisfy({ $0.string != nil }) else { throw self.failure("arguments") }
        var fingerprintFields = p; fingerprintFields["threadID"] = threadID.map(BridgeValue.string) ?? .null; fingerprintFields["preview"] = .bool(preview)
        let fingerprint = BridgeValue.object(fingerprintFields)
        if let entry = self.ledger[id.uuidString] {
            guard entry["parameters"] == fingerprint else { throw self.failure("duplicate") }
            if let inflight = self.admissions[id] { return try await inflight.value }
            if let record = self.model.records.first(where: { $0.id == id }) { return self.task(record) }
            if let error = entry["error"].string { throw self.failure(error) }
            throw self.failure("unknown")
        }
        let context = try self.expected(p["context"] ?? .null, threadID: threadID)
        guard let snapshot = self.model.activeProfile, let action = snapshot.profile.actions.first(where: { $0.id == actionName && $0.allowsMCP && $0.remote == nil }), (action.presentation != .generator || allowGenerator) else { throw self.failure("arguments") }
        let execution = ProfileExecution(snapshot: snapshot, actionID: actionName, parameters: values.mapValues { $0.string! }, preview: preview)
        guard (try? ProfileValidation.parameters(execution.parameters, action: action)) != nil else { throw self.failure("arguments") }
        var toolAdmission: String?
        if preventToolRepeat {
            guard let role = execution.binding?.role, let tool = ProjectTool.allCases.first(where: { $0.roles.contains(role) }) else { throw failure("arguments") }
            let key = context.path + "|" + tool.rawValue
            guard !model.toolAdmissions.contains(key), !model.records.contains(where: { $0.project.path == context.path && ProjectTool.identify($0) == tool && [.queued, .running].contains($0.status) }) else { throw failure("toolBusy") }
            model.toolAdmissions.insert(key); toolAdmission = key
        }
        defer { if let toolAdmission { model.toolAdmissions.remove(toolAdmission) } }
        guard self.ledger.count < 10000 else { throw self.failure("capacity") }
        self.ledger[id.uuidString] = .object(["parameters": fingerprint])
        self.defaults.set(try JSONEncoder().encode(self.ledger), forKey: "mcpLocalRequests")
        let operation = Task<BridgeValue, Error> {
            let record: TaskRecord? = await withCheckedContinuation { continuation in
                self.model.requestProfile(execution: execution, expected: context, recordID: id, reveal: false) { continuation.resume(returning: $0) }
            }
            guard let record else { throw self.failure("admission") }
            return self.task(record)
        }
        self.admissions[id] = operation
        defer { self.admissions[id] = nil }
        do { return try await operation.value }
        catch let error as IntegrationError {
            self.ledger[id.uuidString] = .object(["parameters": fingerprint, "error": .string(error.code)])
            self.defaults.set(try JSONEncoder().encode(self.ledger), forKey: "mcpLocalRequests")
            throw error
        }
    }

    private func remoteProfile(_ p: [String: BridgeValue], threadID: String? = nil) async throws -> BridgeValue {
        guard let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)) else { throw self.failure("arguments") }
        var fingerprintFields = p; fingerprintFields["threadID"] = threadID.map(BridgeValue.string) ?? .null
        let fingerprint = BridgeValue.object(fingerprintFields)
        let key = "remote:" + id.uuidString
        if let entry = self.ledger[key] {
            guard entry["parameters"] == fingerprint else { throw self.failure("duplicate") }
            if let pending = self.admissions[id] { return try await pending.value }
            if let run = self.model.profileRemote.runs.first(where: { $0.requestID == id }) { return self.profileRemoteSummary(run) }
            if let error = entry["error"].string { throw self.failure(error) }
            throw self.failure("unknown")
        }
        let context = try self.expected(p["context"] ?? .null, threadID: threadID)
        guard let snapshot = self.model.activeProfile, let actionID = p["actionID"]?.string,
              let action = snapshot.profile.actions.first(where: { $0.id == actionID && $0.allowsMCP && $0.remote != nil }),
              let values = p["parameters"]?.object, values.values.allSatisfy({ $0.string != nil }), self.ledger.count < 10000 else { throw self.failure("arguments") }
        guard (try? ProfileValidation.parameters(values.mapValues { $0.string! }, action: action)) != nil else { throw self.failure("arguments") }
        self.ledger[key] = .object(["parameters": fingerprint])
        self.defaults.set(try JSONEncoder().encode(self.ledger), forKey: "mcpLocalRequests")
        let pending = Task<BridgeValue, Error> {
            let run = try await self.model.submitRemoteProfile(snapshot: snapshot, action: action, parameters: values.mapValues { $0.string! }, requestID: id, expected: context)
            guard context == run.checkout else { throw self.failure("context") }
            return self.profileRemoteSummary(run)
        }
        self.admissions[id] = pending
        defer { self.admissions[id] = nil }
        do { return try await pending.value }
        catch {
            self.ledger[key] = .object(["parameters": fingerprint, "error": .string("admission")])
            self.defaults.set(try JSONEncoder().encode(self.ledger), forKey: "mcpLocalRequests")
            throw error
        }
    }

    // MARK: - Codex connection

    /// Exports a relocatable plugin definition using the current app's signed helper path.
    func exportPlugin() {
        guard !self.model.admissionsClosed, !self.connecting else { return }
        do {
            let root = try MimicPluginExporter.export(app: Bundle.main.bundleURL, readme: text("mcp.install.instructions"), description: text("mcp.plugin.description"), shortDescription: text("mcp.plugin.shortDescription"))
            if let codex = MimicPluginInstaller.findCodex() {
                let revision = try MimicPluginExporter.installationRevision(app: Bundle.main.bundleURL)
                self.connecting = true
                Task {
                    defer { self.connecting = false }
                    do {
                        try await MimicPluginInstaller.install(marketplace: root, codex: codex)
                        self.defaults.set(MimicVersion.build, forKey: "mimic.pluginBuild")
                        self.defaults.set(revision, forKey: "mimic.pluginRevision")
                        self.connectionMessage = text("mcp.installed")
                    }
                    catch { self.connectionMessage = text("mcp.exported"); NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent("README.md")]) }
                }
                return
            }
            self.connectionMessage = text("mcp.exported")
            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent("README.md")])
        } catch { self.connectionMessage = text("mcp.error.export") }
    }
    /// Refresh only an existing connection; first-time integration remains an explicit setup action.
    func refreshInstalledPluginIfNeeded() {
        let root = self.model.supportDirectory.appendingPathComponent("CodexPlugin")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("plugins/mimic/.mcp.json").path),
              !self.connecting, let codex = MimicPluginInstaller.findCodex() else { return }
        let revision: String
        do { revision = try MimicPluginExporter.installationRevision(app: Bundle.main.bundleURL) }
        catch { self.connectionMessage = text("mcp.error.export"); return }
        guard self.defaults.string(forKey: "mimic.pluginBuild") != MimicVersion.build ||
              self.defaults.string(forKey: "mimic.pluginRevision") != revision else { return }
        self.connecting = true
        Task {
            defer { self.connecting = false }
            do {
                _ = try MimicPluginExporter.export(app: Bundle.main.bundleURL, directory: root, readme: text("mcp.install.instructions"),
                    description: text("mcp.plugin.description"), shortDescription: text("mcp.plugin.shortDescription"))
                try await MimicPluginInstaller.install(marketplace: root, codex: codex)
                self.defaults.set(MimicVersion.build, forKey: "mimic.pluginBuild")
                self.defaults.set(revision, forKey: "mimic.pluginRevision")
                self.connectionMessage = text("update.plugin.ready")
            } catch { self.connectionMessage = text("mcp.error.export") }
        }
    }
}

extension MimicIntegration {
    /// Keeps the legacy successful payload stable for both asynchronous and synchronous clients.
    private func cataloguePayload(_ catalogue: BuildCatalogue, context: BridgeValue, project: ProjectContext) throws -> BridgeValue {
        .object(["context": context, "cli": try BridgeValue.encode(catalogue), "backends": .array([.string("cli")] + (model.builds.xcode.project == project ? [.string("xcodeMCP")] : [])), "xcode": .object(["version": .string(model.builds.xcode.version), "workspaces": .object(model.builds.xcode.windows.mapValues(BridgeValue.string)), "settings": .string(text("build.xcode.settings")), "liveLog": .bool(false), "canCancel": .bool(false)])])
    }

    /// Raw log access is private to MimicCLI; these methods are deliberately absent from MCP tools/list.
    func buildRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        let threadID = request.threadID
        let p = request.parameters
        let method = request.method.replacingOccurrences(of: "cli_", with: "")
        let keys: Set<String>
        switch method {
        case "get_build_configuration": keys = ["context", "scheme"]
        case "start_build_configuration": keys = ["context", "scheme", "includeTestPlans"]
        case "get_build_configuration_state": keys = ["queryID"]
        case "build_project", "run_selected_tests": keys = ["context", "requestID", "parameters", "simulatorConfirmed"]
        case "get_build_activity", "cancel_build_activity", "get_build_diagnostic": keys = ["activityID"]
        case "get_build_log": keys = ["activityID", "cursor"]
        default: throw BuildError.arguments
        }
        guard Set(p.keys) == keys else { throw BuildError.arguments }
        switch method {
        case "get_build_configuration", "start_build_configuration":
            let context = p["context"] ?? .null
            let project = try self.expected(context, threadID: threadID)
            guard model.projects.contains(project), let scheme = p["scheme"]?.string, scheme.utf8.count <= 1024,
                  !scheme.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw BuildError.arguments }
            let tests: Bool
            if method == "start_build_configuration" {
                guard case let .bool(value) = p["includeTestPlans"] else { throw BuildError.arguments }; tests = value
            } else { tests = false }
            let pinned = try await BuildDiscovery.pinned(project)
            _ = try self.expected(context, threadID: threadID)
            if method == "get_build_configuration" {
                let catalogue = try await self.discovery.catalogue(project: pinned, scheme: scheme, includeTestPlans: tests, profileID: context["profileID"].string, profileRevision: context["profileRevision"].string)
                _ = try self.expected(context, threadID: threadID)
                guard try await BuildDiscovery.pinned(project) == pinned else { throw BuildError.context }
                return try cataloguePayload(catalogue, context: context, project: project)
            }
            // Bounded handles belong to this chat and full profile context; polling never waits for xcodebuild.
            if catalogueQueries.count >= 64 { catalogueQueries = catalogueQueries.filter { if case .none = $0.value.result { return true }; return false } }
            guard catalogueQueries.count < 64 else { throw BuildError.capacity }
            let id = UUID()
            catalogueQueries[id] = CatalogueQuery(context: context, project: project, pinned: pinned, thread: threadID)
            Task {
                let result: Result<BuildCatalogue, BuildError>
                do { result = .success(try await self.discovery.catalogue(project: pinned, scheme: scheme, includeTestPlans: tests, profileID: context["profileID"].string, profileRevision: context["profileRevision"].string)) }
                catch { result = .failure(error as? BuildError ?? .catalogueProcess) }
                self.catalogueQueries[id]?.result = result
            }
            return .object(["queryID": .string(id.uuidString), "status": .string("pending")])
        case "get_build_configuration_state":
            guard let id = p["queryID"]?.string.flatMap(UUID.init(uuidString:)), let query = catalogueQueries[id], query.thread == threadID else { throw BuildError.notFound }
            _ = try expected(query.context, threadID: threadID)
            guard try await BuildDiscovery.pinned(query.project) == query.pinned else { throw BuildError.context }
            var payload: [String: BridgeValue] = ["queryID": .string(id.uuidString), "status": .string("pending")]
            if let result = query.result {
                switch result {
                case let .success(catalogue): payload["status"] = .string("ready"); payload["result"] = try cataloguePayload(catalogue, context: query.context, project: query.project)
                case let .failure(error): payload["status"] = .string("failed"); payload["errorCode"] = .string(error.rawValue); payload["message"] = .string(text("build.error." + error.rawValue))
                }
            }
            return .object(payload)
        case "build_project", "run_selected_tests":
            guard let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)), case let .bool(confirmed) = p["simulatorConfirmed"] else { throw BuildError.arguments }
            let project = try self.expected(p["context"] ?? .null, threadID: threadID)
            let parameters = try BuildBridge.parameters(p["parameters"] ?? .null, operation: method == "build_project" ? .build : .test)
            let record = try await model.builds.submit(id: id, project: project, parameters: parameters, source: request.method.hasPrefix("cli_") ? "Terminal" : "Codex", simulatorConfirmed: confirmed)
            return BuildBridge.metadata(record)
        default:
            guard let id = p["activityID"]?.string.flatMap(UUID.init(uuidString:)), let record = model.builds.records.first(where: { $0.id == id }), canAccess(record.project, threadID: request.threadID) else { throw BuildError.notFound }
            if method == "cancel_build_activity" {
                guard record.canCancel else { throw BuildError.unsupported }; model.builds.cancel(id)
                return model.builds.records.first(where: { $0.id == id }).map(BuildBridge.metadata) ?? BuildBridge.metadata(record)
            }
            if method == "get_build_diagnostic" {
                let diagnostic = try model.builds.diagnosticPayload(id)
                return .object(["task": BuildBridge.summary(record), "analysisPrompt": .string(diagnostic.prompt), "truncated": .bool(record.truncated || diagnostic.truncated)])
            }
            if method == "get_build_log" {
                guard let cursor = p["cursor"]?.integer else { throw BuildError.arguments }
                let slice = try model.builds.readLog(id, after: cursor)
                return .object(["text": .string(slice.text), "nextCursor": .number(Double(slice.nextCursor)), "gap": .bool(slice.gap), "activity": BuildBridge.metadata(record)])
            }
            return BuildBridge.metadata(record)
        }
    }
}

// MARK: - Simulator facade

extension MimicIntegration {
    /// Every payload is validated natively. Observations stay private until the caller explicitly asks for them.
    func simulatorRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        if request.method == "simulator_ui_observe", let operation = request.parameters["operation"]?.string, SimulatorBridge.viewerTools.contains(operation) {
            var parameters = request.parameters; parameters["operation"] = nil
            return try await simulatorViewerRequest(.init(method: operation, parameters: parameters, id: request.id, threadID: request.threadID))
        }
        if SimulatorBridge.viewerTools.contains(request.method) { return try await simulatorViewerRequest(request) }
        let threadID = request.threadID
        let method = request.method == "simulator_ui_action" ? "perform_simulator_action" : request.method
        let p = request.parameters, owner = model.simulatorScreen
        let keys: Set<String>
        switch method {
        case "get_simulator_configuration": keys = ["context"]
        case "start_simulator_session": keys = ["context", "requestID", "deviceID"]
        case "perform_simulator_action": keys = ["context", "requestID", "sessionID", "revision", "action"]
        case "install_simulator_app", "close_simulator_session", "refresh_simulator_screen": keys = ["context", "requestID", "sessionID"]
        case "observe_simulator", "simulator_ui_observe", "simulator_ui_heartbeat": keys = ["sessionID"]
        case "get_simulator_activity", "simulator_ui_release_unknown": keys = ["activityID"]
        default: throw AppleSimulatorError.arguments
        }
        guard Set(p.keys) == keys else { throw AppleSimulatorError.arguments }
        if method == "get_simulator_configuration" {
            let project = try expected(p["context"] ?? .null, threadID: threadID)
            var result = try await owner.configuration(project: project).object ?? [:]
            // Discovery is asynchronous; reject a changed binding/profile before exposing choices.
            _ = try expected(p["context"] ?? .null, threadID: threadID)
            result["context"] = Self.context(project, profile: model.activeProfile)
            return .object(result)
        }
        if method == "get_simulator_activity" || method == "simulator_ui_release_unknown" {
            guard let id = p["activityID"]?.string.flatMap(UUID.init(uuidString:)), let record = owner.activity(id), (request.method == "simulator_ui_release_unknown" || record.deviceOnly == true || canAccess(record.project, threadID: threadID)) else { throw BuildError.notFound }
            if method == "simulator_ui_release_unknown" { try await owner.releaseUnknown(id) }
            return .object(["activity": owner.activity(id)?.metadata ?? record.metadata, "state": owner.viewerMetadata(thread: threadID, project: project(threadID))])
        }
        if ["observe_simulator", "simulator_ui_observe", "simulator_ui_heartbeat"].contains(method) {
            guard let id = p["sessionID"]?.string.flatMap(UUID.init(uuidString:)) else { throw AppleSimulatorError.arguments }
            guard owner.sessionAllowed(id, thread: threadID, project: project(threadID)) else { throw BuildError.context }
            if method == "simulator_ui_heartbeat" { try owner.heartbeat(id); return owner.metadata }
            return try owner.observation(sessionID: id)
        }
        let project = try self.expected(p["context"] ?? .null, threadID: threadID)
        guard let requestID = p["requestID"]?.string.flatMap(UUID.init(uuidString:)) else { throw AppleSimulatorError.arguments }
        if method == "start_simulator_session" {
            guard let device = p["deviceID"]?.string.flatMap(UUID.init(uuidString:)) else { throw AppleSimulatorError.arguments }
            return try await owner.submit(id: requestID, kind: .start, project: project, device: device).metadata
        }
        guard let sessionID = p["sessionID"]?.string.flatMap(UUID.init(uuidString:)) else { throw AppleSimulatorError.arguments }
        guard owner.sessionAllowed(sessionID, thread: threadID, project: project) else { throw BuildError.context }
        let device = owner.sessionOwner(sessionID)?.descriptor?.deviceID ?? owner.records.first(where: { $0.id == requestID })?.deviceID
        guard let device else { throw AppleSimulatorError.noSession }
        let kind: SimulatorActivity.Kind = method == "install_simulator_app" ? .install : method == "perform_simulator_action" ? .action : method == "refresh_simulator_screen" ? .refresh : .close
        if request.method == "simulator_ui_action", model.busy || owner.records.contains(where: { $0.status.isPending }) { throw AppleSimulatorError.occupied }
        let action = kind == .action ? try SimulatorBridge.action(p["action"] ?? .null) : nil
        let revision = kind == .action ? p["revision"]?.integer.flatMap { $0 > 0 ? UInt64($0) : nil } : nil
        if kind == .action, revision == nil { throw AppleSimulatorError.arguments }
        return try await owner.submit(id: requestID, kind: kind, project: project, device: device, sessionID: sessionID, action: action, revision: revision).metadata
    }
}


// MARK: - App-only viewer protocol v3

extension MimicIntegration {
    /// Host-provided thread identity binds each viewer; callers cannot name another chat.
    private func simulatorViewerRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        let owner = model.simulatorScreen, p = request.parameters, thread = request.threadID ?? ""
        let keys: Set<String>
        switch request.method {
        case "simulator_ui_authorize", "simulator_ui_devices": keys = ["context"]
        case "simulator_ui_viewer_action": keys = ["viewerID", "requestID", "revision", "action"]
        case "simulator_ui_attach": keys = ["context", "viewerID", "deviceID", "requestID"]
        case "simulator_ui_detach", "simulator_ui_video", "simulator_ui_video_stop", "simulator_ui_masks", "simulator_ui_input", "simulator_ui_input_cancel": keys = ["viewerID"]
        case "simulator_ui_viewer_heartbeat": keys = ["viewerID", "visible"]
        case "simulator_ui_frame": keys = ["viewerID", "refresh"]
        case "simulator_ui_video_size": keys = ["viewerID", "width", "height"]
        case "simulator_ui_input_event": keys = ["viewerID", "event"]
        case "simulator_ui_video_poll": keys = p["token"] == nil ? ["viewerID", "after"] : ["viewerID", "after", "token"]
        default: throw AppleSimulatorError.arguments
        }
        guard Set(p.keys) == keys else { throw AppleSimulatorError.arguments }
        if ["simulator_ui_authorize", "simulator_ui_devices"].contains(request.method) {
            let project = p["context"] == .null && self.project(request.threadID) == nil ? nil : try expected(p["context"] ?? .null, threadID: request.threadID)
            if request.method == "simulator_ui_authorize" { try await owner.chooseAccess(project: project) }
            let result = try await owner.configuration(project: project)
            guard self.project(request.threadID) == project else { throw BuildError.context }
            return result
        }
        guard let viewer = p["viewerID"]?.string.flatMap(UUID.init(uuidString:)) else { throw AppleSimulatorError.arguments }
        switch request.method {
        case "simulator_ui_attach":
            let project = p["context"] == .null && self.project(request.threadID) == nil ? nil : try expected(p["context"] ?? .null, threadID: request.threadID)
            guard let device = p["deviceID"]?.string.flatMap(UUID.init(uuidString:)), let request = p["requestID"]?.string.flatMap(UUID.init(uuidString:)) else { throw AppleSimulatorError.arguments }
            return try await owner.attachViewer(viewer, thread: thread, project: project, device: device, request: request)
        case "simulator_ui_viewer_action":
            guard !model.busy, !owner.records.contains(where: { $0.status.isPending }), let request = p["requestID"]?.string.flatMap(UUID.init(uuidString:)), let revision = p["revision"]?.integer, revision > 0 else { throw AppleSimulatorError.occupied }
            return try owner.viewerAction(viewer, thread: thread, request: request, action: SimulatorBridge.action(p["action"] ?? .null), revision: UInt64(revision))
        case "simulator_ui_detach": owner.detachViewer(viewer, thread: thread); return .null
        case "simulator_ui_viewer_heartbeat":
            guard case let .bool(visible) = p["visible"] else { throw AppleSimulatorError.arguments }
            return try owner.viewerHeartbeat(viewer, thread: thread, visible: visible)
        case "simulator_ui_input": return try await owner.inputAccess(viewer, thread: thread)
        case "simulator_ui_input_event": return try await owner.inputEvent(viewer, thread: thread, event: SimulatorTouchEvent(p["event"] ?? .null))
        case "simulator_ui_input_cancel": try await owner.cancelInput(viewer, thread: thread); return .null
        case "simulator_ui_video": return try await owner.videoAccess(viewer, thread: thread)
        case "simulator_ui_masks": return try await owner.viewerMasks(viewer, thread: thread)
        case "simulator_ui_video_stop": owner.stopVideo(viewer, thread: thread); return .null
        case "simulator_ui_video_size":
            guard let width = p["width"]?.integer, let height = p["height"]?.integer else { throw AppleSimulatorError.arguments }
            try owner.videoSize(viewer, thread: thread, width: width, height: height); return .null
        case "simulator_ui_video_poll":
            guard let after = p["after"]?.integer, after >= 0 else { throw AppleSimulatorError.arguments }
            if let token = p["token"], token.string == nil { throw AppleSimulatorError.arguments }
            return try owner.videoPoll(viewer, thread: thread, after: UInt64(after), token: p["token"]?.string)
        default:
            guard case let .bool(refresh) = p["refresh"] else { throw AppleSimulatorError.arguments }
            return try await owner.viewerObservation(viewer, thread: thread, refresh: refresh)
        }
    }
}
