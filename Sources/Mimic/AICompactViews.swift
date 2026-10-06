//
//  AICompactViews.swift
//  Mimic
//
//  Created by Василий Маслов on 06.10.2026.
import SwiftUI
import MimicCore

// MARK: - Read-only compact presentation

/// A measured window stays visible after expiry, but cannot retain a live pacing verdict.
@MainActor
struct AICompactWindowSummary: Identifiable {
    let window: AIUsageWindow
    let remaining: Double
    let pace: AIUsagePace.State
    nonisolated var id: AIUsagePeriod { self.window.period }
    var percent: Int { Int(self.remaining.rounded(.down)) }
    var fraction: Double { self.remaining / 100 }
    var stale: Bool { self.pace == .stale }

    init?(window: AIUsageWindow, snapshotStale: Bool, now: Date) {
        guard let remaining = window.remainingPercent else { return nil }
        self.window = window; self.remaining = remaining
        self.pace = AIUsagePace.evaluate(window: window, stale: snapshotStale, now: now)
    }
    var title: String {
        text("usage.period." + self.id.rawValue) + " · \(self.percent)% " + text("usage.remaining")
    }
    var color: Color {
        switch self.pace.severity {
        case .normal: .blue
        case .warning: .yellow
        case .critical: .red
        case nil: .gray
        }
    }
    var warningSymbol: String? {
        switch self.pace {
        case .spent, .runningOut: "flame.fill"
        case .closeToLimit, .level(.warning), .level(.critical): "exclamationmark.triangle.fill"
        default: nil
        }
    }
    var forecast: String {
        switch self.pace {
        case .stale: text("usage.stale")
        case .spent: text("usage.pace.spent")
        case let .healthy(projected): String(format: text("usage.pace.leftAtReset"), Int((100 - projected).rounded()))
        case let .closeToLimit(_, projected, _): String(format: text("usage.pace.usedAtReset"), Int(projected.rounded()))
        case let .runningOut(at, projected, _):
            [at.map { text("usage.pace.limitAt") + " " + $0.formatted(date: .abbreviated, time: .shortened) },
             String(format: text(projected > 100 ? "usage.pace.overAtReset" : "usage.pace.usedAtReset"), Int((projected > 100 ? projected - 100 : projected).rounded()))]
                .compactMap { $0 }.joined(separator: " · ")
        default: text("usage.pace.unavailable")
        }
    }
    var tooltip: String {
        var parts = [self.title, self.forecast,
                     self.window.resetsAt.map { text("usage.reset") + " " + $0.formatted(date: .complete, time: .shortened) } ?? text("usage.reset.unknown")]
        if self.pace.tick != nil { parts.append(text("usage.compact.paceMarker")) }
        return parts.joined(separator: "\n")
    }
    /// Calendar-relative labels use the same timezone for the day boundary and clock.
    func resetText(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let reset = self.window.resetsAt else { return text("usage.reset.unknown") }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        if calendar.isDate(reset, inSameDayAs: now) {
            formatter.dateStyle = .none; formatter.timeStyle = .short
            return text("usage.compact.today") + " " + formatter.string(from: reset)
        }
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: reset)
    }
}

/// Compact UI projects existing snapshots; constructing or hovering it never fetches data.
@MainActor
struct AICompactProviderSummary: Identifiable {
    let provider: AIProvider
    let windows: [AICompactWindowSummary]
    let emptyStatus: String
    let metadata: String
    let hasError: Bool
    let points: [AIUsageDailyPoint]
    let unknownModels: [String]
    nonisolated var id: AIProvider { self.provider }
    var name: String { self.provider == .codex ? "Codex" : "Claude Code" }
    var stale: Bool { self.windows.contains(where: \.stale) }
    var showsTrend: Bool { self.windows.map(\.id) == [.weekly] }
    func todayTokens(now: Date, calendar: Calendar = .current) -> Int? {
        self.points.first { calendar.isDate($0.date, inSameDayAs: now) }?.tokens
    }
    var accessibilityDescription: String {
        ([self.metadata] + (self.windows.isEmpty ? [self.emptyStatus] : self.windows.map(\.tooltip))).joined(separator: "\n")
    }

