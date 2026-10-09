// Created by Василий Маслов on 07.10.2026.
import Combine
import Foundation

/// One durable operation owns the checkout through scripted steps and external agent resolution.
@MainActor public final class BranchSwitchCoordinator: ObservableObject {
    @Published public private(set) var operations: [BranchSwitchOperation] = []
    @Published public private(set) var preferences: [String: Bool]
    public var onChange: (() -> Void)?
    public var openManualChat: ((URL) -> Bool)?
    public var mayStart: (() -> Bool)?
    public var active: BranchSwitchOperation? { self.operations.last(where: { $0.phase.holdsCheckout }) }
    public var hasPending: Bool { self.active != nil }
    public var isExecuting: Bool { self.execution != nil }
    private let defaults: UserDefaults
    private let git: BranchSwitchGit
    private var execution: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    private var panels: [String: (path: String, date: Date)] = [:]

    public init(defaults: UserDefaults = .standard, temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.defaults = defaults; self.git = BranchSwitchGit(temporaryRoot: temporaryRoot)
        self.preferences = defaults.dictionary(forKey: "branchRebasePreferences") as? [String: Bool] ?? [:]
        if let data = defaults.data(forKey: "branchSwitchOperations"), let saved = try? JSONDecoder().decode([BranchSwitchOperation].self, from: data) {
            self.operations = saved.map { record in
                var recovered = record
                if recovered.phase.holdsCheckout { recovered.phase = .needsReview; recovered.delivery = .unknown }
                return recovered
            }
        }
    }

    // MARK: - Intent and local execution

    public func rebaseEnabled(path: String) -> Bool { self.preferences[self.canonical(path)] ?? false }
    public func setRebase(_ enabled: Bool, path: String) throws {
        guard !self.hasPending else { throw BranchSwitchError.blocked }
        self.preferences[self.canonical(path)] = enabled
        self.defaults.set(self.preferences, forKey: "branchRebasePreferences"); self.onChange?()
    }
    public func latest(path: String) -> BranchSwitchOperation? { self.operations.last { $0.source.path == self.canonical(path) } }

