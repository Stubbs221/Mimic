//
//  MimicFooter.swift
//  Mimic
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// A presentation snapshot derived from execution state; it never owns a timer or task.
struct FooterActivity {
    enum Phase: String { case running, queued, checking, closingXcode, blocked, preparing }
    let record: TaskRecord
    let phase: Phase
    let otherCheckout: Bool

    var showsTimer: Bool { self.phase == .running && self.record.startedAt != nil }
    var title: String { taskResultTitle(self.record) }
    var status: String {
        switch self.phase {
        case .running: text("status.running")
        case .queued: text("status.queued")
        case .checking, .preparing: text("footer.task.checking")
        case .closingXcode: text("footer.task.closing.xcode")
        case .blocked: text("footer.task.blocked")
        }
    }
    var symbol: String {
        switch self.phase {
        case .running: "circle.dotted"
        case .queued: "clock"
        case .checking, .preparing: "magnifyingglass"
        case .closingXcode: "hourglass"
        case .blocked: "pause.circle"
        }
    }
    var help: String { self.title + " · " + self.status + "\n" + self.record.project.path + "\n" + self.record.project.branch }

    /// A running process wins over admission of the next request; preflight retains its request ID.
    static func resolve(records: [TaskRecord], launch: LaunchPreparationState, preparing: TaskRecord?, checkout: String) -> Self? {
        if let running = records.first(where: { $0.status == .running }) {
            return Self(record: running, phase: .running, otherCheckout: running.project.path != checkout)
        }
        if let id = launch.taskID, let record = records.first(where: { $0.id == id && $0.status == .queued }) {
            let phase: Phase = switch launch {
            case .checking: .checking
            case .closingXcode: .closingXcode
            case .blockedByXcode: .blocked
            case .idle: .queued
            }
            return Self(record: record, phase: phase, otherCheckout: record.project.path != checkout)
        }
        if let preparing {
            return Self(record: preparing, phase: .preparing, otherCheckout: preparing.project.path != checkout)
        }
        if let queued = records.first(where: { $0.status == .queued }) {
            return Self(record: queued, phase: .queued, otherCheckout: queued.project.path != checkout)
        }
        return nil
    }
}

/// Remote identity and stale/error flags accompany the status, so old success never looks current.
struct FooterCIStatus {
    let connected: Bool
    let loading: Bool
    let error: CIError?
    let pipeline: CIPipeline?
    let commit: String?
    let loadedAt: Date?
    var branch: String? = nil
    var historyIncomplete = false

    var stale: Bool { self.connected && self.error != nil && self.pipeline != nil }
    var otherCommit: Bool { self.connected && self.pipeline.map { $0.ref == self.branch && $0.sha != self.commit } == true }
    var title: String {
        guard self.connected else { return text("footer.ci.disconnected") }
        let status: String
        if self.stale { status = text("footer.ci.stale") }
        else if self.error != nil { status = text("ci.unavailable") }
        else if let pipeline {
            let localized = text("ci.status." + pipeline.status)
            status = localized.hasPrefix("ci.status.") ? pipeline.status : localized
        } else { status = text(self.loading ? "ci.loading" : "ci.empty") }
        return "CI · " + status
    }
    var symbol: String {
        if !self.connected { return "link.circle" }
        if self.error != nil { return "exclamationmark.triangle" }
        return self.pipeline.map { Self.pipelineSymbol($0.status) } ?? (self.loading ? "circle.dotted" : "minus.circle")
    }
    var color: Color {
        if !self.connected { return .secondary }
        if self.error != nil || self.otherCommit { return .orange }
        return self.pipeline.map { Self.pipelineColor($0.status) } ?? .secondary
    }
    var help: String {
        var lines = [self.title]
        if let pipeline {
            let localized = text("ci.status." + pipeline.status)
            lines.append("#\(pipeline.id) · " + (localized.hasPrefix("ci.status.") ? pipeline.status : localized))
            lines.append(pipeline.ref + " · " + String(pipeline.sha.prefix(8)))
        }
        if self.otherCommit { lines.append(text("ci.other.commit") + " " + String(self.pipeline?.sha.prefix(8) ?? "")) }
        if self.historyIncomplete { lines.append(text("ci.history.incomplete")) }
        if let error { lines.append(text(error.localizationKey)) }
        if let loadedAt { lines.append(text("ci.stale") + " · " + loadedAt.formatted(date: .omitted, time: .shortened)) }
        return lines.joined(separator: "\n")
    }

