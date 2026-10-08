//
//  AIUsageCoordinator.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import Combine
import Foundation
import MimicCore

/// App-owned refresh and activity lifecycle. Closing the panel never stops the menu-bar monitor.
@MainActor
final class AIUsageCoordinator: ObservableObject {
    @Published private(set) var histories: [AIProvider: [AIUsageDailyPoint]] = [:]
    @Published private(set) var unknownModels: [AIProvider: [String]] = [:]
    @Published private var expansionOverrides: [AIProvider: Bool] = [:]
    @Published private(set) var snapshots: [AIProvider: AIUsageSnapshot] = [:]
    @Published private(set) var errors: [AIProvider: AIUsageError] = [:]
    @Published private(set) var refreshing: Set<AIProvider> = []
    @Published private(set) var currentDate: Date
    @Published private(set) var settings: AIUsageSettings
    @Published private(set) var fallbackProvider: AIProvider
    private(set) var nextRefresh: [AIProvider: Date] = [:]
    private let defaults: UserDefaults
    private let adapters: [AIProvider: any AIUsageFetching]
    private let scan: () async -> AIUsageActivity?
    private let scanUsage: (() async -> AIUsageScanResult)?
    private let clock: () -> Date
    private var revisions: [AIProvider: String] = [:]
    private var failures: [AIProvider: Int] = [:]
    private var operationIDs: [AIProvider: UUID] = [:]
    private var operations: [AIProvider: Task<Void, Never>] = [:]
    private var lifecycle: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var stopped = false
    private var sleeping = false
    private var scanning = false

    init(defaults: UserDefaults = .standard, fallback: AIProvider = .codex, adapters: [any AIUsageFetching], scan: @escaping () async -> AIUsageActivity? = { nil }, scanUsage: (() async -> AIUsageScanResult)? = nil, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.fallbackProvider = fallback
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
        self.scan = scan; self.scanUsage = scanUsage; self.clock = clock; self.currentDate = clock()
        self.settings = defaults.data(forKey: "ai.usage.settings").flatMap { try? JSONDecoder().decode(AIUsageSettings.self, from: $0) } ?? AIUsageSettings()
    }
    var activeProvider: AIProvider { self.settings.lastProvider ?? self.fallbackProvider }
    var activePeriod: AIUsagePeriod {
        self.snapshots[self.activeProvider]?.period(preference: self.settings.preference(for: self.activeProvider)) ?? (self.settings.preference(for: self.activeProvider) == .weekly ? .weekly : .session)
    }
    var percentage: String {
        guard let value = self.snapshots[self.activeProvider]?.percentage(preference: self.settings.preference(for: self.activeProvider), at: self.currentDate) else { return "—" }
        return "\(value)%"
    }
    var statusDescription: String {
        let provider = self.activeProvider, snapshot = self.snapshots[provider]
        var parts = [provider == .codex ? "Codex" : "Claude Code", snapshot?.plan ?? text("usage.plan.unknown"), text("usage.period." + self.activePeriod.rawValue), self.percentage + " " + text("usage.remaining")]
        if let reset = snapshot?.window(self.activePeriod)?.resetsAt { parts.append(text("usage.reset") + " " + reset.formatted(date: .abbreviated, time: .shortened)) }
        if self.percentage == "—" { parts.append(self.errors[provider].map { text($0.localizationKey) } ?? text("usage.unavailable")) }
        return parts.joined(separator: " · ")
    }
    // MARK: - Provider disclosure

