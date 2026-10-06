// Created by Василий Маслов on 06.10.2026.
import Combine
import Foundation

/// Shares one CIState per credential reference/server/project. Account changes invalidate its cache.
/// Codex leases retain their own checkout; a displayed active run outlives its last panel lease.
@MainActor public final class CIActivityMonitor: ObservableObject {
    @Published public private(set) var desktopState: CIState?
    @Published public private(set) var overlay: CICompactSummary?
    private struct Entry {
        let state: CIState
        let subscription: AnyCancellable
    }
    private struct Lease {
        let key: String
        let checkout: String
        let date: Date
    }
    private var entries: [String: Entry] = [:]
    private var leases: [String: Lease] = [:]
    private var desktopKey: String?
    private var desktopCheckout: String?
    private var hidden: Set<String> = []
    private var deadline: Date?
    private var timer: Task<Void, Never>?
    private var stopped = false
    private let makeState: (CIContext) -> CIState
    private let now: () -> Date
    private let completionDelay: TimeInterval
    public var branchOwnerPattern: String? { didSet { for entry in self.entries.values { entry.state.branchOwnerPattern = self.branchOwnerPattern } } }
    public var jenkins: JenkinsConnection?
    public var runs: [RemoteTestRun] = []

    public init(completionDelay: TimeInterval = 5, now: @escaping () -> Date = { .now }, makeState: @escaping (CIContext) -> CIState) {
        self.completionDelay = completionDelay; self.now = now; self.makeState = makeState
    }

    // MARK: - Checkout interests

    private func key(_ context: CIContext) -> String {
        context.connection.id.uuidString + ":" + context.connection.baseURL.absoluteString + ":" + String(context.connection.projectID)
    }

    private func register(_ context: CIContext) -> CIState {
        let key = self.key(context)
        if let state = self.entries[key]?.state { return state }
        let state = self.makeState(context)
        state.branchOwnerPattern = self.branchOwnerPattern
        state.select(context); state.setJenkinsRuns(self.runs, connection: self.jenkins)
        let subscription = state.objectWillChange.sink { [weak self] in
            // Published values are committed after objectWillChange; never select the preceding snapshot.
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.reconcile(); self.objectWillChange.send()
            }
        }
        self.entries[key] = Entry(state: state, subscription: subscription)
        self.startTimer()
        return state
    }

    public func setDesktop(_ context: CIContext?) {
        let old = self.desktopState
        self.desktopKey = context.map(self.key); self.desktopCheckout = context?.checkout
        self.desktopState = context.map(self.register)
        // Shared remote requests retain the current desktop checkout/branch as its native context.
        if let context, let state = self.desktopState, state.context != context {
            let selected = state.visible ? state.selectedPipelineID : nil
            state.select(context)
            if let selected { state.revealPipeline(selected) }
        }
        if old !== self.desktopState { old?.setVisible(false) }
        self.reconcile()
    }

    /// A get_state heartbeat adds no cross-chat data; its response is remapped to this checkout.
    public func heartbeat(threadID: String, context: CIContext?) -> CICompactSummary? {
        guard !self.stopped else { return nil }
        guard let context else { self.leases[threadID] = nil; self.reconcile(); return nil }
        let state = self.register(context)
        self.leases[threadID] = Lease(key: self.key(context), checkout: context.checkout, date: self.now())
        self.reconcile()
        var summary = state.compactSummary
        summary?.checkout = context.checkout
        return summary
    }

    public func updateRuns(_ runs: [RemoteTestRun], jenkins: JenkinsConnection?) {
        self.runs = runs; self.jenkins = jenkins
        for entry in self.entries.values { entry.state.setJenkinsRuns(runs, connection: jenkins) }
    }

    public func credentialsChanged() {
        self.overlay = nil; self.deadline = nil
        for entry in self.entries.values { entry.state.credentialsChanged() }
    }

    public func state(for summary: CICompactSummary) -> CIState? {
        for entry in self.entries.values {
            guard let context = entry.state.context else { continue }
            let account = entry.state.user.map { String($0.id) } ?? "unknown"
            let scope = context.connection.id.uuidString + ":" + String(context.connection.projectID) + ":" + account
            if summary.scopeID == scope { return entry.state }
        }
        return nil
    }

    public func hideCI() {
        if let overlay { self.hidden.insert(overlay.identity) }
        self.overlay = nil; self.deadline = nil
        self.reconcile()
    }

    // MARK: - Selection and lifetime

    /// Exposed for deterministic lease/deadline fixtures, using the injected clock.
    public func reconcile() {
        guard !self.stopped else { return }
        let now = self.now()
        self.leases = self.leases.filter { now.timeIntervalSince($0.value.date) < 30 }
        let interested = Set(self.leases.values.map(\.key)).union(self.desktopKey.map { [$0] } ?? [])
        let currentState = self.overlay.flatMap(self.state)
        let summaries = self.entries.filter { interested.contains($0.key) || $0.value.state === currentState }.values.compactMap { $0.state.compactSummary }
        let active = summaries.filter(\.active).sorted(by: Self.newest).first
        if let current = self.overlay, let state = currentState,
           let entry = state.personalEntries.first(where: { $0.id == current.id }),
           var updated = state.compactSummary(for: entry) {
            updated.checkout = current.checkout
            if updated != current { self.overlay = updated }
            if !updated.active, self.deadline == nil, ["success", "canceled", "cancelled", "skipped"].contains(updated.status) {
                self.deadline = now.addingTimeInterval(self.completionDelay)
            }
        }
        if let deadline, now >= deadline {
            if let overlay { self.hidden.insert(overlay.identity) }
            self.overlay = nil; self.deadline = nil
        }
        if let active, !self.hidden.contains(active.identity) {
            let replace: Bool
            if let current = self.overlay {
                replace = current.active ? Self.newest(active, current) : self.deadline == nil && Self.newest(active, current)
            } else { replace = true }
            if replace {
                self.overlay = active; self.deadline = nil
                // Prefer the desktop checkout when several checkouts share a remote project.
                if self.state(for: active) === self.desktopState, let checkout = self.desktopCheckout {
                    self.overlay?.checkout = checkout
                } else if let lease = self.leases.values.sorted(by: { $0.date == $1.date ? $0.checkout < $1.checkout : $0.date > $1.date }).first(where: { self.entries[$0.key]?.state === self.state(for: active) }) {
                    self.overlay?.checkout = lease.checkout
                }
            }
        }
        let retained = self.overlay.flatMap(self.state)
        for (key, entry) in self.entries {
            entry.state.setMonitoring(interested.contains(key) || self.overlay?.active == true && entry.state === retained)
        }
    }

    private static func newest(_ left: CICompactSummary, _ right: CICompactSummary) -> Bool {
        if left.createdAt != right.createdAt { return (left.createdAt ?? .distantPast) > (right.createdAt ?? .distantPast) }
        if left.pipelineID != right.pipelineID { return (left.pipelineID ?? 0) > (right.pipelineID ?? 0) }
        return left.identity > right.identity
    }

    private func startTimer() {
        guard self.timer == nil else { return }
        self.timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.stopped else { return }
                self.reconcile()
            }
        }
    }

    public func stop() {
        self.stopped = true; self.timer?.cancel(); self.timer = nil
        for entry in self.entries.values { entry.state.setVisible(false); entry.state.setMonitoring(false) }
        self.leases = [:]; self.overlay = nil
    }
}
