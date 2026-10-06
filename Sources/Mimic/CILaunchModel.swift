//
//  CILaunchModel.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import Combine
import Foundation
import MimicCore

/// Owns the short native launch form. Dismissing it never cancels an admitted remote request.
@MainActor final class CILaunchModel: ObservableObject {
    let preferences: CILaunchPreferences
    @Published private(set) var contracts: [RemoteCIKind: ProfileRemoteContract] = [:]
    @Published private(set) var capabilityErrors: [RemoteCIKind: String] = [:]
    @Published private(set) var checking: Set<RemoteCIKind> = []
    @Published private(set) var selected: RemoteCIKind?
    @Published private(set) var submitting = false
    @Published private(set) var message: String?
    @Published private(set) var branches: [String] = []
    @Published var branch = ""
    @Published var plan: UITestPlan = .smoke
    @Published var gates: [QualityGate: Bool] = [:]
    private let settings: JenkinsSettings
    private let gitlabSettings: CISettingsModel
    private let coordinator: ProfileRemoteCoordinator
    private let snapshot: @MainActor () -> ProfileSnapshot?
    private let submitProfile: @MainActor (ProfileSnapshot, ActionDefinition, [String: String], UUID, ProfileRemoteContract, ProjectContext) async throws -> ProfileRemoteRun
    private var frozenSnapshot: ProfileSnapshot?
    private let client: JenkinsClient
    private let gitlab: GitLabClient
    private let project: @MainActor () -> ProjectContext?
    private let validate: @MainActor (ProjectContext) async throws -> Void
    private var revision = UUID()
    private var capabilityTask: Task<Void, Never>?
    private var branchTask: Task<Void, Never>?
    private var branchRevision = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var visible = false
    private var frozenProject: ProjectContext?
    private(set) var reviewedContract: ProfileRemoteContract?
    private var requestID = UUID()

    init(preferences: CILaunchPreferences, settings: JenkinsSettings, gitlabSettings: CISettingsModel, coordinator: ProfileRemoteCoordinator, snapshot: @escaping @MainActor () -> ProfileSnapshot?,
         submitProfile: @escaping @MainActor (ProfileSnapshot, ActionDefinition, [String: String], UUID, ProfileRemoteContract, ProjectContext) async throws -> ProfileRemoteRun,
         client: JenkinsClient = JenkinsClient(), gitlab: GitLabClient = GitLabClient(), project: @escaping @MainActor () -> ProjectContext?,
         validate: @escaping @MainActor (ProjectContext) async throws -> Void) {
        self.preferences = preferences; self.settings = settings; self.gitlabSettings = gitlabSettings; self.coordinator = coordinator
        self.snapshot = snapshot; self.submitProfile = submitProfile
        self.client = client; self.gitlab = gitlab; self.project = project; self.validate = validate
        preferences.$qualityGates.dropFirst().sink { [weak self] enabled in
            if !enabled, self?.selected == .qualityGates { self?.close() }
            DispatchQueue.main.async { [weak self] in self?.refreshCapabilities() }
        }.store(in: &self.subscriptions)
        preferences.$beta.dropFirst().sink { [weak self] enabled in
            if !enabled, self?.selected == .beta { self?.close() }
            DispatchQueue.main.async { [weak self] in self?.refreshCapabilities() }
        }.store(in: &self.subscriptions)
    }

    var credentialBlocked: Bool {
        self.settings.connection.flatMap { self.settings.credentialSession.failures[$0.id] } != nil ||
        self.gitlabSettings.connection.flatMap { self.gitlabSettings.credentialSession.failures[$0.id] } != nil
    }

    // MARK: - Capability and form lifetime