    init(provider: AIProvider, snapshot: AIUsageSnapshot?, error: AIUsageError?, refreshing: Bool, now: Date,
         points: [AIUsageDailyPoint] = [], unknownModels: [String] = []) {
        self.provider = provider; self.hasError = error != nil
        self.points = points; self.unknownModels = unknownModels
        self.windows = AIUsagePeriod.allCases.compactMap { period in
            guard let window = snapshot?.window(period) else { return nil }
            return AICompactWindowSummary(window: window, snapshotStale: snapshot?.isStale(at: now) ?? false, now: now)
        }
        self.emptyStatus = refreshing ? text("usage.refreshing") : error.map { text(Self.compactErrorKey($0)) } ?? text("usage.unavailable")
        self.metadata = [snapshot?.plan ?? text("usage.plan.unknown"),
                         snapshot.map { text("usage.updated") + " " + $0.fetchedAt.formatted(date: .abbreviated, time: .shortened) },
                         error.map { text($0.localizationKey) }].compactMap { $0 }.joined(separator: "\n")
    }
    static func providers(active: AIProvider, full: Bool) -> [AIProvider] {
        [active] + (full ? AIProvider.allCases.filter { $0 != active } : [])
    }
    private static func compactErrorKey(_ error: AIUsageError) -> String {
        if case .rateLimited = error { return "usage.compact.error.rateLimited" }
        return "usage.compact.error." + String(describing: error)
    }
}

// MARK: - Provider columns and meters

struct AICompactProviders: View {
    @ObservedObject var usage: AIUsageCoordinator
    let full: Bool
    let open: () -> Void
    var body: some View {
        AICompactColumns(summaries: AICompactProviderSummary.providers(active: self.usage.activeProvider, full: self.full).map { provider in
            AICompactProviderSummary(provider: provider, snapshot: self.usage.snapshots[provider], error: self.usage.errors[provider],
                                     refreshing: self.usage.refreshing.contains(provider), now: self.usage.currentDate,
                                     points: self.usage.histories[provider] ?? [], unknownModels: self.usage.unknownModels[provider] ?? [])
        }, now: self.usage.currentDate, open: self.open)
    }
}

/// Provider identity, rather than its current column, owns the keyboard focus across reorderings.
struct AICompactColumns: View {
    let summaries: [AICompactProviderSummary]
    let now: Date
    let open: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(self.summaries) { summary in
                Button(action: self.open) {
                    AICompactBody(summary: summary, now: self.now)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).contentShape(Rectangle())
                }.buttonStyle(.plain).background(PanelControlRegion())
                    .accessibilityIdentifier("usage.compact.provider." + summary.provider.rawValue)
                    .accessibilityLabel(summary.name).accessibilityValue(summary.accessibilityDescription)
                    .overlayPreferenceValue(AICompactTrendAnchor.self) { anchor in
                        if let anchor, summary.showsTrend {
                            GeometryReader { geometry in
                                let frame = geometry[anchor]
                                AICompactTrendView(summary: summary, now: self.now)
                                    .frame(width: frame.width, height: frame.height)
                                    .position(x: frame.midX, y: frame.midY)
                            }
                        }
                    }
            }
        }.frame(maxHeight: .infinity).overlay {
            if self.summaries.count == 2 { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5).allowsHitTesting(false) }
        }.transaction { $0.animation = nil }
    }
}

private struct AICompactBody: View {
    let summary: AICompactProviderSummary
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(self.summary.name).lineLimit(1).foregroundStyle(.secondary).help(self.summary.metadata)
                Spacer(minLength: 0)
                if self.summary.stale || self.summary.hasError {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        .help(self.summary.stale ? text("usage.stale") + "\n" + self.summary.metadata : self.summary.metadata)
                        .accessibilityLabel(self.summary.stale ? text("usage.stale") : self.summary.emptyStatus)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 8) {
                if self.summary.showsTrend {
                    Color.clear.frame(height: 34).accessibilityHidden(true)
                        .anchorPreference(key: AICompactTrendAnchor.self, value: .bounds) { $0 }
                }
                if self.summary.windows.isEmpty {
                    Text(self.summary.emptyStatus).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).help(self.summary.metadata)
                } else {
                    ForEach(self.summary.windows) { window in AICompactWindowView(summary: window, now: self.now) }
                }
            }
        }.frame(maxHeight: .infinity, alignment: .topLeading).font(MimicMetrics.secondary)
    }
}

