//
//  TaskResultViews.swift
//  Mimic
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import SwiftUI
import MimicCore

func taskResultTitle(_ record: TaskRecord) -> String {
    record.displayTitle ?? (record.action == .bootstrap ? "Bootstrap " + text("bootstrap.platform.short." + record.options.platform.rawValue) : text(record.action.titleKey))
}

func taskResultStatus(_ record: TaskRecord) -> String {
    if record.status == .failed { return text(record.exitCode == nil ? "task.result.launch.failed" : "task.result.process.failed") }
    return text("status." + record.status.rawValue)
}

func taskRepeatTitle(_ record: TaskRecord) -> String {
    if let title = record.displayTitle { return String(format: text("task.repeat.format"), title) }
    return switch record.action {
    case .bootstrap: String(format: text("task.repeat.format"), "Bootstrap")
    case .simulatorBoot: text("task.repeat.simulator.boot")
    case .simulatorShutdown: text("task.repeat.simulator.shutdown")
    default: String(format: text("task.repeat.format"), text("tool.name." + record.action.rawValue))
    }
}

struct TaskTechnicalData: View {
    @ObservedObject
    var model: TaskCoordinator
    let record: TaskRecord
    var body: some View {
        MimicDisclosure(text("task.technical")) {
            VStack(alignment: .leading, spacing: 8) {
                if let code = self.record.exitCode {
                    Text(String(format: text("task.exit.code.format"), code)).accessibilityIdentifier("task.exit.code")
                    if code != 0 { Text(text("task.exit.explanation")).foregroundStyle(.secondary) }
                }
                if let signal = self.record.signal, signal > 0 { Text(String(format: text("task.signal.format"), signal)) }
                self.field("task.checkout", self.record.project.path)
                self.field("task.branch", self.record.project.branch)
                self.field("task.commit", self.record.project.commit)
                self.field("task.xcode", self.record.project.developerDirectory ?? text("task.not.specified"))
                if let execution = self.record.profileExecution {
                    self.field("profile.revision", execution.snapshot.id + " · " + execution.snapshot.revision)
                    ForEach(execution.action?.parameters ?? []) { parameter in
                        Text(parameter.title + ": " + (execution.parameters[parameter.id] ?? parameter.defaultValue)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let command = self.model.commandDisplay(for: self.record) {
                    Text(text("task.command")).foregroundStyle(.secondary)
                    Text(command).font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Button { self.model.copyCommand(record: self.record) } label: { Label(text("copy.command"), systemImage: "doc.on.doc") }
                        .buttonStyle(BootstrapControlStyle()).accessibilityIdentifier("task.command.copy")
                }
            }.padding(.top, 8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12)).accessibilityIdentifier("task.technical")
    }

    private func field(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text(key)).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Folding and the short preview affect only presentation, never copying or an AI request.
struct DiagnosticOutputView: View {
    let snapshot: DiagnosticSnapshot
    var sensitive = false
    @State
    private var unfolded: Set<Int> = []
    @State
    private var showAll = false
    @State private var source = MimicMotionSource.automatic
    @State
    private var copied = false
    private var groups: [DiagnosticLineGroup] { DiagnosticLineGroup.groups(in: self.snapshot.text) }
    private var visible: [DiagnosticLineGroup] { Array(self.groups.suffix(12)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(text("task.error.output")).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if !self.snapshot.outputUnavailable {
                    Button(text(self.copied ? "ai.copied" : "task.output.copy")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.snapshot.text, forType: .string); self.copied = true
                    }.buttonStyle(BootstrapControlStyle()).accessibilityIdentifier("task.output.copy")
                }
            }
            if self.snapshot.truncated { Text(text("ai.fragment.truncated")).foregroundStyle(.secondary) }
            if self.sensitive { Text(text("task.output.memory")).foregroundStyle(.secondary) }
            if self.snapshot.outputUnavailable {
                Text(text("task.output.unavailable")).foregroundStyle(.secondary).accessibilityIdentifier("task.output.unavailable")
                if !self.snapshot.error.isEmpty { Text(self.snapshot.error).textSelection(.enabled) }
            } else {
                if self.groups.count > 12 {
                    Button(text(self.showAll ? "task.output.less" : "task.output.more")) { self.source = .current; self.showAll.toggle() }.buttonStyle(.plain).foregroundStyle(.indigo)
                }
                VStack(alignment: .leading, spacing: 4) {
                    MimicCollapse(expanded: self.showAll, source: self.source) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(self.groups.dropLast(12))) { self.group($0) }
                        }
                    }
                    ForEach(self.visible) { self.group($0) }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("task.error.output")
    }

    @ViewBuilder
    private func group(_ group: DiagnosticLineGroup) -> some View {
        if group.canFold {
            MimicDisclosure(isExpanded: Binding(get: { self.unfolded.contains(group.id) }, set: { value in
                if value { self.unfolded.insert(group.id) } else { self.unfolded.remove(group.id) }
            })) {
                self.line(Array(repeating: group.text, count: group.count).joined(separator: "\n"))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    self.line(group.text)
                    Text(String(format: text("task.output.repeats.format"), group.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("task.output.repetition")
        } else { self.line(Array(repeating: group.text, count: group.count).joined(separator: "\n")) }
    }


    private func line(_ value: String) -> some View {
        Text(value.isEmpty ? " " : value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
