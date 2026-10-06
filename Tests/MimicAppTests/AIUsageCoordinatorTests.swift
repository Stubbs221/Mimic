//
//  AIUsageCoordinatorTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor
private final class UsageClock {
    var date = Date(timeIntervalSince1970: 1000)
}
@MainActor
private final class UsageAdapterFixture: AIUsageFetching {
    let provider: AIProvider
    var generation = "account-1"
    var requests = 0
    var result: Result<AIUsageSnapshot, AIUsageError>?
    var acquiredRevision: String?
    var pendingGenerations: [String] = []
    var pending: [CheckedContinuation<AIUsageFetchResult, any Error>] = []
    init(_ provider: AIProvider) { self.provider = provider }
    func revision() -> String { self.generation }
    func fetch(manual: Bool) async throws -> AIUsageFetchResult {
        self.requests += 1
        if let acquiredRevision { self.generation = acquiredRevision }
        if let result { return AIUsageFetchResult(snapshot: try result.get(), revision: self.generation) }
        return try await withCheckedThrowingContinuation { self.pendingGenerations.append(self.generation); self.pending.append($0) }
    }
    func complete(_ value: AIUsageSnapshot) { self.pending.removeFirst().resume(returning: AIUsageFetchResult(snapshot: value, revision: self.pendingGenerations.removeFirst())) }
}
@MainActor
private struct UsageCoordinatorFixture {
    let suite = "AIUsage-" + UUID().uuidString
    let defaults: UserDefaults
    let clock = UsageClock()
    let codex = UsageAdapterFixture(.codex), claude = UsageAdapterFixture(.claude)
    let coordinator: AIUsageCoordinator
    init(scanUsage: (() async -> AIUsageScanResult)? = nil) throws {
        self.defaults = try #require(UserDefaults(suiteName: self.suite))
        let clock = self.clock
        self.coordinator = AIUsageCoordinator(defaults: self.defaults, adapters: [self.codex, self.claude], scanUsage: scanUsage, clock: { clock.date })
    }
    func snapshot(_ provider: AIProvider = .codex, account: String = "account-1", reset: Date? = nil) -> AIUsageSnapshot {
        AIUsageSnapshot(provider: provider, accountID: account, plan: provider == .codex ? "pro" : "pro", windows: [.init(period: .session, usedPercent: 10, resetsAt: reset), .init(period: .weekly, usedPercent: 25, resetsAt: reset)], fetchedAt: self.clock.date)
    }
    func cleanup() { self.coordinator.stop(); self.defaults.removePersistentDomain(forName: self.suite) }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct AIUsageCoordinatorTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Usage fixture did not settle")
    }
    @Test
    func coalescingFreshnessAndPersistence() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.coordinator.refresh(provider: .codex)
        f.coordinator.refresh(provider: .codex, manual: true)
        try await self.wait { f.codex.pending.count == 1 }
        #expect(f.codex.requests == 1)
        f.codex.complete(f.snapshot())
        try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.percentage == "75%")
        f.coordinator.setPreference(.session, for: .codex)
        #expect(f.coordinator.percentage == "90%")
        f.coordinator.record(.init(provider: .codex, date: f.clock.date))
        let restart = AIUsageCoordinator(defaults: f.defaults, adapters: [], clock: { f.clock.date })
        #expect(restart.settings.codex == .session && restart.activeProvider == .codex)
        #expect(restart.snapshots.isEmpty && restart.percentage == "—")
        let saved = try #require(f.defaults.data(forKey: "ai.usage.settings"))
        let json = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(Set(json.keys) == ["lastProvider", "lastActivity", "codex", "claude"])
        f.clock.date = f.clock.date.addingTimeInterval(300)
        f.codex.result = .failure(.network); f.claude.result = .failure(.authentication)
        await f.coordinator.tick()
        try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.percentage == "—" && f.coordinator.snapshots[.codex] != nil)
    }
    @Test func acceptsRevisionAcquiredDuringFetchAndReplacesAccount() async throws {
        let fixture = try UsageCoordinatorFixture(); defer { fixture.cleanup() }
        fixture.codex.acquiredRevision = "account-2"
        fixture.codex.result = .success(fixture.snapshot(account: "account-2"))
        fixture.coordinator.refresh(provider: .codex)
        try await self.wait { !fixture.coordinator.refreshing.contains(.codex) }
        #expect(fixture.coordinator.snapshots[.codex]?.accountID == "account-2")
        #expect(fixture.codex.requests == 1)
    }

    @Test
    func accountChangeRejectsLateResponsesAndSameRevisionCancellation() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.coordinator.refresh(provider: .codex)
        try await self.wait { f.codex.pending.count == 1 }
        f.codex.generation = "account-2"
        f.coordinator.refresh(provider: .codex)
        try await self.wait { f.codex.pending.count == 2 }
        f.codex.complete(f.snapshot(account: "account-1"))
        await Task.yield()
        #expect(f.coordinator.snapshots[.codex] == nil && f.coordinator.refreshing.contains(.codex))
        f.codex.complete(f.snapshot(account: "account-2"))
        try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.snapshots[.codex]?.accountID == "account-2")
        f.coordinator.refresh(provider: .codex, manual: true)
        try await self.wait { f.codex.pending.count == 1 }
        f.coordinator.sleep(); f.coordinator.wake()
        f.claude.result = .failure(.authentication)
        await f.coordinator.tick()
        try await self.wait { f.codex.pending.count == 2 }
        f.codex.complete(f.snapshot(account: "old-after-sleep"))
        await Task.yield()
        #expect(f.coordinator.refreshing.contains(.codex))
        f.codex.complete(f.snapshot(account: "account-2"))
        try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.snapshots[.codex]?.accountID == "account-2")
    }
    @Test
    func loginReplacementImmediatelyClearsPreviousValues() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.codex.result = .success(f.snapshot()); f.claude.result = .failure(.authentication)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.percentage == "75%")
        f.codex.generation = "signed-out"; f.codex.result = .failure(.authentication)
        await f.coordinator.tick()
        #expect(f.coordinator.snapshots[.codex] == nil && f.coordinator.percentage == "—")
        try await self.wait { f.coordinator.refreshing.isEmpty }
    }
    @Test
    func accountReplacedDuringSleepClearsValuesBeforeWakeRefresh() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.codex.result = .success(f.snapshot()); f.claude.result = .failure(.authentication)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        f.coordinator.sleep(); f.codex.generation = "account-2"
        f.codex.result = .success(f.snapshot(account: "account-2"))
        f.coordinator.wake()
        #expect(f.coordinator.percentage == "—" && f.coordinator.snapshots[.codex] == nil)
        try await self.wait { f.coordinator.snapshots[.codex]?.accountID == "account-2" }
    }
    @Test
    func retryAfterSurvivesManualRefreshAndWake() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        let retry = f.clock.date.addingTimeInterval(600)
        f.codex.result = .failure(.rateLimited(retryAt: retry)); f.claude.result = .failure(.authentication)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        f.coordinator.refreshAll(); f.coordinator.sleep(); f.coordinator.wake()
        await f.coordinator.tick(); await Task.yield()
        #expect(f.codex.requests == 1 && f.coordinator.nextRefresh[.codex] == retry)
        f.clock.date = retry
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.codex.requests == 2)
    }
    @Test
    func networkBackoffAndResetRefetchWithoutInventingFullQuota() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.codex.result = .failure(.timeout); f.claude.result = .failure(.authentication)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.nextRefresh[.codex] == f.clock.date.addingTimeInterval(30))
        f.clock.date = f.clock.date.addingTimeInterval(30)
        f.codex.result = .failure(.network)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.nextRefresh[.codex] == f.clock.date.addingTimeInterval(60))
        let reset = f.clock.date.addingTimeInterval(5)
        f.codex.result = .success(f.snapshot(reset: reset)); f.coordinator.refresh(provider: .codex, manual: true)
        try await self.wait { f.coordinator.refreshing.isEmpty }
        f.clock.date = reset; f.codex.result = .failure(.network)
        await f.coordinator.tick()
        #expect(f.coordinator.percentage == "—")
        try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.snapshots[.codex]?.window(.weekly)?.remainingPercent == 75)
    }
    @Test
    func alreadyElapsedResetInSuccessfulResponseDoesNotPollEveryTick() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.codex.result = .success(f.snapshot(reset: f.clock.date.addingTimeInterval(-1)))
        f.claude.result = .failure(.authentication)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.percentage == "—")
        f.clock.date.addTimeInterval(10)
        await f.coordinator.tick()
        #expect(f.codex.requests == 1)
    }
    @Test
    func globalAndEphemeralActivitySelectTheLastAgent() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.codex.result = .success(f.snapshot()); f.claude.result = .success(f.snapshot(.claude))
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        f.coordinator.record(.init(provider: .claude, date: f.clock.date))
        try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.activeProvider == .claude && f.coordinator.percentage == "90%")
        f.coordinator.record(.init(provider: .codex, date: f.clock.date.addingTimeInterval(-1)))
        #expect(f.coordinator.activeProvider == .claude)
        f.clock.date = f.clock.date.addingTimeInterval(1)
        f.coordinator.record(.init(provider: .codex, date: f.clock.date))
        #expect(f.coordinator.activeProvider == .codex && f.coordinator.percentage == "75%")
        f.coordinator.setFallback(.claude)
        #expect(f.coordinator.activeProvider == .codex)
    }
    @Test
    func inactiveInstalledProviderIsCompactAndNeverPeriodicallyFetched() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.codex.result = .success(f.snapshot()); f.claude.result = .success(f.snapshot(.claude))
        #expect(f.coordinator.isExpanded(.codex) && !f.coordinator.isExpanded(.claude))
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.codex.requests == 1 && f.claude.requests == 0)
        f.clock.date.addTimeInterval(300)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.codex.requests == 2 && f.claude.requests == 0)
        f.coordinator.toggleProvider(.claude)
        #expect(f.coordinator.isExpanded(.claude))
        try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.claude.requests == 1)
        f.clock.date.addTimeInterval(300)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.claude.requests == 1)
        f.coordinator.refreshVisible(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.claude.requests == 2)
        f.coordinator.panelDidClose()
        #expect(f.coordinator.isExpanded(.codex) && !f.coordinator.isExpanded(.claude))
        f.coordinator.refreshVisible(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.claude.requests == 2)
    }
    @Test
    func newInferenceOverridesDisclosureAndRestartsWithLastAgent() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.codex.result = .success(f.snapshot()); f.claude.result = .success(f.snapshot(.claude))
        f.coordinator.toggleProvider(.codex)
        #expect(!f.coordinator.isExpanded(.codex))
        f.coordinator.record(.init(provider: .claude, date: f.clock.date))
        try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.coordinator.isExpanded(.claude) && !f.coordinator.isExpanded(.codex) && f.claude.requests == 1)
        let restart = AIUsageCoordinator(defaults: f.defaults, adapters: [], clock: { f.clock.date })
        #expect(restart.activeProvider == .claude && restart.isExpanded(.claude) && !restart.isExpanded(.codex))
        f.clock.date.addTimeInterval(300)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.claude.requests == 2 && f.codex.requests == 0)
        f.coordinator.sleep(); f.coordinator.wake()
        try await self.wait { f.coordinator.refreshing.isEmpty && f.claude.requests == 3 }
        #expect(f.codex.requests == 0)
    }
    @Test
    func disclosureAndRepeatedTicksRespectNetworkBackoff() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.codex.result = .failure(.network)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        f.coordinator.toggleProvider(.codex); f.coordinator.toggleProvider(.codex)
        f.coordinator.detailsOpened()
        await f.coordinator.tick()
        #expect(f.codex.requests == 1 && f.claude.requests == 0)
        f.clock.date.addTimeInterval(30)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.codex.requests == 2 && f.claude.requests == 0)
    }
    @Test
    func renderForecastAndTrendWithInactiveClaude() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageForecastRender-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try #require(AIUsageDecoder.date("2026-10-05T08:32:00Z"))
        let daily = (0...30).map { AIUsageDailyPoint(date: now.addingTimeInterval(Double(-30 + $0) * 86400), tokens: $0.isMultiple(of: 4) ? 0 : ($0 * $0 + 20) * 10000) }
        let points = AIUsageHistory.points(daily: daily, now: now)
        let f = try UsageCoordinatorFixture(scanUsage: { AIUsageScanResult(activity: nil, histories: [.codex: points]) }); defer { f.cleanup() }
        f.clock.date = now
        f.codex.result = .success(AIUsageSnapshot(provider: .codex, accountID: "fixture", plan: "pro", windows: [
            .init(period: .session, usedPercent: 10, resetsAt: now.addingTimeInterval(14400), duration: 18000),
            .init(period: .weekly, usedPercent: 38, resetsAt: now.addingTimeInterval(420000), duration: 604800)
        ], fetchedAt: now))
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        #expect(f.claude.requests == 0 && f.coordinator.histories[.codex]?.count == 31)
        let model = TaskCoordinator(directory: directory, defaults: f.defaults)
        model.toggleSection(.usage)
        let output = ProcessInfo.processInfo.environment["MIMIC_USAGE_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSHostingView(rootView: AIUsageSection(model: model, usage: f.coordinator).padding().frame(width: 440).background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: name)
            view.frame = NSRect(x: 0, y: 0, width: 440, height: view.fittingSize.height)
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width <= 440 && view.fittingSize.height < 660)
            #expect(f.coordinator.isExpanded(.codex) && !f.coordinator.isExpanded(.claude))
            if let output {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("forecast-" + name.rawValue + ".png"))
            }
        }
    }
    @Test
    func statusButtonPreservesIconMarkersAndFullAccessibility() async throws {
        let f = try UsageCoordinatorFixture(); defer { f.cleanup() }
        f.codex.result = .success(f.snapshot(reset: f.clock.date.addingTimeInterval(900)))
        f.coordinator.refresh(provider: .codex); try await self.wait { f.coordinator.refreshing.isEmpty }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        for marker in StatusIcon.Marker.allCases {
            AIUsageStatusPresentation.apply(button: button, usage: f.coordinator, marker: marker, health: "fixture-status")
            #expect(button.title == " 75%" && button.imagePosition == .imageLeading)
            #expect(button.image?.isTemplate == true && button.image?.size.width == 20)
            #expect(button.toolTip?.contains("Codex") == true && button.toolTip?.contains("pro") == true)
            #expect((button.accessibilityValue() as? String)?.contains("75%") == true)
        }
        #expect(item.length == NSStatusItem.variableLength)
    }
    @Test
    func usageSectionUsesExistingSingleExpansionAndSettingsPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsagePanel-" + UUID().uuidString)
        let f = try UsageCoordinatorFixture(); defer { f.cleanup(); try? FileManager.default.removeItem(at: directory) }
        let model = TaskCoordinator(directory: directory, defaults: f.defaults)
        model.toggleSection(.usage)
        #expect(model.expandedSection == .usage && model.panelScrollTarget == "section.usage")
        model.toggleSettings()
        #expect(model.panelPage == .settings)
        model.toggleSection(.usage); model.toggleSection(.usage)
        #expect(model.expandedSection == nil)
        #expect(model.aiUsage.refreshing.isEmpty) // Constructing views/models never starts live queries.
    }
    @Test
    func renderUsageDetailsWithMissingDataAndStaleValuesInBothAppearances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageRender-" + UUID().uuidString)
        let f = try UsageCoordinatorFixture(); defer { f.cleanup(); try? FileManager.default.removeItem(at: directory) }
        let model = TaskCoordinator(directory: directory, defaults: f.defaults)
        f.codex.result = .success(f.snapshot()); f.claude.result = .failure(.authentication)
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        model.toggleSection(.usage)
        let output = ProcessInfo.processInfo.environment["MIMIC_USAGE_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for state in ["fresh", "stale"] {
            if state == "stale" {
                f.clock.date.addTimeInterval(301); f.codex.result = .failure(.network)
                await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
                #expect(f.coordinator.percentage == "—" && f.coordinator.snapshots[.codex] != nil)
            }
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let view = NSHostingView(rootView: AIUsageSection(model: model, usage: f.coordinator).padding().frame(width: 440).background(Color(nsColor: .windowBackgroundColor)))
                view.appearance = NSAppearance(named: name)
                view.frame = NSRect(x: 0, y: 0, width: 440, height: view.fittingSize.height)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(2))
                #expect(view.fittingSize.width <= 440)
                #expect(view.fittingSize.height > 100 && view.fittingSize.height < 660)
                if let output {
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(state + "-" + name.rawValue + ".png"))
                }
            }
        }
    }
    // finishLaunching gives this fixture ownership of AppKit's lifecycle; isolate it from other suites.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_TREND_AX_FIXTURE"] == "1"))
    func accessibleTrendButtonOpensWithoutAdditionalUsageRequests() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageTrendAccessibility-" + UUID().uuidString)
        let points = AIUsageHistory.points(daily: [.init(date: Date(timeIntervalSince1970: 1000), tokens: 779300000)], now: Date(timeIntervalSince1970: 1000))
        var scans = 0
        let f = try UsageCoordinatorFixture(scanUsage: { scans += 1; return .init(activity: nil, histories: [.codex: points]) })
        defer { f.cleanup(); try? FileManager.default.removeItem(at: directory) }
        f.codex.result = .success(f.snapshot())
        await f.coordinator.tick(); try await self.wait { f.coordinator.refreshing.isEmpty }
        let model = TaskCoordinator(directory: directory, defaults: f.defaults); model.toggleSection(.usage)
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 440, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: AIUsageSection(model: model, usage: f.coordinator).padding().frame(width: 440))
        window.contentView = view; window.orderFront(nil); view.layoutSubtreeIfNeeded()
        defer { AIUsageTrendPopoverController.dismissAll(); window.orderOut(nil) }
        let label = text("usage.trend.open")
        // AX calls targeting this process dispatch directly to AppKit; actions must stay on
        // the main actor. The client API also avoids depending on SwiftUI's private node types.
        let result = {
            func value(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
                var result: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
                return result
            }
            func find(_ node: AXUIElement, depth: Int = 0) -> AXUIElement? {
                guard depth < 25 else { return nil }
                if value(node, "AXIdentifier") as? String == "usage.trend.open.codex" { return node }
                let children = value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
                let windows = depth == 0 ? value(node, kAXWindowsAttribute) as? [AXUIElement] ?? [] : []
                for child in children + windows {
                    if let match = find(child, depth: depth + 1) { return match }
                }
                return nil
            }
            let app = AXUIElementCreateApplication(getpid())
            guard let button = find(app) else { return (false, nil as String?, nil as String?, Int32(-1)) }
            let title = value(button, kAXTitleAttribute) as? String ?? value(button, kAXDescriptionAttribute) as? String
            let readout = value(button, kAXValueAttribute) as? String
            return (true, title, readout, AXUIElementPerformAction(button, kAXPressAction as CFString).rawValue)
        }()
        #expect(result.0)
        #expect(result.1 == label && result.2?.contains("779") == true)
        #expect(result.3 == AXError.success.rawValue)
        try await self.wait { NSApp.windows.contains { AIUsageTrendPopoverController.owns($0) } }
        let detail = try #require(NSApp.windows.first { AIUsageTrendPopoverController.owns($0) })
        #expect(detail.isVisible && window.isVisible)
        #expect(f.codex.requests == 1 && f.claude.requests == 0 && scans == 1)
        AIUsageTrendPopoverController.dismissAll()
        #expect(!AIUsageTrendPopoverController.owns(detail) && window.isVisible)
    }
}