    func isExpanded(_ provider: AIProvider) -> Bool { self.expansionOverrides[provider] ?? (provider == self.activeProvider) }
    func percentage(for provider: AIProvider) -> String {
        self.snapshots[provider]?.percentage(preference: self.settings.preference(for: provider), at: self.currentDate).map { "\($0)%" } ?? "—"
    }
    func toggleProvider(_ provider: AIProvider) {
        self.expansionOverrides[provider] = !self.isExpanded(provider)
        if self.isExpanded(provider) { self.refreshIfNeeded(provider) }
    }
    func detailsOpened() {
        self.currentDate = self.clock()
        for provider in AIProvider.allCases where self.isExpanded(provider) { self.refreshIfNeeded(provider) }
    }
    func panelDidClose() { self.expansionOverrides.removeAll() }
    func refreshVisible() {
        for provider in AIProvider.allCases where self.isExpanded(provider) { self.refresh(provider: provider, manual: true) }
    }
    private func refreshIfNeeded(_ provider: AIProvider) {
        let snapshot = self.snapshots[provider]
        if snapshot == nil || snapshot?.isStale(at: self.currentDate) == true || snapshot?.windows.contains(where: { $0.hasReset(at: self.currentDate) }) == true {
            self.refresh(provider: provider)
        }
    }
    func setFallback(_ provider: AIProvider) {
        let previous = self.activeProvider
        if self.fallbackProvider != provider { self.fallbackProvider = provider }
        if previous != self.activeProvider {
            self.expansionOverrides.removeAll()
            self.refresh(provider: self.activeProvider)
        }
    }
    func setPreference(_ preference: AIUsagePreference, for provider: AIProvider) {
        if provider == .codex { self.settings.codex = preference } else { self.settings.claude = preference }
        self.persist()
    }
    func record(_ activity: AIUsageActivity) {
        guard activity.date <= self.clock(), self.settings.lastActivity.map({ activity.date > $0 }) ?? true else { return }
        let changed = self.activeProvider != activity.provider
        self.settings.lastProvider = activity.provider; self.settings.lastActivity = activity.date; self.persist()
        if changed {
            self.expansionOverrides.removeAll()
            if self.errors[activity.provider] == nil { self.nextRefresh[activity.provider] = nil }
            self.refresh(provider: activity.provider)
        }
    }

    // MARK: - Monitoring lifecycle

