//
//  AICompactTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 06.10.2026.
import AppKit
import ApplicationServices
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

/// In-memory adapter: native hover and action fixtures cannot access real accounts.
@MainActor private final class CompactUsageAdapter: AIUsageFetching {
    let provider: AIProvider
    let snapshot: AIUsageSnapshot
    var requests = 0
    init(_ provider: AIProvider, now: Date) {
        self.provider = provider
        self.snapshot = .init(provider: provider, accountID: "fixture", plan: "pro",
            windows: [.init(period: .session, usedPercent: 10), .init(period: .weekly, usedPercent: 81)], fetchedAt: now)
    }
    func revision() -> String { "fixture" }
    func fetch(manual: Bool) async throws -> AIUsageFetchResult {
        self.requests += 1
        return .init(snapshot: self.snapshot, revision: self.revision())
    }
}

@Suite(.serialized) @MainActor
struct AICompactTests {
    private let now = Date(timeIntervalSince1970: 1_791_318_600)

    private func summary(_ provider: AIProvider = .codex, used: Double = 81, periods: [AIUsagePeriod] = [.session, .weekly],
                         stale: Bool = false, expired: Bool = false) -> AICompactProviderSummary {
        let snapshot = AIUsageSnapshot(provider: provider, accountID: "disposable-account", plan: "prolite",
            windows: periods.map { period in
                .init(period: period, usedPercent: used,
                      resetsAt: self.now.addingTimeInterval(expired ? -1 : period == .session ? 3600 : 3 * 86400),
                      duration: period == .session ? 18000 : 604800)
            }, fetchedAt: self.now.addingTimeInterval(stale ? -300 : 0))
        let points = AIUsageHistory.points(daily: (0...30).map { index in
            .init(date: self.now.addingTimeInterval(Double(index - 30) * 86400), tokens: index == 30 ? 127000 : index * (index.isMultiple(of: 3) ? 700 : 2100))
        }, now: self.now)
        return .init(provider: provider, snapshot: snapshot, error: nil, refreshing: false, now: self.now, points: points)
    }

    // MARK: - Snapshot and pacing contracts

    @Test func absentMeasurementsStayHiddenAndRemainingIsClampedAndFloored() throws {
        let snapshot = AIUsageSnapshot(provider: .codex, accountID: "fixture", plan: "pro",
            windows: [.init(period: .weekly, usedPercent: 80.01), .init(period: .session, usedPercent: nil)], fetchedAt: self.now)
        let value = AICompactProviderSummary(provider: .codex, snapshot: snapshot, error: nil, refreshing: false, now: self.now)
        #expect(value.windows.map(\.id) == [.weekly])
        let weekly = try #require(value.windows.first)
        #expect(weekly.percent == 19 && abs(weekly.fraction - 0.1999) < 0.00001)
        for (used, expected) in [(0.0, 100), (81.0, 19), (100.0, 0), (-12.0, 100), (120.0, 0)] {
            let window = try #require(AICompactWindowSummary(window: .init(period: .session, usedPercent: used), snapshotStale: false, now: self.now))
            #expect(window.percent == expected && window.fraction == Double(expected) / 100)
        }
        #expect(AICompactWindowSummary(window: .init(period: .session, usedPercent: .nan), snapshotStale: false, now: self.now) == nil)
        #expect(self.summary(periods: [.weekly, .session]).windows.map(\.id) == [.session, .weekly])
        #expect(self.summary(periods: [.session]).windows.map(\.id) == [.session])
        #expect(self.summary(periods: [.weekly]).windows.map(\.id) == [.weekly])
    }

    @Test func staleAndExpiredWindowsRetainValuesWithoutForecastOrMarker() throws {
        for value in [self.summary(stale: true), self.summary(expired: true)] {
            #expect(value.stale && value.windows.count == 2)
            for window in value.windows {
                #expect(window.percent == 19 && window.pace == .stale)
                #expect(window.pace.tick == nil && window.warningSymbol == nil)
                #expect(window.forecast == text("usage.stale"))
            }
            #expect(value.accessibilityDescription.contains("19%"))
        }
        let risk = try #require(self.summary().windows.first)
        #expect(risk.warningSymbol == "flame.fill" && risk.pace.tick != nil)
        #expect(risk.tooltip.contains(text("usage.compact.paceMarker")))
        #expect(risk.tooltip.contains(text("usage.pace.limitAt")))
        let healthy = try #require(self.summary(used: 10).windows.first)
        #expect(healthy.warningSymbol == nil && healthy.pace.tick == nil)
        let spent = try #require(self.summary(used: 100).windows.first)
        #expect(spent.percent == 0 && spent.forecast == text("usage.pace.spent"))
    }