/// The sparkline is a sibling control over its reserved slot, never a button inside a button.
private struct AICompactTrendAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

private struct AICompactTrendView: View {
    let summary: AICompactProviderSummary
    let now: Date
    @StateObject private var hover: AIUsageTrendPopoverState
    init(summary: AICompactProviderSummary, now: Date) {
        self.summary = summary; self.now = now
        self._hover = StateObject(wrappedValue: AIUsageTrendPopoverState(points: summary.points))
    }
    private var todayReadout: String {
        let count = self.summary.todayTokens(now: self.now).map { $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) } ?? "—"
        return String(format: text("usage.compact.todayTokens"), count)
    }
    private var description: String {
        let exact = self.summary.todayTokens(now: self.now).map { $0.formatted() } ?? text("usage.unavailable")
        var parts = [String(format: text("usage.compact.todayTokens"), exact), AIUsageTrendFormat.description(self.summary.points, provider: self.summary.provider)]
        if !self.summary.unknownModels.isEmpty { parts.append(text("usage.trend.unknownModels") + " " + self.summary.unknownModels.joined(separator: ", ")) }
        return parts.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.todayReadout).font(MimicMetrics.secondary).monospacedDigit().foregroundStyle(.secondary)
            if self.summary.points.isEmpty {
                Text(text("usage.trend.empty")).font(MimicMetrics.secondary).foregroundStyle(.secondary)
                    .frame(height: 18)
            } else {
                Button { self.hover.toggleExplicit() } label: {
                    let peak = self.summary.points.map(\.tokens).max() ?? 0
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(self.summary.points, id: \.date) { point in
                            RoundedRectangle(cornerRadius: 1).fill(Color.blue).frame(maxWidth: .infinity)
                                .frame(height: AIUsageTrendFormat.barHeight(point.tokens, peak: peak, height: 18, floor: 0.18))
                        }
                    }.frame(height: 18, alignment: .bottom).contentShape(Rectangle())
                }.buttonStyle(.plain).background(PanelControlRegion())
                    .background(AIUsageTrendPopoverAnchor(provider: self.summary.provider, state: self.hover))
                    .onContinuousHover { phase in
                        if case .active = phase { self.hover.inlineHover(true) } else { self.hover.inlineHover(false) }
                    }
                    .accessibilityIdentifier("usage.compact.trend." + self.summary.provider.rawValue)
                    .accessibilityLabel(text("usage.trend.open")).accessibilityValue(self.description)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).help(self.description)
            .onChange(of: self.summary.points) { _, points in self.hover.replacePoints(points) }
            .transaction { $0.animation = nil }
    }
}

private struct AICompactWindowView: View {
    let summary: AICompactWindowSummary
    let now: Date
    private var accessibility = MimicAccessibility()
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(self.summary.title).monospacedDigit().fixedSize()
                Spacer(minLength: 0)
                if let symbol = self.summary.warningSymbol {
                    Image(systemName: symbol).foregroundStyle(self.summary.color)
                        .accessibilityLabel(self.summary.forecast)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(self.summary.color).frame(width: geometry.size.width * self.summary.fraction)
                    Capsule().stroke(Color.primary.opacity(self.accessibility.increasedContrast ? 0.6 : 0.15), lineWidth: 0.5)
                    if let tick = self.summary.pace.tick {
                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary).frame(width: 2, height: 6)
                            .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * tick - 1)))
                    }
                }
            }.frame(height: 6).accessibilityHidden(true)
            Text(self.summary.window.resetsAt == nil ? text("usage.reset.unknown") : text("usage.reset") + " " + self.summary.resetText(now: self.now))
                .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }.help(self.summary.tooltip)
            .accessibilityElement(children: .ignore).accessibilityLabel(self.summary.title).accessibilityValue(self.summary.tooltip)
    }
}