    func start() {
        guard self.lifecycle == nil else { return }
        self.stopped = false
        let center = NSWorkspace.shared.notificationCenter
        self.wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.wake() } }
        self.sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleep() } }
        self.lifecycle = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
    func stop() {
        self.stopped = true; self.lifecycle?.cancel(); self.lifecycle = nil
        self.cancelOperations()
        let center = NSWorkspace.shared.notificationCenter
        if let wakeObserver { center.removeObserver(wakeObserver) }
        if let sleepObserver { center.removeObserver(sleepObserver) }
        self.wakeObserver = nil; self.sleepObserver = nil
    }
    func sleep() { self.sleeping = true; self.cancelOperations() }
    func wake() {
        self.sleeping = false; self.currentDate = self.clock()
        self.checkRevisions()
        for provider in [self.activeProvider] {
            // Wake does not bypass provider throttling.
            if self.errors[provider] == nil { self.nextRefresh[provider] = nil }
        }
        Task { @MainActor [weak self] in await self?.tick() }
    }
    func tick() async {
        guard !self.stopped, !self.sleeping else { return }
        let interval = FramePerformanceTrace.begin("AI usage tick")
        defer { FramePerformanceTrace.end("AI usage tick", interval) }
        let now = self.clock()
        if self.currentDate != now { self.currentDate = now }
        self.checkRevisions()
        if !self.scanning {
            self.scanning = true
            let result: AIUsageScanResult
            if let scanUsage = self.scanUsage { result = await scanUsage() }
            else { result = AIUsageScanResult(activity: await self.scan()) }
            self.scanning = false
            guard !self.stopped, !self.sleeping else { return }
            if self.histories != result.histories { self.histories = result.histories }
            if self.unknownModels != result.unknownModels { self.unknownModels = result.unknownModels }
            if let activity = result.activity { self.record(activity) }
        }
        for provider in [self.activeProvider] {
            if self.errors[provider] == nil, let snapshot = self.snapshots[provider], snapshot.windows.contains(where: { $0.hasReset(at: self.currentDate) && !$0.hasReset(at: snapshot.fetchedAt) }) { self.nextRefresh[provider] = nil }
            if self.nextRefresh[provider].map({ $0 <= self.currentDate }) ?? true { self.refresh(provider: provider) }
        }
    }

    // MARK: - Coalesced refreshes

    func refreshAll(manual: Bool = true) { for provider in AIProvider.allCases { self.refresh(provider: provider, manual: manual) } }
    func refresh(provider: AIProvider, manual: Bool = false) {
        guard !self.stopped, !self.sleeping, let adapter = self.adapters[provider] else { return }
        self.checkRevision(provider, adapter: adapter)
        guard self.operations[provider] == nil else { return }
        if let retry = self.nextRefresh[provider], retry > self.clock() {
            if case .rateLimited = self.errors[provider] { return }
            if !manual { return }
        }
        let revision = adapter.revision(); self.revisions[provider] = revision
        let operationID = UUID(); self.operationIDs[provider] = operationID
        self.refreshing.insert(provider)
        self.operations[provider] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await adapter.fetch(manual: manual)
                let snapshot = result.snapshot
                guard !Task.isCancelled, !self.stopped, self.operationIDs[provider] == operationID else { return }
                guard adapter.revision() == result.revision else { self.changed(provider, revision: adapter.revision()); return }
                self.revisions[provider] = result.revision
                self.snapshots[provider] = snapshot; self.errors[provider] = nil; self.failures[provider] = 0
                self.nextRefresh[provider] = self.clock().addingTimeInterval(300)
            } catch {
                guard !Task.isCancelled, !self.stopped, self.revisions[provider] == revision, self.operationIDs[provider] == operationID else { return }
                let failure = error as? AIUsageError ?? .network
                if failure == .accountChanged || adapter.revision() != revision { self.changed(provider, revision: adapter.revision()); return }
                self.errors[provider] = failure
                if failure == .authentication || failure == .keychainAccess { self.snapshots[provider] = nil }
                let count = min(6, (self.failures[provider] ?? 0) + 1); self.failures[provider] = count
                let delay = min(1800, 30 * pow(2, Double(count - 1)))
                if case let .rateLimited(retryAt) = failure { self.nextRefresh[provider] = max(retryAt ?? self.clock().addingTimeInterval(300), self.clock().addingTimeInterval(30)) }
                else if failure == .authentication || failure == .keychainAccess || failure == .missingCLI { self.nextRefresh[provider] = self.clock().addingTimeInterval(300) }
                else { self.nextRefresh[provider] = self.clock().addingTimeInterval(delay) }
            }
            guard self.operationIDs[provider] == operationID else { return }
            self.operations[provider] = nil; self.operationIDs[provider] = nil; self.refreshing.remove(provider); self.currentDate = self.clock()
        }
    }
    private func checkRevisions() { for (provider, adapter) in self.adapters { self.checkRevision(provider, adapter: adapter) } }
    private func checkRevision(_ provider: AIProvider, adapter: any AIUsageFetching) {
        let revision = adapter.revision()
        if let old = self.revisions[provider], old != revision { self.changed(provider, revision: revision) }
        else { self.revisions[provider] = revision }
    }
    private func changed(_ provider: AIProvider, revision: String) {
        self.operations[provider]?.cancel(); self.operations[provider] = nil; self.operationIDs[provider] = nil; self.refreshing.remove(provider)
        self.revisions[provider] = revision; self.snapshots[provider] = nil; self.errors[provider] = nil; self.failures[provider] = nil; self.nextRefresh[provider] = nil
    }
    private func cancelOperations() {
        for operation in self.operations.values { operation.cancel() }
        self.operations.removeAll(); self.operationIDs.removeAll(); self.refreshing.removeAll()
        // Operation IDs reject late callbacks; retain login revisions to detect account changes during sleep.
    }
    private func persist() { if let data = try? JSONEncoder().encode(self.settings) { self.defaults.set(data, forKey: "ai.usage.settings") } }
}