    static func pipelineSymbol(_ status: String) -> String {
        switch status {
        case "success": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        case "running": "circle.dotted"
        case "manual": "hand.raised"
        case "canceled": "stop.circle"
        case "skipped": "minus.circle"
        default: "clock"
        }
    }
    static func pipelineColor(_ status: String) -> Color {
        switch status {
        case "success": .green
        case "failed": .red
        case "running", "pending", "preparing", "waiting_for_resource", "created": .indigo
        default: .secondary
        }
    }
}

// MARK: - Navigation through the existing owners

extension TaskCoordinator {
    var footerActivity: FooterActivity? {
        let preparing = self.quickBootstrapActivity.flatMap { $0.isPreparing(in: self.records) ? $0.request : nil }
        return FooterActivity.resolve(records: self.records, launch: self.launchState, preparing: preparing, checkout: self.selectedProjectPath)
    }

    func openFooterActivity() {
        guard let activity = self.footerActivity else { self.toggleHistory(); return }
        if self.records.contains(where: { $0.id == activity.record.id }) { self.showHistory(id: activity.record.id) }
        else { self.openTool(.bootstrap); self.showPanel?() }
    }

    func toggleFooterCI() {
        if self.ciSettings.connection == nil { self.openSettings(group: .ci) }
        else { self.toggleSection(.ci) }
    }
}

// MARK: - Two pinned rows

