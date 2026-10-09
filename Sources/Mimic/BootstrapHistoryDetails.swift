//
//  BootstrapHistoryDetails.swift
//  Mimic
//
//  Created by Василий Маслов on 09.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Actions and technical fields share a footer, with a vertical fallback for long labels.
struct BootstrapDetailsFooter<Actions: View>: View {
    @ObservedObject var model: TaskCoordinator
    let record: TaskRecord
    @ViewBuilder var actions: () -> Actions
    @State private var technicalExpanded = false
    @State private var source = MimicMotionSource.automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    self.actions().fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    self.disclosure.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) { self.actions(); self.disclosure }
            }
            MimicCollapse(expanded: self.technicalExpanded, source: self.source) {
                TaskTechnicalData(model: self.model, record: self.record).content
            }
        }.accessibilityIdentifier("bootstrap.details.footer")
    }

    private var disclosure: some View {
        Button { self.source = .current; self.technicalExpanded.toggle() } label: {
            Label(text("task.technical"), systemImage: self.technicalExpanded ? "chevron.down" : "chevron.right")
                .mimicFont(.caption).foregroundStyle(.secondary)
        }.buttonStyle(.plain).accessibilityValue(disclosureValue(self.technicalExpanded))
            .accessibilityIdentifier("task.technical")
    }
}

/// The enclosing history row owns the header. This screen never borrows the card's renderer.
struct BootstrapHistoryDetails: View {
    @ObservedObject var model: TaskCoordinator
    let record: TaskRecord
    private var live: Bool { [.queued, .running].contains(self.record.status) }
    private var failed: Bool { [.failed, .interrupted].contains(self.record.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.record.status == .running {
                BootstrapExecutionProgress(model: self.model, record: self.record, showClock: false)
            } else if self.record.status == .queued {
                BootstrapPreparationView(model: self.model, record: self.record, showCancel: false, showRetryActions: false)
            }
            if let error = self.record.error {
                Text(DiagnosticText.clean(error)).mimicFont(.caption).foregroundStyle(.orange)
                    .lineLimit(2).help(error).textSelection(.enabled)
            }
            BootstrapHistoryTerminal(model: self.model, record: self.record).id(self.record.id)
                .frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 10)).mimicImmediate()
            BootstrapDetailsFooter(model: self.model, record: self.record) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { self.actions }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { self.actions }
                }
            }
            if self.model.analysis.sessions[self.record.id] != nil {
                MimicDisclosure(isExpanded: Binding(get: { self.model.expandedAnalysisIDs.contains(self.record.id) }, set: { value in
                    if value { self.model.expandedAnalysisIDs.insert(self.record.id) }
                    else { self.model.expandedAnalysisIDs.remove(self.record.id) }
                })) {
                    AnalysisView(model: self.model, id: self.record.id)
                } label: { Text(text("ai.analysis")).mimicFont(.body, weight: .semibold) }
                .accessibilityIdentifier("task.analysis.disclosure")
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("task.details")
    }

    @ViewBuilder private var actions: some View {
        if self.live {
            if self.model.launchState == .blockedByXcode(self.record.id) {
                BootstrapPreparationView(model: self.model, record: self.record).retryActions
            }
            Button(text(self.record.status == .running ? "stop" : "bootstrap.cancel")) { self.model.cancel(id: self.record.id) }
                .buttonStyle(BootstrapControlStyle()).accessibilityIdentifier("task.cancel")
        } else {
            if self.failed {
                Button(text("ai.analyze")) {
                    self.model.prepareAnalysis(self.record, inline: true)
                    self.model.expandedAnalysisIDs.insert(self.record.id)
                }.buttonStyle(BootstrapControlStyle(primary: true)).accessibilityIdentifier("task.analyze")
            }
            Button(taskRepeatTitle(self.record)) { self.model.repeatTask(self.record) }
                .buttonStyle(BootstrapControlStyle(primary: !self.failed))
                .disabled(self.model.switchingBranch || self.model.bootstrapLocked).accessibilityIdentifier("task.repeat")
        }
        if self.failed, !self.model.diagnosticSnapshot(for: self.record).outputUnavailable {
            Button(text("task.output.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.model.diagnosticSnapshot(for: self.record).text, forType: .string)
            }.buttonStyle(BootstrapControlStyle()).accessibilityIdentifier("task.output.copy")
        }
        if let path = self.record.logPath {
            Button(text("log.open")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.buttonStyle(BootstrapControlStyle())
        }
    }
}

/// Separate subscriptions and screens allow card and history to stay mounted simultaneously.
private struct BootstrapHistoryTerminal: View {
    let model: TaskCoordinator
    let record: TaskRecord
    @StateObject private var session: BootstrapTerminalSession
    init(model: TaskCoordinator, record: TaskRecord) {
        self.model = model; self.record = record
        self._session = StateObject(wrappedValue: BootstrapTerminalSession(model: model, record: record, replay: model.terminalSnapshot(id: record.id)))
    }
    var body: some View {
        BootstrapTaskTerminal(model: self.model, record: self.record, visible: true, fontSize: 12, session: self.session)
    }
}
