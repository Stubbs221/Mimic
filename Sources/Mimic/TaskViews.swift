//
//  TaskViews.swift
//  Mimic
//
//  Created by Василий Маслов on 01.10.2026.
import AppKit
import SwiftUI
import MimicCore

func duration(_ record: TaskRecord) -> String {
    let seconds = Int(record.duration ?? 0)
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

/// Local tasks and builds share chronological ordering and a single display limit.
enum TaskHistoryEntry: Identifiable {
    case local(TaskRecord)
    case build(BuildActivity)
    var id: UUID {
        switch self { case .local(let record): record.id; case .build(let record): record.id }
    }
    var date: Date {
        switch self { case .local(let record): record.createdAt; case .build(let record): record.createdAt }
    }
    var task: TaskRecord? { if case .local(let record) = self { record } else { nil } }
}

/// History and one selected result participate in the panel's document scrolling.
struct TaskHistoryContent: View {
    @ObservedObject
    var model: TaskCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.medium) {
            HStack {
                Label("\(self.model.summary.succeeded + self.model.builds.records.filter { $0.project.path == self.model.selectedProjectPath && $0.status == .succeeded }.count) " + text("summary.success"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                Spacer()
                Label("\(self.model.summary.failed + self.model.builds.records.filter { $0.project.path == self.model.selectedProjectPath && [.failed, .interrupted].contains($0.status) }.count) " + text("summary.failed"), systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }.mimicFont(.caption)
            TextField(text("tasks.search"), text: self.$model.taskSearch).textFieldStyle(.roundedBorder).accessibilityIdentifier("tasks.search")
            Picker(text("tasks.filter"), selection: self.$model.taskFilter) {
                ForEach(TaskHistoryFilter.allCases, id: \.self) { filter in Text(text("filter." + filter.rawValue)).tag(filter) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("tasks.filter")
            if self.model.filteredTaskRecords.isEmpty && self.model.filteredBuildRecords.isEmpty {
                EmptyState(symbol: "terminal", title: text(self.model.records.isEmpty && self.model.builds.records.isEmpty ? "tasks.empty.title" : "search.empty"), message: text(self.model.records.isEmpty && self.model.builds.records.isEmpty ? "tasks.empty.description" : "search.suggest"))
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(self.model.visibleTaskHistory) { item in
                    switch item {
                    case .local(let record): LegacyHistoryRow(model: model, record: record)
                    case .build(let record): BuildHistoryRow(model: model, builds: model.builds, record: record)
                    }
                }
            }
            if self.model.hasMoreTaskHistory {
                Button(text("tasks.more")) { self.model.showMoreTaskHistory() }
                    .accessibilityIdentifier("tasks.more")
            }
        }.accessibilityIdentifier("tasks.history")
    }
}

/// Bootstrap uses the enclosing row as its header; all analysis stays bound to the original ID.
struct TaskDetails: View {
    @ObservedObject
    var model: TaskCoordinator
    let record: TaskRecord
    private var failed: Bool { self.record.status == .failed || self.record.status == .interrupted }
    private var live: Bool { self.record.status == .running || self.record.status == .queued }
    private var expanded: Binding<Bool> {
        Binding(get: { self.model.expandedAnalysisIDs.contains(self.record.id) }, set: { value in
            if value { self.model.expandedAnalysisIDs.insert(self.record.id) }
            else { self.model.expandedAnalysisIDs.remove(self.record.id) }
        })
    }

    var body: some View {
        if self.record.action == .bootstrap { BootstrapHistoryDetails(model: self.model, record: self.record) }
        else { self.generalBody }
    }

    private var generalBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ActionIcon(action: self.record.action)
                VStack(alignment: .leading, spacing: 6) {
                    Text(taskResultTitle(self.record)).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if let name = self.record.generation?.name ?? self.record.simulator?.name { Text(name).font(.system(size: 12)).foregroundStyle(.secondary) }
                    HStack(spacing: MimicMetrics.medium) {
                        Label(taskResultStatus(self.record), systemImage: ActionPresentation.statusSymbol(self.record.status)).foregroundStyle(ActionPresentation.statusColor(self.record.status)).mimicStatus(self.record.status)
                        MimicActivityClock(running: record.status == .running && record.startedAt != nil) { _ in Text(duration(self.record)).monospacedDigit().foregroundStyle(.secondary) }.mimicImmediate()
                    }.font(.system(size: 12)).accessibilityIdentifier("task.result.status")
                }
                Spacer(minLength: 0)
            }
            if let progress = self.model.profileProgress[self.record.id], self.record.status == .running { Text(progress).mimicFont(.caption) }
            TaskTechnicalData(model: self.model, record: self.record)
            if self.failed { DiagnosticOutputView(snapshot: self.model.diagnosticSnapshot(for: self.record), sensitive: self.record.metadataOnly) }
            else if let error = self.record.error { Text(DiagnosticText.clean(error)).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            if self.record.requiresXcodeQuit, self.record.status == .queued {
                BootstrapPreparationView(model: self.model, record: self.record, showCancel: false)
            } else if !self.failed, !self.record.metadataOnly || self.record.status == .running {
                TerminalContainer(model: self.model, id: self.record.id).id("terminal." + self.record.id.uuidString).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 8)).mimicImmediate()
                if self.record.status == .running { Label(text("terminal.hint"), systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { self.actions; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { self.actions }
            }
            if self.model.analysis.sessions[self.record.id] != nil {
                MimicDisclosure(isExpanded: self.expanded) {
                    AnalysisView(model: self.model, id: self.record.id)
                } label: {
                    Text(text("ai.analysis")).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                }.id("analysis." + self.record.id.uuidString).accessibilityIdentifier("task.analysis.disclosure")
            }
            if let path = self.record.logPath {
                Button(text("log.open")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.buttonStyle(BootstrapControlStyle())
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("task.details")
    }

    @ViewBuilder
    private var actions: some View {
        if self.live {
            BootstrapIconButton(symbol: "stop.fill", label: text("stop")) { self.model.cancel(id: self.record.id) }
        } else {
            if self.failed, self.model.analysis.sessions[self.record.id] == nil {
                Button(text("ai.analyze")) { self.model.prepareAnalysis(self.record) }.buttonStyle(BootstrapControlStyle(primary: true)).accessibilityIdentifier("task.analyze")
            }
            Button(taskRepeatTitle(self.record)) { self.model.repeatTask(self.record) }.buttonStyle(BootstrapControlStyle(primary: !self.failed))
                .disabled(self.model.switchingBranch || (self.record.action == .bootstrap && self.model.bootstrapLocked)).accessibilityIdentifier("task.repeat")
        }
    }
}

struct LegacyHistoryRow: View {
    @ObservedObject var model: TaskCoordinator
    let record: TaskRecord
    var body: some View {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { self.model.toggleTask(record.id) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: ActionPresentation.statusSymbol(record.status)).foregroundStyle(ActionPresentation.statusColor(record.status)).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(taskResultTitle(record)).font(.system(size: 12, weight: .semibold))
                                    if let name = record.generation?.name ?? record.simulator?.name { Text(name).mimicFont(.caption).lineLimit(2).help(name) }
                                    Text(URL(fileURLWithPath: record.project.path).lastPathComponent + " · " + record.project.branch).mimicFont(.caption).foregroundStyle(.secondary).lineLimit(2).help(record.project.path + " · " + record.project.branch)
                                    HStack {
                                        Text(record.action == .bootstrap ? taskResultStatus(record) : text("status." + record.status.rawValue))
                                        if record.action == .bootstrap, record.startedAt != nil {
                                            MimicActivityClock(running: record.status == .running) { _ in Text(duration(record)).monospacedDigit() }.mimicImmediate()
                                        }
                                        Spacer()
                                        Text(record.createdAt, style: .time)
                                    }.mimicFont(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: self.model.selectedTaskID == record.id ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets(top: 7, leading: MimicMetrics.medium, bottom: 7, trailing: MimicMetrics.medium))).accessibilityValue(disclosureValue(self.model.selectedTaskID == record.id)).accessibilityIdentifier("task.toggle." + record.id.uuidString)
                        MimicCollapse(expanded: self.model.selectedTaskID == record.id, source: self.model.navigationSource) { TaskDetails(model: self.model, record: record).id("details." + record.id.uuidString) }
                        Divider()
                    }.id("task." + record.id.uuidString)
    }
}
