//
//  BootstrapViews.swift
//  Mimic
//
//  Created by Василий Маслов on 02.10.2026.
import SwiftUI
import MimicCore

/// Layout changes presentation only; both platform buttons capture the standard request.
enum BootstrapCardMode { case mini, full, expanded }

struct BootstrapCard: View {
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var textScale
    @ObservedObject var model: TaskCoordinator
    var mode = BootstrapCardMode.expanded
    var header: AnyView? = nil
    @State private var analysisVisible = false
    private var record: TaskRecord? {
        if let activity = self.model.quickBootstrapActivity {
            if let error = activity.error {
                var failed = activity.record(in: self.model.records); failed.status = .failed; failed.error = error
                return failed
            }
            if self.model.requestingBootstrap || !self.model.records.contains(where: { $0.id == activity.request.id }) && activity.request.status == .cancelled { return activity.request }
        }
        return self.model.bootstrapRecord
    }
    private var live: Bool {
        guard let record else { return false }
        return record.status == .queued || record.status == .running
    }
    private var progress: BootstrapProgress {
        guard let record else { return BootstrapProgress(options: .standard()) }
        if self.model.bootstrapProgressID == record.id { return self.model.bootstrapProgress }
        if let activity = self.model.quickBootstrapActivity, activity.request.id == record.id, let progress = activity.progress { return progress }
        var progress = BootstrapProgress(options: record.options)
        if record.status == .succeeded { progress.finish(succeeded: true) }
        return progress
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BootstrapCardLayout(mode: self.mode) {
                VStack(alignment: .leading, spacing: 4) {
                    if let header { header }
                    else { Text("Bootstrap").mimicFont(.heading).accessibilityAddTraits(.isHeader) }
                    if self.live, let record {
                        self.liveControls(record)
                    } else {
                        (theme.tiled && textScale <= 1.2 ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))) {
                            ForEach(BootstrapPlatform.allCases, id: \.self) { platform in
                                Button { self.model.requestQuickBootstrap(platform: platform) } label: {
                                    Label(text("bootstrap.platform.short." + platform.rawValue), systemImage: platform == .ios ? "iphone" : "tv")
                                        .frame(maxWidth: .infinity)
                                }.buttonStyle(BootstrapControlStyle(primary: true, fillsWidth: true))
                                    .disabled(!self.model.canRequestQuickBootstrap || self.model.checking)
                                    .help(text("quick.bootstrap." + platform.rawValue))
                                    .accessibilityIdentifier("bootstrap.launch." + platform.rawValue)
                            }
                        }.frame(width: theme.tiled ? nil : 104, alignment: .leading)
                    }
                    if let record {
                        BootstrapStateText(model: self.model, record: record, compact: true)
                            .lineLimit(self.live ? 2 : 1)
                        if self.model.launchState != .blockedByXcode(record.id) { HStack(spacing: 4) {
                            if !self.live { Text(text("bootstrap.platform.short." + record.options.platform.rawValue)) }
                            MimicActivityClock(running: record.status == .running && record.startedAt != nil) { _ in
                                Text(record.startedAt == nil ? "" : duration(record)).monospacedDigit()
                            }.mimicImmediate()
                        }.mimicFont(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("bootstrap.last.result") }
                        if self.live, self.model.launchState != .blockedByXcode(record.id) { BootstrapFillBar(value: self.progress.fraction, color: Color(red: 65 / 255, green: 108 / 255, blue: 155 / 255)) }
                    }
                    if !self.live {
                        Text(text("bootstrap.xcode.launch.notice")).mimicFont(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(text("bootstrap.xcode.notice"))
                    }
                    if self.mode == .expanded { self.details }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                self.terminal.frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: self.mode == .mini ? 0 : self.mode == .full ? MimicMetrics.collapsedCardHeight - 32 : 240).clipped()
                    .opacity(self.mode == .mini ? 0 : 1).allowsHitTesting(self.mode != .mini)
                    .accessibilityHidden(self.mode == .mini)
            }
            if self.mode == .expanded, self.analysisVisible, let record, self.model.analysis.sessions[record.id] != nil {
                HStack { Text(text("ai.analysis")).mimicFont(.body, weight: .semibold); Spacer(); Button(text("close")) { self.analysisVisible = false } }
                AnalysisView(model: self.model, id: record.id)
            }
        }.accessibilityIdentifier("bootstrap.card")
            .onChange(of: self.record?.id) { _, _ in self.analysisVisible = false }
    }

    @ViewBuilder private func liveControls(_ record: TaskRecord) -> some View {
        Text(text("bootstrap.platform.short." + record.options.platform.rawValue)).mimicFont(.body, weight: .semibold)
        if self.model.launchState == .blockedByXcode(record.id) {
            Button(text("bootstrap.retry.check")) { self.model.retryBootstrap(id: record.id) }
                .buttonStyle(BootstrapControlStyle(primary: true, fillsWidth: true))
        }
        Button(text(record.status == .running ? "stop" : "bootstrap.cancel")) {
            self.model.cancelQuickBootstrap(id: record.id)
        }.buttonStyle(BootstrapControlStyle(primary: false, fillsWidth: true))
            .accessibilityIdentifier("bootstrap.cancel")
    }

    @ViewBuilder private var details: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(self.progress.stages, id: \.self) { stage in
                let completed = self.progress.completed.contains(stage)
                let current = self.live && self.progress.stage == stage
                Label(text("stage.short." + stage.rawValue), systemImage: completed ? "checkmark.circle.fill" : current ? "circle.dotted" : "circle")
                    .mimicFont(.caption).foregroundStyle(completed ? Color.green : current ? .blue : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityValue(text(completed ? "stage.status.complete" : current ? "stage.status.running" : "stage.status.pending"))
            }
        }.padding(.top, 4).accessibilityIdentifier("bootstrap.stages")
        if let record {
            if self.model.launchState == .blockedByXcode(record.id) {
                Button(text("bootstrap.xcode.activate")) { self.model.activateBlockingXcode() }.buttonStyle(BootstrapControlStyle())
            } else if self.model.launchState == .closingXcode(record.id) {
                Text(text("bootstrap.xcode.dialog")).mimicFont(.caption).foregroundStyle(.secondary)
            }
            if let error = record.error {
                Text(error).mimicFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if record.project.path != self.model.selectedProjectPath {
                Text(record.project.path).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        Text(text("bootstrap.preparation.description")).mimicFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
    }

    private var terminal: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let record, record.status == .failed || record.status == .interrupted {
                Button(text("bootstrap.error.agent")) {
                    self.model.panelLayout.expanded = .bootstrap
                    self.model.prepareAnalysis(record, inline: true); self.analysisVisible = true
                }.buttonStyle(BootstrapControlStyle()).mimicFont(.caption)
                    .fixedSize(horizontal: false, vertical: true).padding(6)
                    .accessibilityIdentifier("bootstrap.analyze")
            }
            if let record {
                BootstrapTaskTerminal(model: self.model, record: record, visible: self.mode != .mini,
                                      fontSize: self.mode == .expanded ? 12 : 10,
                                      session: self.model.bootstrapTerminal(for: record)).id(record.id)
            } else {
                BootstrapTerminalPlaceholder(state: .idle, platform: self.model.bootstrapOptions.platform)
            }
        }
        .background(theme.tiled ? theme.color("terminal") : Color(nsColor: BootstrapTerminalTheme.background))
        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("bootstrap.terminal")
    }
}