    @Test func providerOrderFallbackAndEmptyReasonsRemainExplicit() {
        #expect(AICompactProviderSummary.providers(active: .codex, full: false) == [.codex])
        #expect(AICompactProviderSummary.providers(active: .claude, full: false) == [.claude])
        #expect(AICompactProviderSummary.providers(active: .codex, full: true) == [.codex, .claude])
        #expect(AICompactProviderSummary.providers(active: .claude, full: true) == [.claude, .codex])
        let empty = AICompactProviderSummary(provider: .claude, snapshot: nil, error: nil, refreshing: false, now: self.now)
        #expect(empty.windows.isEmpty && empty.emptyStatus == text("usage.unavailable"))
        let loading = AICompactProviderSummary(provider: .claude, snapshot: nil, error: .network, refreshing: true, now: self.now)
        #expect(loading.emptyStatus == text("usage.refreshing"))
        for error in [AIUsageError.authentication, .keychainAccess, .missingCLI, .unsupported, .invalidResponse, .network, .timeout, .cancelled, .accountChanged, .rateLimited(retryAt: nil)] {
            let value = AICompactProviderSummary(provider: .claude, snapshot: nil, error: error, refreshing: false, now: self.now)
            #expect(!value.emptyStatus.hasPrefix("usage.") && value.hasError && value.windows.isEmpty)
            #expect(value.metadata.contains(text(error.localizationKey)))
        }
    }

