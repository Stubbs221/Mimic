//
//  AIUsageViews.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// The existing status button remains the only click target and panel anchor.
@MainActor
enum AIUsageStatusPresentation {
    static func apply(button: NSStatusBarButton, usage: AIUsageCoordinator, marker: StatusIcon.Marker, health: String) {
        button.image = StatusIcon.image(marker: marker)
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        button.title = " " + usage.percentage
        button.toolTip = text("app.name") + " · " + health + "\n" + usage.statusDescription
        button.setAccessibilityLabel(text("app.name"))
        button.setAccessibilityValue(health + " · " + usage.statusDescription)
    }
}

struct AIUsageSection: View {
    @ObservedObject var model: TaskCoordinator
    let usage: AIUsageCoordinator
    var showsHeader = true
    private var expanded: Bool { !self.showsHeader || self.model.expandedSection == .usage }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if self.showsHeader {
            Button { self.model.toggleSection(.usage) } label: {
                HStack(spacing: MimicMetrics.medium) {
                    Image(systemName: "chart.bar").frame(width: 24)
                    Text(text("usage.title")).mimicFont(.heading).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    Text(self.usage.activeProvider == .codex ? "Codex" : "Claude Code").foregroundStyle(.secondary)
                    Text(self.usage.percentage).monospacedDigit()
                    Image(systemName: self.expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                }.contentShape(Rectangle())
            }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets(top: MimicMetrics.medium, leading: MimicMetrics.medium, bottom: MimicMetrics.medium, trailing: MimicMetrics.medium))).help(self.usage.statusDescription)
                .accessibilityIdentifier("usage.toggle").accessibilityValue(disclosureValue(self.expanded) + " · " + self.usage.statusDescription)
            }
            MimicCollapse(expanded: self.expanded, source: self.model.navigationSource) {
                VStack(alignment: .leading, spacing: MimicMetrics.large) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        AIUsageProviderView(provider: provider, usage: self.usage)
                    }
                    HStack {
                        Button(text("refresh")) { self.usage.refreshVisible() }.buttonStyle(RowButtonStyle())
                            .disabled(!self.usage.refreshing.isEmpty).accessibilityIdentifier("usage.refresh")
                        if !self.usage.refreshing.isEmpty { ProgressView().controlSize(.small).accessibilityLabel(text("usage.refreshing")) }
                    }
                }.padding(.top, MimicMetrics.medium).onAppear { self.usage.detailsOpened() }
            }
        }.id(PanelSection.usage.scrollID)
            .onChange(of: self.expanded) { _, expanded in if !expanded { AIUsageTrendPopoverController.dismissAll() } }
            .onChange(of: self.usage.activeProvider) { _, _ in AIUsageTrendPopoverController.dismissAll() }
    }
}