    /// Page navigation pauses capability requests while keeping the launch draft.
    func setVisible(_ visible: Bool, preserveDraft: Bool = false) {
        guard self.visible != visible else {
            if !visible, !preserveDraft, self.selected != nil { self.close() }
            return
        }
        self.visible = visible
        if visible { self.refreshCapabilities() }
        else {
            self.revision = UUID(); self.capabilityTask?.cancel(); self.capabilityTask = nil; self.checking = []
            if preserveDraft { self.branchRevision = UUID(); self.branchTask?.cancel(); self.branchTask = nil }
            else { self.close() }
        }
    }
    func contextChanged() {
        self.close(); self.contracts = [:]; self.capabilityErrors = [:]; self.refreshCapabilities()
    }
    func refreshCapabilities() {
        self.revision = UUID(); self.capabilityTask?.cancel(); self.checking = []
        guard self.visible else { return }
        guard let connection = self.settings.connection, self.gitlabSettings.connection != nil, self.project() != nil, self.snapshot()?.profile.interface != nil else {
            self.contracts = [:]
            self.capabilityErrors = Dictionary(uniqueKeysWithValues: self.preferences.kinds.map { ($0, "ci.launch.configure") }); return
        }
        let revision = self.revision, kinds = self.preferences.kinds
        self.checking = Set(kinds)
        self.capabilityTask = Task { [weak self] in
            guard let self else { return }
            for kind in kinds {
                do {
                    guard let snapshot = self.snapshot(), let binding = snapshot.profile.interface?.binding(kind.profileRole), let action = snapshot.profile.actions.first(where: { $0.id == binding.actionID }) else { throw ProfileError.interface }
                    let contract = try await self.coordinator.contract(action: action, connection: connection)
                    guard self.revision == revision, !Task.isCancelled else { return }
                    self.contracts[kind] = contract; self.capabilityErrors[kind] = nil
                } catch {
                    guard self.revision == revision, !Task.isCancelled else { return }
                    self.contracts[kind] = nil; self.capabilityErrors[kind] = self.errorKey(error)
                }
                self.checking.remove(kind)
            }
        }
    }
    func open(_ kind: RemoteCIKind) {
        guard !self.submitting, self.preferences.kinds.contains(kind), let contract = self.contracts[kind], let project = self.project() else { return }
        if self.selected == kind { self.close(); return }
        self.close(); self.selected = kind; self.frozenProject = project; self.frozenSnapshot = self.snapshot(); self.reviewedContract = contract
        self.plan = .smoke; self.branch = ""; self.requestID = UUID(); self.message = nil
        self.applyDefaults(kind, contract: contract)
        let revision = self.branchRevision
        self.branchTask = Task { [weak self] in
            guard let self, let connection = self.gitlabSettings.connection else { return }
            do {
                let token = try self.gitlabSettings.token(for: connection)
                let exists: Bool
                if project.branch.isEmpty { exists = false }
                else { exists = try await self.gitlab.branchExists(connection: connection, branch: project.branch, token: token) }
                guard self.branchRevision == revision, self.selected == kind, !Task.isCancelled else { return }
                if exists { self.branch = project.branch }
                self.searchBranches(self.branch)
            } catch {
                guard self.branchRevision == revision, !Task.isCancelled else { return }
                self.message = self.errorKey(error)
            }
        }
    }
    func close() {
        self.selected = nil; self.reviewedContract = nil; self.frozenProject = nil; self.frozenSnapshot = nil; self.message = nil
        self.branchRevision = UUID(); self.branchTask?.cancel(); self.branchTask = nil; self.branches = []
    }
    func searchBranches(_ query: String) {
        self.branchTask?.cancel(); self.branchRevision = UUID(); self.branches = []
        guard self.selected != nil, let connection = self.gitlabSettings.connection else { return }
        let revision = self.branchRevision
        self.branchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let branches = try await self.gitlab.branches(connection: connection, search: query, token: self.gitlabSettings.token(for: connection))
                guard self.branchRevision == revision, !Task.isCancelled else { return }
                self.branches = branches
            } catch {
                guard self.branchRevision == revision, !Task.isCancelled else { return }
                self.message = self.errorKey(error)
            }
        }
    }

    // MARK: - Explicit submission

    func submit() {
        guard !self.submitting, let kind = self.selected, self.preferences.kinds.contains(kind),
              let project = self.frozenProject, let contract = self.reviewedContract,
              let jenkins = self.settings.connection, self.gitlabSettings.connection != nil else { return }
        let branch = self.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot = self.frozenSnapshot, let binding = snapshot.profile.interface?.binding(kind.profileRole), let action = snapshot.profile.actions.first(where: { $0.id == binding.actionID }) else { return }
        var values: [ProfileFormField: String] = [.branch: branch]
        if kind == .uiTests { values[.plan] = self.plan.rawValue }
        if kind == .qualityGates { for gate in QualityGate.allCases { values[gate.profileField] = String(self.gates[gate] == true) } }
        if kind == .beta {
            for field in [ProfileFormField.target, .rebase, .upload] {
                guard let id = binding.parameter(field), let value = contract.fields[id]?.defaultValue else { return }; values[field] = value
            }
        }
        let execution: ProfileExecution
        do { execution = try snapshot.execution(role: kind.profileRole, values: values) } catch { self.message = "jenkins.error.contractChanged"; return }
        let requestID = self.requestID
        self.submitting = true; self.message = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.submitting = false }
            do {
                guard self.snapshot() == snapshot, self.project() == project, self.preferences.kinds.contains(kind) else { throw ProfileError.revision }
                try await self.validate(project)
                _ = try await self.submitProfile(snapshot, action, execution.parameters, requestID, contract, project)
                self.close()
            } catch JenkinsConnectionError.contractChanged {
                do {
                    let current = try await self.coordinator.contract(action: action, connection: jenkins)
                    guard self.selected == kind, self.project() == project, self.settings.connection == jenkins else { return }
                    self.contracts[kind] = current; self.reviewedContract = current
                    self.applyDefaults(kind, contract: current)
                    self.message = "jenkins.error.contractChanged"
                } catch { if self.selected == kind { self.message = self.errorKey(error) } }
            } catch { if self.selected == kind { self.message = self.errorKey(error) } }
        }
    }
    private func applyDefaults(_ kind: RemoteCIKind, contract: ProfileRemoteContract) {
        guard let binding = self.frozenSnapshot?.profile.interface?.binding(kind.profileRole) else { return }
        if kind == .uiTests, let id = binding.parameter(.plan), let value = contract.fields[id]?.defaultValue, let plan = UITestPlan(rawValue: value) { self.plan = plan }
        if kind == .qualityGates {
            self.gates = Dictionary(uniqueKeysWithValues: QualityGate.allCases.map { gate in (gate, binding.parameter(gate.profileField).flatMap { contract.fields[$0]?.defaultValue } == "true") })
        }
    }
    var availablePlans: [UITestPlan] {
        guard let binding = self.frozenSnapshot?.profile.interface?.binding(.uiTests), let id = binding.parameter(.plan) else { return [] }
        return (self.reviewedContract?.fields[id]?.choices ?? []).compactMap(UITestPlan.init(rawValue:))
    }
    func betaValue(_ field: ProfileFormField) -> String? {
        guard let id = self.frozenSnapshot?.profile.interface?.binding(.beta)?.parameter(field) else { return nil }
        return self.reviewedContract?.fields[id]?.defaultValue
    }
    private func errorKey(_ error: Error) -> String {
        (error as? JenkinsConnectionError)?.localizationKey ?? (error as? CIError)?.localizationKey ?? "ci.error.network"
    }
}
