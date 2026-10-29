// Created by Василий Маслов on 06.10.2026.
import SwiftUI
import MimicCore

/// Polling a CI run updates its card without rebuilding the grid or the hidden settings document.
struct CICompactSummaryView: View {
    let state: CIState
    var model: TaskCoordinator? = nil
    @ObservedObject var settings: CISettingsModel
    let full: Bool
    let openSettings: () -> Void
    let open: (CICompactSummary) -> Void
    var body: some View {
        let summaries = state.compactPresentation.summaries
        if self.state.context?.connection == nil && self.settings.connection == nil {
            CIConnectionSetupView(full: self.full, openSettings: self.openSettings)
        } else if summaries.isEmpty {
            if self.state.loading, self.state.loadedAt == nil {
                CISkeleton(presented: self.state.visible || self.state.monitoring)
            } else {
                Text(text("ci.compact.empty")).mimicFont(.caption).foregroundStyle(.secondary)
            }
        } else {
            CICompactRuns(summaries: Array(summaries.prefix(full ? 2 : 1)), open: open, model: self.model)
        }
    }
}

/// Each run owns its status and evidence; compact layout never infers time or completion.
struct CICompactBody: View {
    let summary: CICompactSummary
    /// Only collapsed cards consume spare height; activity and details stay intrinsic.
    var fillsAvailableHeight = false
    var condensed = false
    var showsContext = true
    @Environment(\.mimicTextScale) private var textScale
    var body: some View {
        VStack(alignment: .leading, spacing: self.condensed ? 2 : 4) {
            HStack(spacing: 4) {
                Text(self.summary.displayID ?? text("ci.compact.launch")).mimicFont(.body, weight: .semibold)
                    .lineLimit(1).mimicHelp(self.summary.displayID ?? text("ci.compact.launch"))
                Spacer(minLength: 2)
                CIStatusBadge(status: self.summary.status).lineLimit(1)
                    .mimicHelp(text("ci.status." + self.summary.status))
                if self.summary.stale {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        .mimicHelp(text("ci.compact.stale")).accessibilityLabel(text("ci.compact.stale"))
                }
            }.frame(height: self.fillsAvailableHeight ? 19 * self.textScale : nil)
            Text(self.summary.branch).font(.system(size: 11 * self.textScale, design: .monospaced))
                .lineLimit(1).truncationMode(.middle).mimicHelp(self.summary.branch)
                .frame(height: self.fillsAvailableHeight ? 17 * self.textScale : nil)
            if self.condensed {
                HStack(spacing: 8) {
                    Text(self.current ?? " ").lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .mimicHelp(self.summary.runningJobs.isEmpty ? (self.current ?? "") : self.summary.runningJobs.joined(separator: "\n"))
                    if self.summary.active {
                        Text(self.summary.fraction == nil ? "—" : "\(self.summary.completed ?? 0)/\(self.summary.total ?? 0)")
                            .monospacedDigit().fixedSize().foregroundStyle(.secondary)
                            .mimicHelp(text(self.summary.fraction == nil ? "ci.compact.progress.unknown" : "ci.checks.progress"))
                    }
                }.frame(height: self.fillsAvailableHeight ? 16 * self.textScale : nil)
                if self.summary.active { CICompactProgress(summary: self.summary, showsCount: false) }
            } else {
                if self.summary.active { CICompactProgress(summary: self.summary, inline: true) }
                CICompactTiming(summary: self.summary)
                if self.showsContext, let current = self.current {
                    Text(current).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .mimicHelp(self.summary.runningJobs.isEmpty ? current : self.summary.runningJobs.joined(separator: "\n"))
                }
            }
        }
            .mimicFont(.caption).transaction { $0.animation = nil }
    }
    var current: String? {
        if self.summary.status == "failed" { return self.summary.firstFailedJob.map { text("ci.checks.failed") + " " + $0 } }
        guard self.summary.active else { return self.summary.finishedAt.map { text("ci.time.finished") + " " + ciDate($0) } }
        if self.summary.runningJobs.count == 1 { return self.summary.runningJobs[0] }
        if self.summary.runningJobs.count > 1 { return String(format: text("ci.checks.parallel"), self.summary.runningJobs.count) }
        if self.summary.waitingForManual { return text("ci.checks.manual") }
        return nil
    }
}

