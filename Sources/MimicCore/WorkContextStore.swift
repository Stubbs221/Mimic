// Created by Василий Маслов on 13.10.2026.
import Foundation
import Combine

/// Owns per-observer selection and generation checks independently of build execution queues.
@MainActor public final class WorkContextStore: ObservableObject {
    @Published public private(set) var snapshots: [String: WorkContextSnapshot] = [:]
    private struct Binding { var identity: String; var preset: AtlassianPreset; var client: (any AtlassianReading)?; var namespace: String }
    private struct Cached { var issue: WorkIssue; var date: Date }
    private var bindings: [String: Binding] = [:]
    private var operations: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var selections: [String: UUID] = [:]
    private var cache: [String: Cached] = [:]
    private var retryAfter: [String: Date] = [:]
    private let defaults: UserDefaults
    private var choices: [String: String]
    private let now: () -> Date

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now; self.choices = defaults.dictionary(forKey: "workIssueChoices") as? [String: String] ?? [:]
    }
    public func snapshot(_ owner: String) -> WorkContextSnapshot { snapshots[owner] ?? .init() }

    /// Rebinding cancels only this observer's read. Late results never replace another branch.
    public func bind(owner: String, project: ProjectContext?, profileID: String?, preset: AtlassianPreset?, client: (any AtlassianReading)?) {
        guard let project, let profileID, let preset else { release(owner); return }
        let namespace = preset.sourceNamespace(profileID: profileID)
        let identity = [namespace, project.path, project.branch].joined(separator: "\n")
        if bindings[owner]?.identity == identity { bindings[owner]?.client = client; return }
        if let old = bindings[owner] { choices[owner + "\n" + old.identity] = nil; defaults.set(choices, forKey: "workIssueChoices") }
        retryAfter[owner] = nil
        operations[owner]?.cancel(); operations[owner] = nil; generations[owner] = UUID()
        bindings[owner] = Binding(identity: identity, preset: preset, client: client, namespace: namespace); selections[owner] = UUID()
        var value = WorkContextSnapshot(); value.presetID = preset.id
        value.candidates = WorkReference.keys(in: project.branch).filter { (try? WorkReference.issue($0, preset: preset)) != nil }
        if let chosen = choices[owner + "\n" + identity], (try? WorkReference.issue(chosen, preset: preset)) != nil { value.candidates = [chosen]; value.manual = true }
        value.phase = value.candidates.count > 1 ? "choose" : value.candidates.isEmpty ? "empty" : "idle"
        snapshots[owner] = value
    }

    public func select(_ reference: String, owner: String) throws {
        guard let binding = bindings[owner] else { throw AtlassianError.configuration }
        let key = try WorkReference.issue(reference, preset: binding.preset)
        operations[owner]?.cancel(); generations[owner] = UUID(); selections[owner] = UUID()
        retryAfter[owner] = nil
        if choices.count > 1000 { choices.removeAll() }
        choices[owner + "\n" + binding.identity] = key; defaults.set(choices, forKey: "workIssueChoices")
        var value = WorkContextSnapshot(); value.presetID = binding.preset.id; value.candidates = [key]; value.manual = true; value.phase = "idle"; snapshots[owner] = value
    }

    public func refresh(_ owner: String, force: Bool = false) async {
        guard let binding = bindings[owner], var value = snapshots[owner], value.candidates.count == 1 else { return }
        let key = value.candidates[0], cacheKey = binding.namespace + ":" + key
        if !force, let retry = retryAfter[owner], retry > now() { return }
        if !force, let cached = cache[cacheKey], now().timeIntervalSince(cached.date) < 300 {
            value.issue = cached.issue; value.fetchedAt = cached.date; value.stale = false; value.error = nil; value.phase = "ready"; snapshots[owner] = value; return
        }
        if !force, value.phase == "loading" { return }
        guard let client = binding.client else { value.phase = "authenticationRequired"; value.error = .authenticationRequired; value.stale = value.issue != nil; snapshots[owner] = value; return }
        retryAfter[owner] = nil
        let generation = UUID(); generations[owner] = generation; value.phase = "loading"; value.error = nil; snapshots[owner] = value
        let operation = Task { @MainActor [weak self] in
            do {
                let issue = try await client.issue(key)
                guard !Task.isCancelled, let self, self.generations[owner] == generation, self.bindings[owner]?.identity == binding.identity else { return }
                if self.cache.count >= 100 { self.cache.removeAll() }
                let date = self.now(); self.cache[cacheKey] = Cached(issue: issue, date: date)
                var current = self.snapshot(owner); current.issue = issue; current.phase = "ready"; current.fetchedAt = date; current.error = nil; current.stale = false; self.snapshots[owner] = current
            } catch {
                guard let self, self.generations[owner] == generation else { return }
                var current = self.snapshot(owner); current.error = error as? AtlassianError ?? .network; current.phase = "error"; current.stale = current.issue != nil; self.snapshots[owner] = current
                self.retryAfter[owner] = self.now().addingTimeInterval(current.error == .rateLimited ? 300 : 30)
            }
        }
        operations[owner]?.cancel(); operations[owner] = operation
        await operation.value
        if generations[owner] == generation { operations[owner] = nil }
    }

    public func client(_ owner: String) throws -> any AtlassianReading {
        guard let binding = bindings[owner] else { throw AtlassianError.configuration }
        guard let client = binding.client else { throw AtlassianError.authenticationRequired }; return client
    }
    public func currentIdentity(_ owner: String) -> String? { bindings[owner].map { $0.identity + "\n" + (selections[owner]?.uuidString ?? "") } }
    public func preset(_ owner: String) -> AtlassianPreset? { bindings[owner]?.preset }
    /// Switching account or disconnecting revokes cached content for every observer of that connection.
    public func invalidateConnection(_ credentialNamespace: String) {
        cache = cache.filter { !$0.key.hasPrefix(credentialNamespace + ":") }
        for owner in bindings.keys where bindings[owner]?.namespace.hasPrefix(credentialNamespace + ":") == true {
            operations[owner]?.cancel(); operations[owner] = nil; generations[owner] = UUID(); selections[owner] = UUID(); bindings[owner]?.client = nil
            retryAfter[owner] = nil
            var value = snapshot(owner); value.issue = nil; value.fetchedAt = nil; value.stale = false; value.error = nil
            value.phase = value.candidates.count == 1 ? "idle" : value.candidates.isEmpty ? "empty" : "choose"; snapshots[owner] = value
        }
    }
    public func release(_ owner: String) {
        operations[owner]?.cancel(); operations[owner] = nil; generations[owner] = nil; selections[owner] = nil; bindings[owner] = nil; snapshots[owner] = nil
        retryAfter[owner] = nil
    }
}

/// Reports preserve evidence verdicts; a successful process alone is never a task acceptance verdict.
public struct WorkReportEvidence: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var result: String
    public var reference: String?
    public init(id: String, title: String, result: String, reference: String? = nil) { self.id = id; self.title = title; self.result = result; self.reference = reference }
}
public enum WorkReport {
    public static func draft(issue: WorkIssue?, evidence: [WorkReportEvidence]) -> String {
        var lines = [issue.map { "\($0.key) · \($0.title)\n\($0.url)" } ?? "", "Изменения\nЗаполнить вручную или дополнить анализом агента.", "Проверки"]
        lines += evidence.map { "- \($0.title): \($0.result) [\($0.id)]" + ($0.reference.map { "\n  \($0)" } ?? "") }
        if evidence.isEmpty { lines.append("- Результаты не выбраны.") }
        lines.append("Не проверено\nКритерии приёмки не сопоставлены с результатами автоматически.")
        return lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
