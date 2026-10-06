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
    private var layout: AnyLayout {
        self.mode == .full ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: self.mode == .mini ? 0 : 12))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.layout {
                VStack(alignment: .leading, spacing: 10) {
                    if let header { header }
                    else { Text("Bootstrap").font(MimicMetrics.heading).accessibilityAddTraits(.isHeader) }
                    HStack(spacing: 8) {
                        ForEach(BootstrapPlatform.allCases, id: \.self) { platform in
                            Button { self.model.requestQuickBootstrap(platform: platform) } label: {
                                Text(text("bootstrap.platform.short." + platform.rawValue)).frame(maxWidth: .infinity)
                            }.buttonStyle(BootstrapControlStyle(primary: true, fillsWidth: true))
                                .disabled(!self.model.canRequestQuickBootstrap || self.model.checking)
                                .help(text("quick.bootstrap." + platform.rawValue))
                                .accessibilityIdentifier("bootstrap.launch." + platform.rawValue)
                        }
                    }
                    if self.mode == .expanded { self.details }
                    else if self.mode == .full, let record {
                        BootstrapStateText(model: self.model, record: record).lineLimit(2)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                self.terminal.frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: self.mode == .mini ? 0 : self.mode == .full ? MimicMetrics.collapsedCardHeight - 32 : 240).clipped()
                    .opacity(self.mode == .mini ? 0 : 1).allowsHitTesting(self.mode != .mini)
                    .accessibilityHidden(self.mode == .mini)
            }
            if self.mode == .expanded, self.analysisVisible, let record, self.model.analysis.sessions[record.id] != nil {
                HStack { Text(text("ai.analysis")).font(MimicMetrics.body.weight(.semibold)); Spacer(); Button(text("close")) { self.analysisVisible = false } }
                AnalysisView(model: self.model, id: record.id)
            }
        }.tint(.indigo).accessibilityIdentifier("bootstrap.card")
            .onChange(of: self.record?.id) { _, _ in self.analysisVisible = false }
    }

    @ViewBuilder private var details: some View {
        if let record {
            VStack(alignment: .leading, spacing: 4) {
                BootstrapStateText(model: self.model, record: record)
                HStack {
                    Text(text("bootstrap.platform.short." + record.options.platform.rawValue))
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in Text(record.startedAt == nil ? "" : duration(record)).monospacedDigit() }.mimicImmediate()
                }.font(MimicMetrics.secondary).foregroundStyle(.secondary)
            }.accessibilityIdentifier("bootstrap.last.result")
            if self.model.requestingBootstrap {
                Button(text("bootstrap.cancel.launch")) { self.model.cancelQuickBootstrap(id: record.id) }.buttonStyle(BootstrapControlStyle())
            } else if record.status == .queued {
                BootstrapPreparationView(model: self.model, record: record, showCancel: true, showState: false)
            } else if record.status == .running {
                BootstrapExecutionProgress(model: self.model, record: record, compact: self.mode == .full, showState: false)
                Button(text("stop")) { self.model.cancel(id: record.id) }.buttonStyle(BootstrapControlStyle())
            }
            if let error = self.model.quickBootstrapActivity?.request.id == record.id ? self.model.quickBootstrapActivity?.error ?? record.error : record.error {
                Text(error).font(MimicMetrics.secondary).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if record.project.path != self.model.selectedProjectPath {
                Text(record.project.path).font(MimicMetrics.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        Label(text("bootstrap.xcode.compact"), systemImage: "info.circle")
            .font(MimicMetrics.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var terminal: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if let record {
                    BootstrapTerminalContainer(model: self.model, record: record, visible: self.mode != .mini).id(record.id)
                        .padding(.top, record.status == .failed || record.status == .interrupted ? 52 : 0)
                    if !self.model.bootstrapTerminal(for: record).hasOutput {
                        Text(text(record.status == .running || record.status == .queued ? "bootstrap.terminal.waiting" : "task.output.unavailable"))
                            .font(MimicMetrics.secondary).foregroundStyle(.secondary).padding(12).allowsHitTesting(false)
                    }
                } else {
                    Text(text("bootstrap.terminal.choose")).font(MimicMetrics.secondary).foregroundStyle(.secondary).padding(12)
                }
            }
            if let record, record.status == .failed || record.status == .interrupted {
                Button(text("bootstrap.error.agent")) {
                    self.model.panelLayout.expanded = .bootstrap
                    self.model.prepareAnalysis(record, inline: true); self.analysisVisible = true
                }.buttonStyle(BootstrapControlStyle()).font(MimicMetrics.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(6)
                    .accessibilityIdentifier("bootstrap.analyze")
            }
        }.background(PanelControlRegion()).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("bootstrap.terminal")
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
                    .font(MimicMetrics.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain).help(text("bootstrap.xcode.notice")).accessibilityLabel(text("bootstrap.xcode.details"))
                .accessibilityValue(disclosureValue(self.showingDetails))
            MimicCollapse(expanded: self.showingDetails, source: self.source) {
                Text(text("bootstrap.xcode.notice")).font(MimicMetrics.secondary).foregroundStyle(.secondary)
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
                Text(text("bootstrap.xcode.dialog")).font(MimicMetrics.secondary).foregroundStyle(.secondary)
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
                Text(self.progress.currentStep.map { text("bootstrap.step." + $0.rawValue) } ?? text("bootstrap.process.starting")).font(MimicMetrics.body.weight(.medium)).mimicStatus(self.progress.currentStep)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in Text(duration(self.record)).font(MimicMetrics.secondary.monospacedDigit()).foregroundStyle(.secondary) }.mimicImmediate()
            }
            }
            BootstrapFillBar(value: self.progress.fraction)
            if !self.compact { HStack(alignment: .top, spacing: MimicMetrics.medium) {
                ForEach(self.progress.stages, id: \.self) { stage in
                    Label(text("stage.short." + stage.rawValue), systemImage: self.progress.completed.contains(stage) ? "checkmark.circle.fill" : self.progress.stage == stage ? "circle.dotted" : "circle")
                        .font(MimicMetrics.secondary).foregroundStyle(self.progress.completed.contains(stage) ? Color.green : self.progress.stage == stage ? .indigo : .secondary)
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
    private var title: String {
        if self.model.quickBootstrapActivity?.request.id == self.record.id, self.model.quickBootstrapActivity?.error != nil { return text("status.failed") }
        if self.model.quickBootstrapActivity?.request.id == self.record.id,
           self.model.quickBootstrapActivity?.isPreparing(in: self.model.records) == true { return text("bootstrap.preflight") }
        if self.record.status == .queued {
            if self.model.launchState == .blockedByXcode(self.record.id) { return text("bootstrap.xcode.blocked") }
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
        Label(self.title, systemImage: self.symbol).font(MimicMetrics.secondary.weight(.medium))
            .foregroundStyle(self.color)
            .fixedSize(horizontal: false, vertical: true).mimicStatus(self.title + self.symbol)
            .accessibilityIdentifier("bootstrap.phase")
    }
}