    @Test func resetLabelsRespectCalendarDayAndPreserveExactTooltip() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Almaty"))
        let date = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 6, hour: 21, minute: 0)))
        let today = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 6, hour: 23, minute: 40)))
        let later = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 10, hour: 9, minute: 18)))
        let first = try #require(AICompactWindowSummary(window: .init(period: .session, usedPercent: 10, resetsAt: today), snapshotStale: false, now: date))
        let second = try #require(AICompactWindowSummary(window: .init(period: .weekly, usedPercent: 10, resetsAt: later), snapshotStale: false, now: date))
        #expect(first.resetText(now: date, calendar: calendar, locale: Locale(identifier: "ru_RU")) == "Сегодня 23:40")
        #expect(second.resetText(now: date, calendar: calendar, locale: Locale(identifier: "ru_RU")).contains("10 окт"))
        #expect(second.tooltip.contains(later.formatted(date: .complete, time: .shortened)))
    }

    @Test func weeklyOnlyTrendUsesTodaysLocalTokensWithoutInventingMissingData() {
        let weekly = self.summary(periods: [.weekly])
        #expect(weekly.showsTrend && weekly.points.count == 31 && weekly.todayTokens(now: self.now) == 127000)
        #expect(!self.summary().showsTrend && !self.summary(periods: [.session]).showsTrend)
        #expect(weekly.todayTokens(now: self.now.addingTimeInterval(86400)) == nil)
        let missing = AICompactProviderSummary(provider: .codex, snapshot: nil, error: nil, refreshing: false, now: self.now)
        #expect(!missing.showsTrend && missing.todayTokens(now: self.now) == nil)
        let snapshot = AIUsageSnapshot(provider: .codex, accountID: "fixture", plan: "pro",
            windows: [.init(period: .weekly, usedPercent: 81)], fetchedAt: self.now)
        let idle = AICompactProviderSummary(provider: .codex, snapshot: snapshot, error: nil, refreshing: false, now: self.now,
            points: [.init(date: self.now, tokens: 0)])
        #expect(idle.todayTokens(now: self.now) == 0)
        let large = AICompactProviderSummary(provider: .codex, snapshot: snapshot, error: nil, refreshing: false, now: self.now,
            points: [.init(date: self.now, tokens: Int.max)], unknownModels: ["unknown-fixture-model"])
        #expect(large.todayTokens(now: self.now) == Int.max)
    }

    // MARK: - Native rendering and actions

    /// Run separately: finishLaunching gives this fixture ownership of AppKit's lifecycle.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_AI_COMPACT_AX_FIXTURE"] == "1"))
    func nativeAccessibleActionsOpenAIAndTrendIndependently() async throws {
        _ = NSApplication.shared; NSApp.finishLaunching()
        let suite = "AICompactAX-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let codex = CompactUsageAdapter(.codex, now: self.now), claude = CompactUsageAdapter(.claude, now: self.now)
        let now = self.now
        let usage = AIUsageCoordinator(defaults: defaults, adapters: [codex, claude], clock: { now })
        let layout = PanelLayoutController(defaults: defaults)
        defer { usage.stop(); defaults.removePersistentDomain(forName: suite) }
        usage.refreshAll()
        for _ in 0..<1000 where !usage.refreshing.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(usage.refreshing.isEmpty && codex.requests == 1 && claude.requests == 1)
        let view = NSHostingView(rootView: AICompactProviders(usage: usage, full: true, open: { layout.open(.ai) }).frame(width: 464, height: 112))
        let window = NSWindow(contentRect: NSRect(x: 250, y: 300, width: 464, height: 112), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50)); view.layoutSubtreeIfNeeded()
        func value(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
            return result
        }
        func find(_ node: AXUIElement, _ identifier: String, depth: Int = 0) -> AXUIElement? {
            guard depth < 25 else { return nil }
            if value(node, "AXIdentifier") as? String == identifier { return node }
            let children = value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let windows = depth == 0 ? value(node, kAXWindowsAttribute) as? [AXUIElement] ?? [] : []
            for child in children + windows {
                if let match = find(child, identifier, depth: depth + 1) { return match }
            }
            return nil
        }
        let app = AXUIElementCreateApplication(getpid())
        let first = try #require(find(app, "usage.compact.provider.codex"))
        let readout = try #require(value(first, kAXValueAttribute) as? String)
        #expect(readout.contains("90%") && readout.contains("19%") && readout.contains("pro"))
        #expect(AXUIElementPerformAction(first, kAXPressAction as CFString) == .success)
        #expect(layout.expanded == .ai && usage.isExpanded(.codex) && !usage.isExpanded(.claude))
        layout.open(.ai)
        layout.expanded = nil
        let trendView = NSHostingView(rootView: self.card([self.summary(periods: [.weekly])], width: 238, open: { layout.open(.ai) }))
        let trendWindow = NSWindow(contentRect: NSRect(x: 750, y: 300, width: 238, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        trendWindow.isReleasedWhenClosed = false; trendWindow.contentView = trendView; trendWindow.makeKeyAndOrderFront(nil)
        defer { AIUsageTrendPopoverController.dismissAll(); trendWindow.close() }
        trendView.layoutSubtreeIfNeeded()
        let trend = try #require(find(app, "usage.compact.trend.codex"))
        #expect((value(trend, kAXValueAttribute) as? String)?.contains("127") == true)
        #expect(AXUIElementPerformAction(trend, kAXPressAction as CFString) == .success)
        #expect(layout.expanded == nil)
        #expect(NSApp.windows.contains { AIUsageTrendPopoverController.owns($0) })
        #expect(codex.requests == 1 && claude.requests == 1)
    }

    private func card(_ summaries: [AICompactProviderSummary], width: CGFloat, open: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(PanelCardPalette.color(.ai))
                Text(text("panel.block.ai")).font(MimicMetrics.heading)
                Spacer(minLength: 0)
            }.frame(minHeight: 20)
            AICompactColumns(summaries: summaries, now: self.now, open: open)
        }.padding(MimicMetrics.cardInsets).frame(width: width, height: MimicMetrics.collapsedCardHeight)
            .modifier(PanelCardBackground(block: .ai))
    }

    /// Real card dimensions and realistic missing/error data exercise the production columns.
    @Test func rendersBothSizesInThemesContrastAndReducedMotion() async throws {
        let empty = AICompactProviderSummary(provider: .claude, snapshot: nil, error: .unsupported, refreshing: false, now: self.now)
        let missing = AICompactProviderSummary(provider: .codex, snapshot: nil, error: nil, refreshing: false, now: self.now)
        let cases: [(String, [AICompactProviderSummary])] = [
            ("both", [self.summary(), self.summary(.claude, used: 10)]),
            ("weekly", [self.summary(periods: [.weekly]), self.summary(.claude)]),
            ("session", [self.summary(periods: [.session]), self.summary(.claude, periods: [.weekly])]),
            ("empty", [missing, empty]), ("one-missing", [self.summary(), empty]),
            ("stale", [self.summary(stale: true), self.summary(.claude, expired: true)]),
            ("bounds", [self.summary(used: 0), self.summary(.claude, used: 100)])
        ]
        let output = ProcessInfo.processInfo.environment["MIMIC_AI_COMPACT_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for (state, values) in cases {
            let style = PanelAppearance(rawValue: ProcessInfo.processInfo.environment["MIMIC_PANEL_APPEARANCE"] ?? "legacy") ?? .legacy
            let mini: CGFloat = style == .tileGrid ? 258 : 238
            for width in [mini, style == .tileGrid ? 528 : 488] {
                for dark in [false, true] {
                    for contrast in [false, true] {
                        let appearance: NSAppearance.Name = contrast ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua)
                        let root = self.card(width == mini ? Array(values.prefix(1)) : values, width: width)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.mimicPanelAppearance, style)
                            .environment(MimicAppearancePreview(reduceMotion: true, increasedContrast: contrast))
                        let view = NSHostingView(rootView: root)
                        let window = NSWindow(contentRect: NSRect(x: 250, y: 300, width: width, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = view
                        defer { window.close() }
                        window.orderFront(nil)
                        try await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded()
                        #expect(view.fittingSize == CGSize(width: width, height: 160))
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let output {
                            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("ai-\(state)-\(Int(width))-\(dark)-\(contrast).png"))
                        }
                    }
                }
            }
        }
    }
}
