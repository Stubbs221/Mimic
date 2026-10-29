// Created by Василий Маслов on 13.10.2026.
import AppKit
import Combine
import Foundation
import MimicCore

/// One native account/cache owner; observer identity determines selection and report ownership.
@MainActor final class WorkCoordinator: ObservableObject {
    let contexts: WorkContextStore
    @Published private(set) var connecting = false
    @Published var message = ""
    private let defaults: UserDefaults
    private var clients: [String: any AtlassianReading] = [:]
    private var clientPresets: [String: AtlassianPreset] = [:]
    private var keychains: [String: AtlassianKeychain] = [:]
    private var configuration: [String: String]
    private var subscription: AnyCancellable?
    private var login: AtlassianWebLogin?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; contexts = WorkContextStore(defaults: defaults); configuration = defaults.dictionary(forKey: "workConnections") as? [String: String] ?? [:]
        subscription = contexts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    func preset(project: ProjectContext?, profile: ProfileSnapshot?) -> AtlassianPreset? {
        guard let profile else { return nil }; let presets = profile.profile.services?.atlassian ?? []
        return presets.first { $0.id == configuration[(profile.id + ":" + (project?.path ?? ""))] } ?? presets.first
    }
    func choose(_ id: String, project: ProjectContext?, profile: ProfileSnapshot?) {
        guard let project, let profile, profile.profile.services?.atlassian?.contains(where: { $0.id == id }) == true else { return }
        configuration[profile.id + ":" + project.path] = id; defaults.set(configuration, forKey: "workConnections")
    }
    private func keychain(_ preset: AtlassianPreset, profile: ProfileSnapshot) -> AtlassianKeychain {
        let namespace = preset.credentialNamespace(profileID: profile.id)
        if let keychain = keychains[namespace] { return keychain }
        let keychain = AtlassianKeychain(namespace: namespace); keychains[namespace] = keychain; return keychain
    }
    func bind(owner: String, project: ProjectContext?, profile: ProfileSnapshot?) {
        let preset = preset(project: project, profile: profile)
        var client: (any AtlassianReading)?
        if let preset, let profile {
            let namespace = preset.credentialNamespace(profileID: profile.id), keychain = keychain(preset, profile: profile)
            if clientPresets[namespace] != preset { clients[namespace] = nil }
            clientPresets[namespace] = preset
            client = clients[namespace]
            if client == nil {
                if preset.deployment == .cloud {
                    if keychain.load() != nil { client = AtlassianCloud(preset: preset, keychain: keychain) }
                } else if let headers = try? keychain.restHeaders(preset) { client = AtlassianREST(preset: preset, headers: headers) }
                if let client { clients[namespace] = client }
            }
        }
        contexts.bind(owner: owner, project: project, profileID: profile?.id, preset: preset, client: client)
    }
    func refresh(owner: String, project: ProjectContext?, profile: ProfileSnapshot?, force: Bool = false) async {
        bind(owner: owner, project: project, profile: profile); await contexts.refresh(owner, force: force)
    }
    func connect(project: ProjectContext?, profile: ProfileSnapshot?, appearance: PanelAppearanceStore? = nil) async {
        guard !connecting, let profile, let preset = preset(project: project, profile: profile) else { message = text("work.unconfigured"); return }
        connecting = true; message = ""; defer { connecting = false; login = nil }
        let keychain = keychain(preset, profile: profile), namespace = preset.credentialNamespace(profileID: profile.id)
        do {
            if preset.deployment == .cloud {
                let cloud = AtlassianCloud(preset: preset, keychain: keychain); try await cloud.connect(interactive: true); clients[namespace] = cloud
            } else if preset.authentication == .webSession {
                let login = AtlassianWebLogin(preset: preset, keychain: keychain, appearance: appearance); self.login = login; try await login.run()
                clients[namespace] = AtlassianREST(preset: preset, headers: try keychain.restHeaders(preset))
            } else {
                let alert = NSAlert(); alert.messageText = text("work.connect") + " · " + preset.title; alert.informativeText = text("work.token.instructions")
                alert.addButton(withTitle: text("work.connect")); alert.addButton(withTitle: text("cancel"))
                let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
                var fields: [String: NSSecureTextField] = [:]
                defer { fields.values.forEach { $0.stringValue = "" } }
                for service in ["jira", "confluence"] where (service == "jira" ? preset.jiraURL : preset.confluenceURL) != nil {
                    stack.addArrangedSubview(NSTextField(labelWithString: service.capitalized)); let field = NSSecureTextField(); field.placeholderString = "Personal Access Token"; field.translatesAutoresizingMaskIntoConstraints = false; field.widthAnchor.constraint(equalToConstant: 360).isActive = true; stack.addArrangedSubview(field); fields[service] = field
                }
                alert.accessoryView = stack
                guard NativeRetroDialog.run(alert, store: appearance) == .alertFirstButtonReturn else { throw AtlassianError.cancelled }
                let headers = fields.mapValues { ["Authorization": "Bearer " + $0.stringValue] }
                let rest = AtlassianREST(preset: preset, headers: headers)
                for service in fields.keys { try await rest.verifyIdentity(service) }
                try keychain.writeRESTSessions(fields.mapValues { Data($0.stringValue.utf8) })
                for field in fields.values { field.stringValue = "" }
                clients[namespace] = rest
            }
            clientPresets[namespace] = preset
            contexts.invalidateConnection(namespace)
            message = text("work.connected")
        } catch { message = text("work.error." + ((error as? AtlassianError)?.rawValue ?? "network")) }
    }
    func disconnect(project: ProjectContext?, profile: ProfileSnapshot?) {
        guard let profile, let preset = preset(project: project, profile: profile) else { return }
        let keychain = keychain(preset, profile: profile); keychain.clear(); keychain.remove("restSessions"); keychain.remove("jira"); keychain.remove("confluence")
        clients[preset.credentialNamespace(profileID: profile.id)] = nil; message = text("work.disconnected")
        contexts.invalidateConnection(preset.credentialNamespace(profileID: profile.id))
    }
}

