// Created by Василий Маслов on 06.10.2026.
import SwiftUI
import MimicCore

/// Four readable rows share formatting across the grid and floating activity section.
struct CICompactBody: View {
    let summary: CICompactSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(self.summary.branch, systemImage: "arrow.triangle.branch")
                .lineLimit(1).truncationMode(.middle).help(self.summary.branch)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { self.start; Spacer(minLength: 0); self.elapsed(timeline.date) }
                    VStack(alignment: .leading, spacing: 2) { self.start; self.elapsed(timeline.date) }
                }.monospacedDigit().foregroundStyle(.secondary)
            }.mimicImmediate()
            Text(self.current).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(self.summary.runningJobs.isEmpty ? self.current : self.summary.runningJobs.joined(separator: "\n"))
            HStack(spacing: 4) {
                Text(String(format: text("ci.compact.completed"), self.summary.completed.map(String.init) ?? "—", self.summary.complete ? self.summary.total.map(String.init) ?? "—" : "—"))
                    .monospacedDigit().fixedSize()
                Spacer(minLength: 0)
                if self.summary.stale { Image(systemName: "exclamationmark.circle").help(text("ci.compact.stale")).accessibilityLabel(text("ci.compact.stale")) }
            }.foregroundStyle(.secondary)
        }.font(MimicMetrics.secondary).transaction { $0.animation = nil }
    }
    private var start: some View {
        Text(text("ci.time.begin") + " " + (self.summary.startedAt.map { ciDate($0) } ?? "—")).fixedSize()
            .help(self.summary.startedAt?.formatted(date: .complete, time: .complete) ?? "—")
    }
    private func elapsed(_ now: Date) -> some View {
        let value = self.summary.status == "running" && !self.summary.stale
            ? self.summary.startedAt.map { now.timeIntervalSince($0) } : self.summary.duration
        return Text(text("ci.time.duration") + " " + (value.map(ciElapsed) ?? "—")).fixedSize()
    }
    private var current: String {
        if self.summary.runningJobs.count == 1 { return text("ci.checks.current") + " " + self.summary.runningJobs[0] }
        if self.summary.runningJobs.count > 1 { return String(format: text("ci.checks.parallel"), self.summary.runningJobs.count) }
        if self.summary.waitingForManual { return text("ci.checks.manual") }
        if self.summary.active { return text(self.summary.status == "running" ? "ci.progress.unavailable" : "ci.status." + self.summary.status) }
        return text("ci.status." + self.summary.status)
    }
}

/// A bottom-edge line uses evidence-based completion. Unknown progress has only a neutral track.
struct CICompactProgress: View {
    let summary: CICompactSummary
    private var motion = MimicMotion()
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.10))
                if let fraction = self.summary.fraction {
                    Rectangle().fill(FooterCIStatus.pipelineColor(self.summary.status))
                        .frame(width: proxy.size.width)
                        .scaleEffect(x: fraction, y: 1, anchor: .leading)
                        .animation(self.motion.policy(.automatic).animation(.progress), value: fraction)
                }
            }
        }.frame(height: 3).accessibilityElement()
            .accessibilityLabel(text("ci.checks.progress"))
            .accessibilityValue(self.summary.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? text("ci.progress.unavailable"))
    }
}

struct CIActivitySection: View {
    let summary: CICompactSummary
    let open: () -> Void
    let hide: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal").foregroundStyle(PanelCardPalette.color(.ci))
                Text(text("panel.block.ci")).font(MimicMetrics.heading)
                Spacer(minLength: 0)
                CIStatusBadge(status: self.summary.status)
                BootstrapIconButton(symbol: "xmark", label: text("ci.compact.hide"), action: self.hide, inControlBar: true)
            }
            Text(URL(fileURLWithPath: self.summary.checkout).lastPathComponent).font(MimicMetrics.secondary).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(self.summary.checkout)
            CICompactBody(summary: self.summary).allowsHitTesting(false)
        }.padding(16).frame(width: MimicMetrics.cardWidth, alignment: .leading)
            .background(CardMouseSurface(open: self.open, label: text("ci.compact.open")))
            .overlay(alignment: .bottom) { CICompactProgress(summary: self.summary).allowsHitTesting(false) }
            .accessibilityIdentifier("ci.quick.activity")
    }
}
