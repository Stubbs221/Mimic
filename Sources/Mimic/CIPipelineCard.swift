//
//  CIPipelineCard.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Numeric timers have stable width and never confuse run age with duration.
func ciElapsed(_ interval: TimeInterval) -> String {
    guard interval.isFinite else { return "—" }
    let seconds = Int(min(999_999_999, max(0, interval)))
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

func ciDate(_ date: Date, now: Date = .now) -> String {
    let formatter = DateFormatter(); formatter.locale = .current; formatter.timeZone = .current
    if Calendar.current.isDate(date, inSameDayAs: now) { formatter.dateFormat = "HH:mm" }
    else if Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now) { formatter.dateFormat = "dd.MM HH:mm" }
    else { formatter.dateFormat = "dd.MM.yyyy HH:mm" }
    return formatter.string(from: date)
}

private func ciFullDate(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.locale = .current; formatter.timeZone = .current
    formatter.dateFormat = "dd.MM.yyyy HH:mm:ss zzz"
    return formatter.string(from: date)
}

/// The username can consume at most a third of this row; the branch receives the remainder.
private struct CIBranchLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        let user = subviews.count > 1 ? min(width / 3, subviews[1].sizeThatFits(.unspecified).width) : 0
        let branch = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, width - user - (user > 0 ? 6 : 0)), height: nil))
        return CGSize(width: width, height: max(branch.height, subviews.count > 1 ? subviews[1].sizeThatFits(ProposedViewSize(width: user, height: nil)).height : 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let user = subviews.count > 1 ? min(bounds.width / 3, subviews[1].sizeThatFits(.unspecified).width) : 0
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: max(0, bounds.width - user - (user > 0 ? 6 : 0)), height: bounds.height))
        if subviews.count > 1 { subviews[1].place(at: CGPoint(x: bounds.maxX - user, y: bounds.minY), proposal: ProposedViewSize(width: user, height: bounds.height)) }
    }
}

struct CIPipelineCard: View {
    @ObservedObject var state: CIState
    let entry: CIFeedEntry
    var presented = true
    private var pipelineID: Int? { self.entry.pipeline?.id ?? self.entry.run?.pipelineID }
    private var summary: CIProgressSummary? { self.pipelineID.flatMap { self.state.summaries[$0] } }
    private var isExpanded: Bool { self.pipelineID != nil && self.state.selectedPipelineID == self.pipelineID }
    private var commitTitle: String? { self.entry.sha.flatMap { self.state.commitTitles[$0] } ?? self.summary?.commitTitle }
    /// Credential failures belong to the shared connection banner, rather than each run.
    private var detailError: CIError? {
        guard let error = self.state.detailError, error != .credential, error != .authentication else { return nil }
        return error
    }
    private var incomplete: Bool {
        guard let id = self.pipelineID else { return false }
        if let error = self.state.enrichmentErrors[id], error == .credential || error == .authentication { return false }
        return [.partial, .failed].contains(self.state.metadataStates[id] ?? .notRequested) || [.partial, .failed].contains(self.state.checkStates[id] ?? .notRequested)
    }
    private var title: String {
        let kind = self.entry.run.map { text($0.kind.localizationKey) }
        if let id = self.pipelineID { return "#\(id)" + (kind.map { " · " + $0 } ?? "") }
        var values = kind.map { [$0] } ?? []
        if let number = self.entry.run?.buildURL?.lastPathComponent, Int(number) != nil { values.append("Jenkins #" + number) }
        else if let queue = self.entry.run?.queueURL?.lastPathComponent, Int(queue) != nil { values.append(text("ci.queue") + " Jenkins #" + queue) }
        return values.joined(separator: " · ")
    }