// MARK: - Selected evidence without implicit execution

extension TaskCoordinator {
    func workEvidence(project: ProjectContext?) -> [WorkReportEvidence] {
        guard let project else { return [] }
        let builds = builds.records.filter { $0.project.path == project.path && !$0.status.isPending }.suffix(20).map {
            WorkReportEvidence(id: "build:" + $0.id.uuidString, title: $0.parameters.operation.rawValue + " · " + $0.parameters.scheme, result: $0.parameters.operation == .test ? "verificationRequired" : $0.status.rawValue)
        }
        let simulator = simulatorScreen.records.filter { $0.project.path == project.path && !$0.status.isPending }.suffix(10).map {
            WorkReportEvidence(id: "simulator:" + $0.id.uuidString, title: text("panel.block.simulators"), result: $0.status.rawValue + " · " + text("work.criteria.unverified"))
        }
        return Array(builds) + Array(simulator)
    }
    func workReport(owner: String, project: ProjectContext?, selected: [String]) async throws -> String {
        guard selected.count <= 20, Set(selected).count == selected.count else { throw AtlassianError.invalidReference }
        let identity = work.contexts.currentIdentity(owner), available = workEvidence(project: project)
        var evidence: [WorkReportEvidence] = []
        for id in selected {
            guard var item = available.first(where: { $0.id == id }) else { throw AtlassianError.invalidReference }
            if id.hasPrefix("build:"), let uuid = UUID(uuidString: String(id.dropFirst(6))), let record = builds.activity(uuid) {
                let result = try await builds.result(uuid)
                if record.parameters.operation == .test { item.result = result.verification?.verdict ?? "unavailable" }
                if let revision = record.sourceProvenance?.finished {
                    let current = try? await Task.detached { try SourceRevisionReader.capture(path: record.project.path, exclusions: record.sourceExclusions ?? []) }.value
                    item.result += " · " + (current == revision ? "current" : current == nil ? "unknown" : "stale")
                } else { item.result += " · unknown" }
                if let path = record.resultBundlePath { item.reference = path }
                guard builds.activity(uuid)?.stateRevision == record.stateRevision else { throw AtlassianError.staleContext }
            }
            evidence.append(item)
        }
        guard work.contexts.currentIdentity(owner) == identity else { throw AtlassianError.staleContext }
        return WorkReport.draft(issue: work.contexts.snapshot(owner).issue, evidence: evidence)
    }
}
