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
    @State private var controlsWidth: CGFloat = 200
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
    private var live: Bool { self.record.map { [.queued, .running].contains($0.status) } ?? false }
    private var collapsedHeight: CGFloat { MimicMetrics.collapsedCardHeight * (self.theme.tiled ? max(1, self.textScale) : 1) - 24 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BootstrapCardLayout(mode: self.mode, collapsedHeight: self.collapsedHeight) {
                self.controls
                self.terminal.frame(height: self.mode == .mini ? 0 : self.mode == .full ? nil : 240)
                    .clipped().opacity(self.mode == .mini ? 0 : 1).allowsHitTesting(self.mode != .mini)
                    .accessibilityHidden(self.mode == .mini)
            }
            if self.mode == .expanded {
                if let record {
                    BootstrapDetailsFooter(model: self.model, record: record) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { self.expandedActions(record) }.fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 8) { self.expandedActions(record) }
                        }
                    }
                } else { self.launchers }
                MimicDisclosure(text("bootstrap.preparation.title")) {
                    Text(text("bootstrap.preparation.description")).mimicFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.mimicFont(.caption).foregroundStyle(.secondary)
                if self.analysisVisible, let record, self.model.analysis.sessions[record.id] != nil {
                    HStack { Text(text("ai.analysis")).mimicFont(.body, weight: .semibold); Spacer(); Button(text("close")) { self.analysisVisible = false } }
                    AnalysisView(model: self.model, id: record.id)
                }
            }
        }.accessibilityIdentifier("bootstrap.card")
            .onChange(of: self.record?.id) { _, _ in self.analysisVisible = false }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: self.mode == .expanded ? 12 : 4) {
            VStack(alignment: .leading, spacing: 8) {
                if let header { header }
                else { Text("Bootstrap").mimicFont(.heading).accessibilityAddTraits(.isHeader) }
                if !self.live, self.mode != .expanded { self.launchers }
                else if self.mode != .expanded, let record { self.liveControls(record) }
            }
            if self.mode != .expanded { Spacer(minLength: 4) }
            if let record {
                VStack(alignment: .leading, spacing: 4) {
                    if self.mode == .expanded, record.status == .running {
                        Label(text("status.running"), systemImage: ActionPresentation.statusSymbol(record.status))
                            .mimicFont(.caption).foregroundStyle(ActionPresentation.statusColor(record.status))
                    } else {
                        BootstrapStateText(model: self.model, record: record, compact: self.mode != .expanded)
                            .lineLimit(self.live ? 2 : 1)
                    }
                    HStack(spacing: 4) {
                        Text(text("bootstrap.platform.short." + record.options.platform.rawValue))
                        if self.model.launchState != .blockedByXcode(record.id) {
                            MimicActivityClock(running: record.status == .running && record.startedAt != nil) { _ in
                                Text(record.startedAt == nil ? "" : duration(record)).monospacedDigit()
                            }.mimicImmediate()
                        }
                    }.mimicFont(.caption).foregroundStyle(.secondary).accessibilityIdentifier("bootstrap.last.result")
                    if self.live, self.mode != .expanded, self.model.launchState != .blockedByXcode(record.id) {
                        BootstrapExecutionProgress(model: self.model, record: record, compact: true, showState: false)
                    }
                }
            }
            if !self.live, self.mode != .expanded {
                // Preserve the terminal's insets when Full leaves a narrow controls column.
                Label(text(self.mode == .full && self.controlsWidth < 160 ? "bootstrap.xcode.launch.narrow" : "bootstrap.xcode.launch.notice"), systemImage: "exclamationmark.circle")
                    .mimicFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).help(text("bootstrap.xcode.notice"))
                    .accessibilityElement(children: .ignore).accessibilityLabel(text("bootstrap.xcode.launch.notice"))
                    .accessibilityIdentifier("bootstrap.notice")
            }
            if self.mode == .expanded, let record {
                if record.status == .running { BootstrapExecutionProgress(model: self.model, record: record, showClock: false) }
                else if record.status == .queued { BootstrapPreparationView(model: self.model, record: record, showCancel: false, showState: false, showRetryActions: false) }
                if let error = record.error {
                    Text(DiagnosticText.clean(error)).mimicFont(.caption).foregroundStyle(.orange).lineLimit(2).help(error).textSelection(.enabled)
                }
            }
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { self.controlsWidth = $0 }
    }

    private var launchers: some View {
        (self.theme.tiled && self.textScale <= 1.2 && self.controlsWidth >= 160 ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))) {
            ForEach(BootstrapPlatform.allCases, id: \.self) { platform in
                Button { self.model.requestQuickBootstrap(platform: platform) } label: {
                    Label(text("bootstrap.platform.short." + platform.rawValue), systemImage: platform == .ios ? "iphone" : "tv")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(BootstrapControlStyle(primary: true, fillsWidth: true))
                    .disabled(!self.model.canRequestQuickBootstrap || self.model.checking)
                    .help(text("quick.bootstrap." + platform.rawValue))
                    .accessibilityIdentifier("bootstrap.launch." + platform.rawValue)
                    .background(PanelControlRegion())
            }
        }.frame(maxWidth: self.theme.tiled ? .infinity : 104, alignment: .leading)
    }

    @ViewBuilder private func liveControls(_ record: TaskRecord) -> some View {
        if self.model.launchState == .blockedByXcode(record.id) {
            Button(text("bootstrap.retry.check")) { self.model.retryBootstrap(id: record.id) }
                .buttonStyle(BootstrapControlStyle(primary: true, fillsWidth: true)).background(PanelControlRegion())
        }
        Button(text(record.status == .running ? "stop" : "bootstrap.cancel")) { self.model.cancelQuickBootstrap(id: record.id) }
            .buttonStyle(BootstrapControlStyle(primary: false, fillsWidth: true))
            .accessibilityIdentifier("bootstrap.cancel").background(PanelControlRegion())
    }

    @ViewBuilder private func expandedActions(_ record: TaskRecord) -> some View {
        if self.live {
            if self.model.launchState == .blockedByXcode(record.id) {
                BootstrapPreparationView(model: self.model, record: record).retryActions
            }
            Button(text(record.status == .running ? "stop" : "bootstrap.cancel")) { self.model.cancelQuickBootstrap(id: record.id) }
                .buttonStyle(BootstrapControlStyle()).accessibilityIdentifier("bootstrap.cancel").background(PanelControlRegion())
        } else {
            Button(taskRepeatTitle(record)) { self.model.repeatTask(record) }
                .buttonStyle(BootstrapControlStyle(primary: ![.failed, .interrupted].contains(record.status)))
                .disabled(self.model.switchingBranch || self.model.bootstrapLocked).accessibilityIdentifier("task.repeat")
            if [.failed, .interrupted].contains(record.status) {
                Button(text("bootstrap.error.agent")) { self.model.prepareAnalysis(record, inline: true); self.analysisVisible = true }
                    .buttonStyle(BootstrapControlStyle(primary: true)).accessibilityIdentifier("bootstrap.analyze")
            }
        }
    }

    private var terminal: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if self.mode != .expanded, let record, record.status == .failed || record.status == .interrupted {
                Button(text("bootstrap.error.agent")) {
                    self.model.panelLayout.expanded = .bootstrap
                    self.model.prepareAnalysis(record, inline: true); self.analysisVisible = true
                }.buttonStyle(BootstrapControlStyle()).mimicFont(.caption).padding(6)
                    .accessibilityIdentifier("bootstrap.analyze")
            }
            if let record {
                BootstrapTaskTerminal(model: self.model, record: record, visible: self.mode != .mini,
                                      fontSize: self.mode == .expanded ? 12 : 10,
                                      session: self.model.bootstrapTerminal(for: record)).id(record.id)
            } else {
                BootstrapTerminalPlaceholder(state: .idle, platform: self.model.bootstrapOptions.platform)
                    .modifier(BootstrapTerminalSelection(visible: self.mode != .mini))
            }
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .background(self.theme.tiled ? self.theme.color("terminal") : Color(nsColor: BootstrapTerminalTheme.background))
            .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("bootstrap.terminal")
    }
}

