// Created by Василий Маслов on 06.10.2026.
import SwiftUI
import MimicCore

/// Polling a CI run updates its card without rebuilding the grid or the hidden settings document.
struct CICompactSummaryView: View {
    @ObservedObject var state: CIState
    let full: Bool
    let open: (CICompactSummary) -> Void
    var body: some View {
        if state.compactSummaries.isEmpty {
            Text(text("ci.compact.empty")).mimicFont(.caption).foregroundStyle(.secondary)
        } else {
            CICompactRuns(summaries: Array(state.compactSummaries.prefix(full ? 2 : 1)), open: open)
        }
    }
}

/// Each run owns its status and evidence; compact layout never infers time or completion.
struct CICompactBody: View {
    let summary: CICompactSummary
    /// Only collapsed cards consume spare height; activity and details stay intrinsic.
    var fillsAvailableHeight = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(self.summary.displayID ?? text("ci.compact.launch")).foregroundStyle(.secondary)
                    .lineLimit(1).help(self.summary.displayID ?? text("ci.compact.launch"))
                Spacer(minLength: 2)
                CIStatusBadge(status: self.summary.status).lineLimit(1)
                    .help(text("ci.status." + self.summary.status))
                if self.summary.stale {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        .help(text("ci.compact.stale")).accessibilityLabel(text("ci.compact.stale"))
                }
            }
            Label(self.summary.branch, systemImage: "arrow.triangle.branch")
                .lineLimit(1).truncationMode(.middle).help(self.summary.branch)
            if self.fillsAvailableHeight { Spacer(minLength: 4) }
            VStack(alignment: .leading, spacing: 4) {
                if self.summary.active { CICompactProgress(summary: self.summary) }
                MimicActivityClock(running: summary.status == "running" && !summary.stale && summary.startedAt != nil) { now in
                    HStack(spacing: 8) {
                        Label(self.summary.startedAt.map { ciDate($0) } ?? "—", systemImage: "clock")
                            .help(text("ci.time.begin") + " · " + (self.summary.startedAt?.formatted(date: .complete, time: .complete) ?? "—"))
                            .accessibilityLabel(text("ci.time.begin"))
                            .accessibilityValue(self.summary.startedAt.map { ciDate($0) } ?? "—")
                        Spacer(minLength: 0)
                        Label(self.elapsed(now), systemImage: "timer")
                            .help(text("ci.time.duration")).accessibilityLabel(text("ci.time.duration"))
                            .accessibilityValue(self.elapsed(now))
                    }.monospacedDigit().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.mimicImmediate()
                if let current = self.current {
                    Text(current).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .help(self.summary.runningJobs.isEmpty ? current : self.summary.runningJobs.joined(separator: "\n"))
                }
            }
        }.frame(maxHeight: self.fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
            .mimicFont(.caption).transaction { $0.animation = nil }
    }
    private func elapsed(_ now: Date) -> String {
        let value = self.summary.status == "running" && !self.summary.stale
            ? self.summary.startedAt.map { now.timeIntervalSince($0) } : self.summary.duration
        return value.map(ciElapsed) ?? "—"
    }
    private var current: String? {
        if self.summary.status == "failed" { return self.summary.firstFailedJob.map { text("ci.checks.failed") + " " + $0 } }
        guard self.summary.active else { return nil }
        if self.summary.runningJobs.count == 1 { return self.summary.runningJobs[0] }
        if self.summary.runningJobs.count > 1 { return String(format: text("ci.checks.parallel"), self.summary.runningJobs.count) }
        if self.summary.waitingForManual { return text("ci.checks.manual") }
        return nil
    }
}

/// Completion belongs inside a run, rather than on the outside edge of its container.
struct CICompactProgress: View {
    private var theme = MimicTheme()
    let summary: CICompactSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MimicProgressBar(value: self.summary.fraction, color: theme.tiled ? theme.color("usageOlive") : FooterCIStatus.pipelineColor(self.summary.status), label: text("ci.checks.progress"))
            Text(self.summary.fraction == nil ? text("ci.compact.progress.unknown") : "\(self.summary.completed ?? 0)/\(self.summary.total ?? 0)")
                .mimicFont(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
        }
    }
}

struct CIProjectName: View {
    let checkout: String
    var body: some View {
        HStack(spacing: 4) {
            Text("·")
            Text(URL(fileURLWithPath: self.checkout).lastPathComponent).lineLimit(1).truncationMode(.middle)
        }.mimicFont(.caption).foregroundStyle(.secondary).help(self.checkout)
    }
}

/// Stable identities keep keyboard focus on its run when active priority changes their order.
struct CICompactRuns: View {
    let summaries: [CICompactSummary]
    let open: (CICompactSummary) -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(self.summaries) { summary in
                Button { self.open(summary) } label: {
                    CICompactBody(summary: summary, fillsAvailableHeight: true).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).contentShape(Rectangle())
                }.buttonStyle(.plain).background(PanelControlRegion())
                    .accessibilityIdentifier("ci.compact.run." + summary.id)
                    .accessibilityLabel((summary.displayID ?? text("ci.compact.launch")) + " · " + summary.branch)
            }
        }.frame(maxHeight: .infinity).overlay {
            if self.summaries.count == 2 { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5).allowsHitTesting(false) }
        }
    }
}

struct CIActivitySection: View {
    let summary: CICompactSummary
    let open: () -> Void
    let hide: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal").foregroundStyle(PanelCardPalette.color(.ci))
                Text(text("panel.block.ci")).mimicFont(.heading)
                CIProjectName(checkout: self.summary.checkout)
                Spacer(minLength: 0)
                BootstrapIconButton(symbol: "xmark", label: text("ci.compact.hide"), action: self.hide, inControlBar: true)
            }
            CICompactBody(summary: self.summary).allowsHitTesting(false)
        }.padding(MimicMetrics.cardInsets).frame(width: MimicMetrics.cardWidth, alignment: .leading)
            .background(CardMouseSurface(open: self.open, label: text("ci.compact.open")))
            .accessibilityIdentifier("ci.quick.activity")
    }
}