struct MimicFooter: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        MimicChrome {
            VStack(spacing: MimicMetrics.small) {
                self.activityRow.frame(height: MimicMetrics.footerRow)
                HStack(spacing: MimicMetrics.medium) {
                    FooterCIButton(state: self.model.ci, settings: self.model.ciSettings, expanded: self.model.panelPage == .home && self.model.expandedSection == .ci, action: self.model.toggleFooterCI)
                    Spacer(minLength: MimicMetrics.medium)
                    Button {
                        if let project = self.model.project { NSWorkspace.shared.open(URL(fileURLWithPath: project.workspace)) }
                    } label: { Label("Xcode", systemImage: "hammer").padding(.horizontal, MimicMetrics.medium).frame(height: MimicMetrics.footerRow).fixedSize(horizontal: true, vertical: false) }
                        .buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).disabled(self.model.project == nil || !self.model.canOpenXcode || self.model.switchingBranch)
                        .help(text("open.xcode")).accessibilityLabel(text("open.xcode")).accessibilityIdentifier("footer.xcode")
                    Button {
                        if let project = self.model.project { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
                    } label: { Label(text("footer.finder"), systemImage: "folder").padding(.horizontal, MimicMetrics.medium).frame(height: MimicMetrics.footerRow).fixedSize(horizontal: true, vertical: false) }
                        .buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).disabled(self.model.project == nil)
                        .help(text("open.finder")).accessibilityLabel(text("open.finder")).accessibilityIdentifier("footer.finder")
                }.font(MimicMetrics.secondary).frame(height: MimicMetrics.footerRow)
            }.padding(.horizontal, MimicMetrics.documentInset).padding(.vertical, MimicMetrics.medium)
        }.frame(height: MimicMetrics.footerHeight).accessibilityIdentifier("mimic.footer")
    }

    private var displayedBuild: BuildActivity? {
        if let active = model.builds.active { return active }
        guard let queued = model.builds.next else { return nil }
        if let legacy = model.footerActivity, legacy.phase != .queued || legacy.record.createdAt <= queued.createdAt { return nil }
        return queued
    }
    private var activityRow: some View {
        Group {
            if let record = displayedBuild {
                Button { model.showBuildResult(record.id) } label: {
                    HStack { Image(systemName: "hammer"); Text(buildTitle(record)); Spacer(); Text(text("build.status." + record.status.rawValue)).font(MimicMetrics.secondary) }.padding(.horizontal, MimicMetrics.medium).frame(height: MimicMetrics.footerRow)
                }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).accessibilityIdentifier("build.footer")
            } else { legacyActivityRow }
        }
    }
    private var legacyActivityRow: some View {
        Button { self.model.openFooterActivity() } label: {
            HStack(spacing: MimicMetrics.medium) {
                if let activity = self.model.footerActivity {
                    Image(systemName: activity.symbol).mimicStatus(activity.phase).foregroundStyle(activity.phase == .blocked ? Color.orange : .secondary).accessibilityHidden(true)
                    Text(activity.title).font(MimicMetrics.body.weight(.medium)).lineLimit(1).truncationMode(.middle).mimicStatus(activity.record.id)
                    if activity.otherCheckout {
                        Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange).help(text("footer.task.other.checkout"))
                            .accessibilityLabel(text("footer.task.other.checkout"))
                    }
                    Spacer(minLength: MimicMetrics.small)
                    if activity.showsTimer {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in Text(duration(activity.record)).monospacedDigit() }
                            .font(MimicMetrics.secondary).foregroundStyle(.secondary).fixedSize().mimicImmediate()
                    } else {
                        Text(activity.status).mimicStatus(activity.phase).font(MimicMetrics.secondary).foregroundStyle(activity.phase == .blocked ? Color.orange : .secondary)
                            .lineLimit(1).fixedSize()
                    }
                } else {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(text("tasks")).font(MimicMetrics.body.weight(.medium))
                    Spacer()
                    Text("⌘1").font(MimicMetrics.secondary).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }.mimicStatus(self.model.footerActivity.map { $0.record.id.uuidString + $0.phase.rawValue } ?? "idle").padding(.horizontal, MimicMetrics.medium).frame(maxWidth: .infinity).frame(height: MimicMetrics.footerRow).contentShape(Rectangle())
        }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).help(self.model.footerActivity?.help ?? text("tasks"))
            .accessibilityLabel(self.model.footerActivity.map { $0.help } ?? text("tasks"))
            .accessibilityValue(disclosureValue(self.model.panelPage == .home && self.model.expandedSection == .tasks)).accessibilityIdentifier("tasks.toggle")
    }
}

/// Observes the existing CI owner directly; no network lifetime is attached to this view.
struct FooterCIButton: View {
    @ObservedObject var state: CIState
    @ObservedObject var settings: CISettingsModel
    let expanded: Bool
    let action: () -> Void
    var presentation: FooterCIStatus {
        FooterCIStatus(connected: self.settings.connection != nil, loading: self.state.loading, error: self.state.error,
                       pipeline: self.state.pipelines.first, commit: self.state.context?.commit, loadedAt: self.state.loadedAt, branch: self.state.context?.branch, historyIncomplete: self.state.historyIncomplete)
    }
    var body: some View {
        let status = self.presentation
        Button(action: self.action) {
            HStack(spacing: MimicMetrics.small) {
                Image(systemName: status.symbol).mimicStatus(status.symbol).foregroundStyle(status.color).accessibilityHidden(true)
                Text(status.title).lineLimit(1).mimicStatus(status.title)
                if status.otherCommit {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(text("footer.ci.other.commit"))
                        .accessibilityLabel(text("footer.ci.other.commit"))
                }
                if status.loading, status.pipeline != nil { ProgressView().controlSize(.mini) }
            }.padding(.horizontal, MimicMetrics.medium).frame(height: MimicMetrics.footerRow).contentShape(Rectangle())
        }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).help(status.help).accessibilityLabel(status.help)
            .accessibilityValue(disclosureValue(self.expanded)).accessibilityIdentifier("ci.expand")
    }
}