/// Both columns receive the same available height; the terminal retains its identity across modes.
struct BootstrapCardLayout: Layout {
    var mode: BootstrapCardMode
    var collapsedHeight: CGFloat = MimicMetrics.collapsedCardHeight - 24
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        if self.mode != .expanded {
            // Collapsed content receives the grid's shared height, including narrow Full columns.
            return CGSize(width: width, height: self.collapsedHeight)
        }
        let controls = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let terminal = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: controls.height + terminal.height + 12)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let available = max(0, bounds.width - 12)
        let controlsWidth = self.mode == .full ? available * 0.4 : bounds.width
        let height = self.mode == .expanded ? nil : Optional(bounds.height)
        let controlsProposal = ProposedViewSize(width: controlsWidth, height: height)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: controlsProposal)
        if self.mode == .full {
            subviews[1].place(at: CGPoint(x: bounds.minX + controlsWidth + 12, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: available * 0.6, height: height))
        } else {
            subviews[1].place(at: CGPoint(x: bounds.minX, y: self.mode == .mini ? bounds.minY : bounds.minY + subviews[0].sizeThatFits(controlsProposal).height + 12),
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
    var showRetryActions = true
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.medium) {
            if self.showState { BootstrapStateText(model: self.model, record: self.record) }
            if self.showRetryActions, self.model.launchState == .blockedByXcode(self.record.id) {
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

    /// The detail footer reuses the same retry and activation commands.
    @ViewBuilder
    var retryActions: some View {
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
    var showClock = true
    private var progress: BootstrapProgress { self.model.bootstrapProgressID == self.record.id ? self.model.bootstrapProgress : BootstrapProgress(options: self.record.options) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.showState { HStack {
                Text(self.progress.currentStep.map { text("bootstrap.step." + $0.rawValue) } ?? text("bootstrap.process.starting")).mimicFont(.body, weight: .medium).mimicStatus(self.progress.currentStep)
                Spacer()
                if self.showClock { MimicActivityClock(running: record.status == .running && record.startedAt != nil) { _ in Text(duration(self.record)).font(MimicMetrics.secondary.monospacedDigit()).foregroundStyle(.secondary) }.mimicImmediate() }
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