/// Compact cards reserve the trailing space for actions; full timestamps remain in help and AX values.
struct CICompactTiming: View {
    let summary: CICompactSummary
    var compact = false
    @Environment(\.mimicTextScale) private var textScale
    var body: some View {
        MimicActivityClock(running: self.summary.status == "running" && !self.summary.stale && self.summary.startedAt != nil) { now in
            HStack(spacing: self.compact && self.textScale > 1 ? 2 : 8) {
                Text(self.summary.startedAt.map { ciDate($0) } ?? "—").lineLimit(1)
                    .mimicHelp(text("ci.time.begin") + " · " + (self.summary.startedAt?.formatted(date: .complete, time: .complete) ?? "—"))
                    .accessibilityLabel(text("ci.time.begin"))
                    .accessibilityValue(self.summary.startedAt.map { ciDate($0) } ?? "—")
                if !self.compact { Spacer(minLength: 0) }
                Group {
                    if self.compact, self.textScale > 1 { Text(self.elapsed(now)) }
                    else { Label(self.elapsed(now), systemImage: "timer") }
                }.lineLimit(1).fixedSize()
                    .mimicHelp(text("ci.time.duration")).accessibilityLabel(text("ci.time.duration"))
                    .accessibilityValue(self.elapsed(now))
            }.monospacedDigit().foregroundStyle(.secondary).mimicFont(.caption)
        }.mimicImmediate()
    }
    private func elapsed(_ now: Date) -> String {
        let value = self.summary.status == "running" && !self.summary.stale
            ? self.summary.startedAt.map { now.timeIntervalSince($0) } : self.summary.duration
        return value.map(ciElapsed) ?? "—"
    }
}

/// Completion belongs inside a run, rather than on the outside edge of its container.
struct CICompactProgress: View {
    private var theme = MimicTheme()
    let summary: CICompactSummary
    var inline = false
    var showsCount = true
    private var layout: AnyLayout { self.inline ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) }
    var body: some View {
        self.layout {
            MimicProgressBar(value: self.summary.fraction, color: theme.tiled ? theme.color("usageOlive") : FooterCIStatus.pipelineColor(self.summary.status), label: text("ci.checks.progress"))
                .scaleEffect(x: 1, y: self.theme.retro ? 1 : 2.0 / 3.0).frame(height: self.theme.retro ? 13 : 4)
            if self.showsCount { Text(self.summary.fraction == nil ? (self.inline ? "—" : text("ci.compact.progress.unknown")) : "\(self.summary.completed ?? 0)/\(self.summary.total ?? 0)")
                .mimicFont(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                .accessibilityLabel(self.summary.fraction == nil ? text("ci.compact.progress.unknown") : text("ci.checks.progress"))
            }
        }
    }
}

struct CIProjectName: View {
    let checkout: String
    var body: some View {
        HStack(spacing: 4) {
            Text("·")
            Text(URL(fileURLWithPath: self.checkout).lastPathComponent).lineLimit(1).truncationMode(.middle)
        }.mimicFont(.caption).foregroundStyle(.secondary).mimicHelp(self.checkout)
    }
}

/// Stable identities keep keyboard focus on its run when active priority changes their order.
struct CICompactRuns: View {
    let summaries: [CICompactSummary]
    let open: (CICompactSummary) -> Void
    var model: TaskCoordinator? = nil
    @Environment(\.mimicTextScale) private var textScale
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(self.summaries, id: \.identity) { summary in
                // Both sizes keep an 8-point inset inside the hover surface. Only the
                // gap above the footer stretches; completed runs reserve no progress row.
                VStack(alignment: .leading, spacing: 0) {
                    Button { self.open(summary) } label: {
                        CICompactBody(summary: summary, fillsAvailableHeight: true, condensed: true, showsContext: false)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Spacer(minLength: 4 * self.textScale)
                    HStack(spacing: self.textScale > 1 ? 2 : 4) {
                        CICompactTiming(summary: summary, compact: true).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
                        if summary.canAnalyze, let model = self.model {
                            CIAnalysisButton(model: model, summary: summary)
                        }
                        if let url = summary.gitlabURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { CIGitLabButton(url: url) }
                    }.frame(height: 28 * self.textScale)
                }.padding(8 * self.textScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .modifier(CIRunSurface(inset: self.summaries.count == 2))
                    .background(PanelControlRegion())
                    .id(summary.checkout + "\0" + summary.identity)
                    .accessibilityIdentifier("ci.compact.run." + summary.id)
                    .accessibilityLabel((summary.displayID ?? text("ci.compact.launch")) + " · " + summary.branch)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Shared lavender pointer feedback preserves the same list identity in compact and detailed CI.
struct CIRunSurface: ViewModifier {
    var inset = true
    @State private var hovered = false
    private var theme = MimicTheme()
    func body(content: Content) -> some View {
        content.background(self.hovered ? self.theme.color("accentSoft") : self.inset ? self.theme.color("paper") : .clear,
                           in: RoundedRectangle(cornerRadius: self.theme.retro ? 0 : 10))
            .onHover { self.hovered = $0 }
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
            }.mimicRetroHeading()
            CICompactBody(summary: self.summary).allowsHitTesting(false)
        }.padding(MimicMetrics.cardInsets).frame(width: MimicMetrics.cardWidth, alignment: .leading)
            .background(CardMouseSurface(open: self.open, label: text("ci.compact.open")))
            .accessibilityIdentifier("ci.quick.activity")
    }
}