private struct AIUsageProviderView: View {
    private var theme = MimicTheme()
    let provider: AIProvider
    let usage: AIUsageCoordinator
    private var snapshot: AIUsageSnapshot? { self.usage.snapshots[self.provider] }
    private var expanded: Bool { self.usage.isExpanded(self.provider) }
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: MimicMetrics.medium) {
                Button { self.usage.toggleProvider(self.provider) } label: {
                    HStack(spacing: MimicMetrics.medium) {
                        Text(self.provider == .codex ? "Codex" : "Claude Code").fontWeight(.semibold)
                        if self.usage.activeProvider == self.provider {
                            Text(text("usage.lastUsed")).mimicFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(self.usage.percentage(for: self.provider)).monospacedDigit()
                        Image(systemName: self.expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    }.contentShape(Rectangle())
                }.buttonStyle(RowButtonStyle())
                    .accessibilityIdentifier("usage.provider.toggle." + self.provider.rawValue)
                    .accessibilityValue(disclosureValue(self.expanded))
                if self.expanded {
                    Text(self.snapshot?.plan ?? text("usage.plan.unknown")).mimicFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ForEach(AIUsagePeriod.allCases, id: \.self) { period in self.window(period) }
                    AIUsageTrendView(provider: self.provider, points: self.usage.histories[self.provider] ?? [], unknownModels: self.usage.unknownModels[self.provider] ?? []).equatable()
                        .accessibilityIdentifier("usage.trend." + self.provider.rawValue)
                    if let error = self.usage.errors[self.provider] {
                        Text(text(error.localizationKey)).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if case .rateLimited = error, let retry = self.usage.nextRefresh[self.provider] {
                            Text(text("usage.retry") + " " + retry.formatted(date: .omitted, time: .shortened)).mimicFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let fetched = self.snapshot?.fetchedAt {
                        Text(text("usage.updated") + " " + fetched.formatted(date: .omitted, time: .shortened)).mimicFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("usage.provider." + self.provider.rawValue)
            .onChange(of: self.expanded) { _, expanded in if !expanded { AIUsageTrendPopoverController.dismiss(for: self.provider) } }
    }

    private func window(_ period: AIUsagePeriod) -> some View {
        let window = self.snapshot?.window(period)
        let remaining = window?.remainingPercent
        let state = AIUsagePace.evaluate(window: window, stale: self.snapshot?.isStale(at: self.usage.currentDate) ?? false, now: self.usage.currentDate)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text("usage.period." + period.rawValue)).fontWeight(.semibold)
                Spacer(minLength: 4)
                self.warning(state)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(theme.tiled ? theme.usageColor(state, provider: provider) : self.color(state)).frame(width: geometry.size.width * (remaining ?? 0) / 100)
                    if let tick = state.tick {
                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary)
                            .frame(width: 2, height: 10).offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * tick - 1)))
                    }
                }
            }.frame(height: 6).help(self.tooltip(state))
                .accessibilityLabel(text("usage.period." + period.rawValue))
                .accessibilityValue(self.remainingText(remaining) + " · " + self.tooltip(state))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.remainingText(remaining)).monospacedDigit()
                Spacer(minLength: 4)
                if let reset = window?.resetsAt {
                    Text(text("usage.reset") + " " + reset.formatted(date: .abbreviated, time: .shortened))
                        .mimicFont(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                } else if remaining != nil {
                    Text(text("usage.reset.unknown")).mimicFont(.caption).foregroundStyle(.secondary)
                }
            }
            if state == .stale { Text(text("usage.stale")).mimicFont(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
    private func remainingText(_ remaining: Double?) -> String {
        remaining.map { "\(Int($0.rounded()))% " + text("usage.remaining") } ?? text("usage.unavailable")
    }
    private func color(_ state: AIUsagePace.State) -> Color {
        switch state.severity {
        case .normal: .blue
        case .warning: .yellow
        case .critical: .red
        case nil: .gray
        }
    }
    @ViewBuilder private func warning(_ state: AIUsagePace.State) -> some View {
        switch state {
        case let .closeToLimit(spare, _, _):
            Text(String(format: text("usage.pace.spare"), spare)).mimicFont(.caption).foregroundStyle(.secondary).help(self.tooltip(state))
        case .spent:
            self.flame(text("usage.pace.spent"), state: state)
        case let .runningOut(at, _, _):
            self.flame(at.map { text("usage.pace.limitAt") + " " + $0.formatted(date: .abbreviated, time: .shortened) }, state: state)
        default: EmptyView()
        }
    }
    private func flame(_ label: String?, state: AIUsagePace.State) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "flame.fill").foregroundStyle(.red).accessibilityLabel(text("usage.pace.limit"))
            if let label { Text(label).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        }.mimicFont(.caption).help(self.tooltip(state))
    }
    private func tooltip(_ state: AIUsagePace.State) -> String {
        switch state {
        case .spent: text("usage.pace.spent")
        case let .healthy(projected): String(format: text("usage.pace.leftAtReset"), Int((100 - projected).rounded()))
        case let .closeToLimit(_, projected, _): String(format: text("usage.pace.usedAtReset"), Int(projected.rounded()))
        case let .runningOut(_, projected, _):
            String(format: text(projected > 100 ? "usage.pace.overAtReset" : "usage.pace.usedAtReset"), Int((projected > 100 ? projected - 100 : projected).rounded()))
        case .stale: text("usage.stale")
        default: text("usage.pace.unavailable")
        }
    }
}