    /// Reusing a request ID returns the original operation; different intent is rejected.
    @discardableResult public func start(id: UUID, project: ProjectContext, target: String, threadID: String? = nil) throws -> BranchSwitchOperation {
        if let old = self.operations.first(where: { $0.id == id }) {
            guard old.source == project, old.target == target, old.sourceThreadID == threadID else { throw BranchSwitchError.context }
            return old
        }
        guard !self.hasPending, self.execution == nil, self.mayStart?() != false else { throw BranchSwitchError.blocked }
        guard !target.isEmpty, target.utf8.count <= 1024, !target.contains("\0") else { throw BranchSwitchError.missing }
        let record = BranchSwitchOperation(id: id, source: project, target: target, rebase: self.rebaseEnabled(path: project.path), sourceThreadID: threadID)
        try self.save(record)
        self.execution = Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.git.prepare(record, update: self.updater) }
            catch { await self.failed(id: id, error: error) }
            self.execution = nil; self.onChange?(); self.scheduleHandoff()
        }
        return record
    }

    public func operation(_ id: UUID) throws -> BranchSwitchOperation {
        guard let op = self.operations.first(where: { $0.id == id }) else { throw BranchSwitchError.missing }; return op
    }
    public func claim(_ id: UUID, threadID: String) throws -> BranchSwitchOperation {
        var op = try self.operation(id)
        guard !threadID.isEmpty, threadID.utf8.count <= 256, self.execution == nil,
              [.awaitingAgent, .resolving].contains(op.phase), op.ownerThreadID == nil || op.ownerThreadID == threadID else { throw BranchSwitchError.ownership }
        op.ownerThreadID = threadID; op.phase = .resolving
        self.fallback?.cancel(); self.fallback = nil
        try self.save(op); return op
    }
    public func complete(_ id: UUID, threadID: String) async throws -> BranchSwitchOperation {
        let op = try self.operation(id)
        if op.phase == .succeeded, op.ownerThreadID == threadID { return op }
        guard self.execution == nil, op.phase == .resolving, op.ownerThreadID == threadID else { throw BranchSwitchError.ownership }
        // Reserve synchronously before awaiting Git, including duplicate calls from the same owner.
        self.execution = Task { }
        defer { self.execution = nil; self.onChange?() }
        do { return try await self.git.finish(op, update: self.updater) }
        catch {
            var record = try self.operation(id); record.error = self.errorText(error); record.phase = (error as? BranchSwitchError) == .review ? .resolving : .needsReview
            try self.save(record); throw error
        }
    }
    public func cancel(_ id: UUID, threadID: String? = nil) async throws -> BranchSwitchOperation {
        let op = try self.operation(id)
        guard op.phase.holdsCheckout, op.ownerThreadID == nil || op.ownerThreadID == threadID || op.phase == .needsReview && threadID == nil else { throw BranchSwitchError.ownership }
        self.fallback?.cancel(); self.fallback = nil
        if let execution = self.execution {
            guard op.ownerThreadID == nil else { throw BranchSwitchError.blocked }
            execution.cancel(); await execution.value
            return try self.operation(id)
        }
        self.execution = Task { }
        defer { self.execution = nil; self.onChange?() }
        return try await self.git.cancel(op, update: self.updater)
    }

    // MARK: - One-shot panel delivery

    public func heartbeat(threadID: String, path: String, canSend: Bool) {
        if canSend { self.panels[threadID] = (self.canonical(path), Date()) } else { self.panels[threadID] = nil }
    }
    public func reserveDelivery(threadID: String, path: String) throws -> BranchSwitchOperation? {
        guard var op = self.active, op.phase == .awaitingAgent, op.delivery == .pending,
              op.source.path == self.canonical(path), let panel = self.panels[threadID], panel.path == op.source.path,
              Date().timeIntervalSince(panel.date) < 15 else { return nil }
        op.delivery = .reserved; op.deliveryThreadID = threadID; try self.save(op)
        self.fallback?.cancel(); self.fallback = nil
        self.fallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, var uncertain = try? self.operation(op.id),
                  uncertain.delivery == .reserved else { return }
            uncertain.delivery = .unknown; try? self.save(uncertain)
        }
        return op
    }
    public func deliveryResult(_ id: UUID, threadID: String, sent: Bool) throws {
        var op = try self.operation(id)
        guard op.delivery == .reserved, op.deliveryThreadID == threadID else { throw BranchSwitchError.ownership }
        self.fallback?.cancel(); self.fallback = nil
        op.delivery = sent ? .sent : .unknown; try self.save(op)
    }
    public func openChat(_ id: UUID) throws {
        var op = try self.operation(id)
        guard op.phase == .awaitingAgent, op.ownerThreadID == nil, op.delivery != .reserved,
              let url = BranchSwitchBridge.newChatURL(op) else { throw BranchSwitchError.ownership }
        guard self.openManualChat?(url) == true else { throw BranchSwitchError.command("branch.codex.unavailable") }
        op.delivery = .manual; try self.save(op)
    }
    private func scheduleHandoff() {
        guard let op = self.active, op.phase == .awaitingAgent, op.delivery == .pending else { return }
        let live = self.panels.values.contains { $0.path == op.source.path && Date().timeIntervalSince($0.date) < 15 }
        self.fallback?.cancel()
        self.fallback = Task { [weak self] in
            if live { try? await Task.sleep(for: .seconds(7)) }
            guard !Task.isCancelled, let self, let current = self.active, current.id == op.id,
                  current.phase == .awaitingAgent, current.delivery == .pending else { return }
            do { try self.openChat(op.id) }
            catch { var failed = current; failed.error = self.errorText(error); try? self.save(failed) }
        }
    }

    // MARK: - Journal and recovery

    private var updater: BranchSwitchGit.Update { { [weak self] op in try await self?.save(op) } }
    private func save(_ initial: BranchSwitchOperation) throws {
        var op = initial
        if op.phase == .succeeded {
            op.completedAt = self.operations.first(where: { $0.id == op.id })?.completedAt ?? op.completedAt ?? Date()
        }
        var next = self.operations
        if let index = next.firstIndex(where: { $0.id == op.id }) { next[index] = op } else { next.append(op) }
        if next.count > 100 { next.removeFirst(next.count - 100) }
        let data = try JSONEncoder().encode(next)
        self.defaults.set(data, forKey: "branchSwitchOperations")
        self.operations = next; self.onChange?()
    }
    private func failed(id: UUID, error: any Error) async {
        guard var op = try? self.operation(id) else { return }
        op.error = self.errorText(error)
        _ = await self.git.recover(op, cancelled: error is CancellationError || Task.isCancelled, update: self.updater)
    }
    private func errorText(_ error: any Error) -> String {
        if case let BranchSwitchError.command(output) = error { return DiagnosticText.bounded(DiagnosticText.clean(output), limit: 2000).text }
        if let error = error as? BranchSwitchError { return "branch.error." + String(describing: error) }
        return error is CancellationError ? "branch.cancelled" : "branch.error"
    }
    private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
}