    // MARK: - Compact card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(self.title).mimicFont(.body, weight: .semibold).lineLimit(1).mimicHelp(self.title).textSelection(.enabled)
                Spacer(minLength: 4)
                CIStatusBadge(status: self.entry.status)
                if self.incomplete { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).mimicHelp(text("ci.checks.incomplete")) }
                if let id = self.pipelineID {
                    Button { if self.isExpanded { self.state.clearDetails() } else { self.state.loadDetails(id) } } label: {
                        Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down").frame(width: 28, height: 28)
                    }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).background(PanelControlRegion())
                        .accessibilityLabel(self.title + " · " + text("ci.run.information"))
                        .accessibilityValue(disclosureValue(self.isExpanded)).accessibilityIdentifier("ci.card." + self.entry.id)
                }
            }
            HStack(spacing: 6) {
                CIBranchLayout {
                    Label(self.entry.branch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle).mimicHelp(self.entry.branch)
                    if let user = self.entry.participant { Text("@" + user.username).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).mimicHelp("@" + user.username + " · " + user.name) }
                }
            }
            self.timing
            if self.entry.status == "running", let summary = self.summary { self.progress(summary) }
            else if self.entry.status == "running" { Text(text("ci.progress.unavailable")).foregroundStyle(.secondary) }
            else if ["manual", "blocked"].contains(self.entry.status) { Text(text("ci.checks.manual")).foregroundStyle(.orange) }
            if self.entry.status == "failed", let failed = self.summary?.failed.first {
                Text(text("ci.checks.failed") + " " + failed.name).foregroundStyle(.red).lineLimit(2).mimicHelp(failed.name)
            }
            if let error = self.entry.run?.error, !["ci.error.credential", "jenkins.error.credential", "ci.error.authentication", "jenkins.error.authentication"].contains(error) { Text(text(error)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if self.isExpanded { self.details }
        }.mimicFont(.caption).padding(8).modifier(CIRunSurface()).accessibilityElement(children: .contain)
    }

    private var startLabel: String? {
        if let date = self.entry.pipeline?.startedAt { return text("ci.time.begin") + " " + ciDate(date) }
        if let date = self.entry.createdAt { return text(["queued", "pending", "triggering"].contains(self.entry.status) ? "ci.time.queued" : "ci.time.created") + " " + ciDate(date) }
        return nil
    }
    private var timing: some View {
        Group {
            if self.entry.status == "running", let started = self.entry.pipeline?.startedAt {
                MimicActivityClock(running: true) { now in self.timeRow(ciElapsed(now.timeIntervalSince(started))) }
            } else {
                let duration = self.entry.pipeline?.duration ?? self.entry.pipeline.flatMap { pipeline in
                    guard let started = pipeline.startedAt, let finished = pipeline.finishedAt, finished >= started else { return nil as Double? }
                    return finished.timeIntervalSince(started)
                }
                self.timeRow(duration.map(ciElapsed) ?? "—")
            }
        }.foregroundStyle(.secondary).monospacedDigit()
    }
    private func timeRow(_ duration: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(text("ci.time.duration") + " " + duration).fixedSize()
                Spacer(minLength: 8)
                if let label = self.startLabel { Text(label).fixedSize().mimicHelp((self.entry.pipeline?.startedAt ?? self.entry.createdAt).map(ciFullDate) ?? "") }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text("ci.time.duration") + " " + duration).fixedSize()
                if let label = self.startLabel { HStack { Spacer(minLength: 0); Text(label).fixedSize().mimicHelp((self.entry.pipeline?.startedAt ?? self.entry.createdAt).map(ciFullDate) ?? "") } }
            }
        }
    }

    // MARK: - Active checks and disclosure

    @ViewBuilder private func progress(_ summary: CIProgressSummary) -> some View {
        if summary.waitingForManual { Text(text("ci.checks.manual")).foregroundStyle(.orange) }
        else {
            if summary.running.count == 1, let job = summary.running.first {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text("ci.checks.current") + " " + job.name).lineLimit(2).mimicHelp(job.name)
                    Spacer(minLength: 2)
                    if let started = job.startedAt { MimicActivityClock(running: true) { now in Text(ciElapsed(now.timeIntervalSince(started))).monospacedDigit().fixedSize() } }
                }
            } else if summary.running.count > 1 { Text(String(format: text("ci.checks.parallel"), summary.running.count)).mimicHelp(summary.running.map(\.name).joined(separator: "\n")) }
            if summary.complete, summary.total > 0 {
                MimicProgressBar(value: Double(summary.completed) / Double(summary.total), color: FooterCIStatus.pipelineColor(self.entry.status), label: text("ci.checks.progress"))
                    .accessibilityValue(String(format: text("ci.checks.completed"), summary.completed, summary.total))
                Text(String(format: text("ci.checks.completed"), summary.completed, summary.total)).foregroundStyle(.secondary).monospacedDigit()
            } else { Text(text("ci.progress.unavailable")).foregroundStyle(.secondary) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.incomplete || self.detailError != nil, let id = self.pipelineID {
                Text(text(self.detailError?.localizationKey ?? self.state.enrichmentErrors[id]?.localizationKey ?? "ci.checks.incomplete")).foregroundStyle(.secondary)
                Button(text("ci.details.retry")) { self.state.retryDetails(id) }
                    .background(PanelControlRegion())
            }
            CIPipelineDetailsView(presented: self.presented, state: self.state)
            if let summary = self.summary {
                let rootIDs = Set(self.state.details?.jobs.map(\.id) ?? [])
                let children = summary.jobs.filter { !rootIDs.contains($0.id) }
                if !children.isEmpty {
                    Text(text("ci.children.jobs")).fontWeight(.semibold)
                    ForEach(Array(Set(children.map(\.stage))).sorted(), id: \.self) { stage in
                        Text(stage).foregroundStyle(.secondary)
                        ForEach(children.filter { $0.stage == stage }) { job in
                            HStack { Text(job.name).lineLimit(2).mimicHelp(job.name); Spacer(minLength: 4); CIStatusBadge(status: job.status); CIWebButton(url: job.webURL) }
                            if job.allowFailure { Text(text(job.status == "failed" ? "ci.job.allowedFailure" : "ci.allowed.failure")).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            DisclosureGroup(text("ci.run.information")) {
                if let name = self.entry.pipeline?.name, !name.isEmpty, name != self.commitTitle { Text(name).textSelection(.enabled) }
                if let title = self.commitTitle { Text(title).textSelection(.enabled) }
                if let sha = self.entry.sha { Text(sha).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                if let created = self.entry.createdAt { Text(text("ci.time.created") + " " + ciFullDate(created)) }
                if let started = self.entry.pipeline?.startedAt { Text(text("ci.time.begin") + " " + ciFullDate(started)) }
                if let finished = self.entry.pipeline?.finishedAt { Text(text("ci.time.finished") + " " + ciFullDate(finished)) }
                if let sha = self.entry.sha {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sha, forType: .string) } label: { Image(systemName: "doc.on.doc").frame(width: 28, height: 28) }
                        .buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).accessibilityLabel(text("copy"))
                }
            }
            HStack(spacing: 12) {
                if let url = self.entry.run?.buildURL ?? self.entry.run?.queueURL { self.link("Jenkins", url: url) }
                if let url = self.entry.run?.allureURL { self.link("Allure", url: url) }
                Spacer(minLength: 0)
                if let url = self.entry.pipeline?.webURL ?? self.entry.run?.pipelineURL { CIGitLabButton(url: url) }
            }
        }.padding(.leading, 8)
    }
    private func link(_ title: String, url: URL) -> some View { HStack(spacing: 3) { Text(title); CIWebButton(url: url) } }
}