/// Width changes retain both subviews, including the task-owned terminal host.
private struct BootstrapCardLayout: Layout {
    var mode: BootstrapCardMode
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        if self.mode == .full {
            let available = max(0, width - 12)
            let controls = subviews[0].sizeThatFits(ProposedViewSize(width: available * 0.4, height: nil))
            let terminal = subviews[1].sizeThatFits(ProposedViewSize(width: available * 0.6, height: nil))
            return CGSize(width: width, height: max(controls.height, terminal.height))
        }
        let controls = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let terminal = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: controls.height + terminal.height + (self.mode == .mini ? 0 : 12))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let available = max(0, bounds.width - 12)
        let controlsWidth = self.mode == .full ? available * 0.4 : bounds.width
        let controlsProposal = ProposedViewSize(width: controlsWidth, height: nil)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: controlsProposal)
        if self.mode == .full {
            subviews[1].place(at: CGPoint(x: bounds.minX + controlsWidth + 12, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: available * 0.6, height: nil))
        } else {
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + subviews[0].sizeThatFits(controlsProposal).height + (self.mode == .mini ? 0 : 12)),
                              anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// The preparation explanation expands inside the card, without another popover.
struct BootstrapQuitNotice: View {
    @State
    var showingDetails = false
    var compact = false
    @State private var source = MimicMotionSource.automatic
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { self.source = .current; self.showingDetails.toggle() } label: {
                Label(text(self.compact ? "bootstrap.xcode.compact" : "bootstrap.xcode.short"), systemImage: "info.circle")
                    .mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain).help(text("bootstrap.xcode.notice")).accessibilityLabel(text("bootstrap.xcode.details"))
                .accessibilityValue(disclosureValue(self.showingDetails))
            MimicCollapse(expanded: self.showingDetails, source: self.source) {
                Text(text("bootstrap.xcode.notice")).mimicFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

/// A blocked record remains queued; closing Xcode manually cannot start it without explicit retry.
struct BootstrapPreparationView: View {
    @ObservedObject
    var model: TaskCoordinator
    let record: TaskRecord
    var showCancel = true
    var showState = true
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.medium) {
            if self.showState { BootstrapStateText(model: self.model, record: self.record) }
            if self.model.launchState == .blockedByXcode(self.record.id) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { self.retryActions }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { self.retryActions }
                }.controlSize(.small)
            } else if self.model.launchState == .closingXcode(self.record.id) {
                Text(text("bootstrap.xcode.dialog")).mimicFont(.caption).foregroundStyle(.secondary)
            }
            if self.showCancel { BootstrapIconButton(symbol: "stop.fill", label: text("bootstrap.cancel.launch")) { self.model.cancel(id: self.record.id) } }
        }.accessibilityIdentifier("bootstrap.preparation")
    }

    @ViewBuilder
    private var retryActions: some View {
        Button(text("bootstrap.retry.check")) { self.model.retryBootstrap(id: self.record.id) }.buttonStyle(BootstrapControlStyle(primary: true))
        Button(text("bootstrap.xcode.activate")) { self.model.activateBlockingXcode() }.buttonStyle(BootstrapControlStyle())
    }

}

/// Substep completion drives the fill; elapsed time is independent and carries no ETA.
struct BootstrapExecutionProgress: View {
    @ObservedObject
    var model: TaskCoordinator
    let record: TaskRecord
    var compact = false
    var showState = true
    private var progress: BootstrapProgress { self.model.bootstrapProgressID == self.record.id ? self.model.bootstrapProgress : BootstrapProgress(options: self.record.options) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.showState { HStack {
                Text(self.progress.currentStep.map { text("bootstrap.step." + $0.rawValue) } ?? text("bootstrap.process.starting")).mimicFont(.body, weight: .medium).mimicStatus(self.progress.currentStep)
                Spacer()
                MimicActivityClock(running: record.status == .running && record.startedAt != nil) { _ in Text(duration(self.record)).font(MimicMetrics.secondary.monospacedDigit()).foregroundStyle(.secondary) }.mimicImmediate()
            }
            }
            BootstrapFillBar(value: self.progress.fraction)
            if !self.compact { HStack(alignment: .top, spacing: MimicMetrics.medium) {
                ForEach(self.progress.stages, id: \.self) { stage in
                    Label(text("stage.short." + stage.rawValue), systemImage: self.progress.completed.contains(stage) ? "checkmark.circle.fill" : self.progress.stage == stage ? "circle.dotted" : "circle")
                        .mimicFont(.caption).foregroundStyle(self.progress.completed.contains(stage) ? Color.green : self.progress.stage == stage ? .indigo : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mimicStatus(self.progress.completed.contains(stage) ? "complete" : self.progress.stage == stage ? "running" : "pending")
                        .accessibilityValue(text(self.progress.completed.contains(stage) ? "stage.status.complete" : self.progress.stage == stage ? "stage.status.running" : "stage.status.pending"))
                }
            }
            }
        }.accessibilityIdentifier("bootstrap.progress")
    }
}

/// The same label survives preparation, execution and completion; only its text and symbol crossfade.
struct BootstrapStateText: View {
    @ObservedObject var model: TaskCoordinator
    let record: TaskRecord
    var compact = false
    private var title: String {
        if self.model.quickBootstrapActivity?.request.id == self.record.id, self.model.quickBootstrapActivity?.error != nil { return text("status.failed") }
        if self.model.quickBootstrapActivity?.request.id == self.record.id,
           self.model.quickBootstrapActivity?.isPreparing(in: self.model.records) == true { return text("bootstrap.preflight") }
        if self.record.status == .queued {
            if self.model.launchState == .blockedByXcode(self.record.id) { return text(self.compact ? "bootstrap.xcode.blocked.compact" : "bootstrap.xcode.blocked") }
            if self.model.launchState == .closingXcode(self.record.id) { return text("bootstrap.xcode.closing") }
            if self.model.launchState == .checking(self.record.id) { return text("bootstrap.preflight") }
        }
        if self.record.status == .running {
            let step = self.model.bootstrapProgressID == self.record.id ? self.model.bootstrapProgress.currentStep : nil
            return step.map { text("bootstrap.step." + $0.rawValue) } ?? text("bootstrap.process.starting")
        }
        return text("status." + self.record.status.rawValue)
    }
    private var symbol: String {
        if self.model.quickBootstrapActivity?.request.id == self.record.id, self.model.quickBootstrapActivity?.error != nil { return "exclamationmark.triangle" }
        if self.model.launchState == .blockedByXcode(self.record.id) { return "pause.circle" }
        if self.model.launchState == .closingXcode(self.record.id) { return "hourglass" }
        if self.model.launchState == .checking(self.record.id) { return "magnifyingglass" }
        return ActionPresentation.statusSymbol(self.record.status)
    }
    private var color: Color {
        if self.model.launchState == .blockedByXcode(self.record.id) || (self.model.quickBootstrapActivity?.request.id == self.record.id && self.model.quickBootstrapActivity?.error != nil) { return .orange }
        return ActionPresentation.statusColor(self.record.status)
    }
    var body: some View {
        Label(self.title, systemImage: self.symbol).mimicFont(.caption, weight: .medium)
            .foregroundStyle(self.color)
            .fixedSize(horizontal: false, vertical: true).mimicStatus(self.title + self.symbol)
            .accessibilityIdentifier("bootstrap.phase")
    }
}
