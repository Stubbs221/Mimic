//
//  WorkflowViews.swift
//  Mimic
//
//  Created by Василий Маслов on 01.10.2026.
import SwiftUI
import MimicCore

struct ToolContent: View {
    @ObservedObject
    var model: TaskCoordinator
    let action: MimicAction
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tool = ProjectTool(rawValue: action.rawValue) {
                Text(text(tool.descriptionKey)).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let project = model.project {
                    Label(URL(fileURLWithPath: project.path).lastPathComponent + " · " + project.branch, systemImage: "folder")
                        .mimicFont(.caption).lineLimit(2).help(project.path)
                }
                if action == .generation { GeneratorForm(model: model) }
                else {
                    Text(text(tool.effectsKey(execution: try? model.profileExecution(action)))).mimicFont(.caption).fixedSize(horizontal: false, vertical: true)
                    ReadinessView(model: model, action: action)
                    CommandDisclosure(model: model, action: action)
                    Button(model.busy ? text("run.enqueue") : text("run")) { model.launchTool(tool) }
                        .buttonStyle(MimicButtonStyle(primary: true)).disabled(!model.canLaunchTool(tool))
                }
                ToolTaskView(model: model, tool: tool)
            }
        }
    }
}

struct ReadinessView: View {
    @ObservedObject
    var model: TaskCoordinator
    let action: MimicAction
    var body: some View {
        Group {
            if let missing = model.readiness[action] {
                if missing.isEmpty {
                    EmptyView()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(text("ready.no"), systemImage: "exclamationmark.circle").mimicFont(.body, weight: .medium).foregroundStyle(.orange)
                        Text(missing.joined(separator: ", ")).mimicFont(.caption).textSelection(.enabled)
                        Button(text("ready.open.settings")) { self.model.openSettings(group: .environment) }
                    }
                }
            } else { HStack { ProgressView().controlSize(.small); Text(text("diagnostic.loading")).mimicFont(.caption) } }
        }
    }
}

struct CommandDisclosure: View {
    @ObservedObject
    var model: TaskCoordinator
    let action: MimicAction
    var body: some View {
        if let project = self.action == .bootstrap ? self.model.bootstrapDisplayedProject : self.model.project, let execution = try? self.model.profileExecution(action, options: self.action == .bootstrap ? self.model.bootstrapDisplayedOptions : self.model.bootstrapOptions), let command = try? execution.commands(project: project).first {
            MimicDisclosure(text("command.details")) {
                Text(command.display).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 4)
            }.mimicFont(.caption)
        }
    }
}

struct GeneratorForm: View {
    @ObservedObject
    var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.large) {
            Surface {
                VStack(alignment: .leading, spacing: MimicMetrics.medium) {
                    Picker(text("generator.type"), selection: self.$model.generatorKind) {
                        ForEach(GeneratorKind.allCases, id: \.self) { Text(text("tools.generator." + $0.rawValue)).tag($0) }
                    }.pickerStyle(.segmented)
                    Text(text(self.model.generatorKind.titleKey + ".description")).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(text("generator.name")).mimicFont(.caption, weight: .medium)
                    TextField(text("generator.name.placeholder"), text: self.$model.generatorName).textFieldStyle(.roundedBorder).accessibilityLabel(text("generator.name"))
                    Text(text("generator.name.hint")).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !self.model.generatorName.isEmpty, !GenerationRequest.validName(self.model.generatorName) { Text(text("generator.name.invalid")).mimicFont(.caption).foregroundStyle(.orange) }
                }.disabled(self.model.switchingBranch)
            }
            ReadinessView(model: self.model, action: .generation)
            CommandDisclosure(model: self.model, action: .generation)
            if !self.model.generationError.isEmpty { Text(self.model.generationError).mimicFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Button(text("generator.preview")) { self.model.previewGeneration() }.buttonStyle(MimicButtonStyle())
                .disabled(!self.model.canLaunchTool(.generation) || !GenerationRequest.validName(self.model.generatorName) || self.model.planningGeneration)
            if self.model.planningGeneration { HStack { ProgressView().controlSize(.small); Text(text("generator.planning")).mimicFont(.caption) } }
            if let plan = model.generationPlan {
                Surface {
                    VStack(alignment: .leading, spacing: MimicMetrics.medium) {
                        Text("\(plan.files.count) " + text("generator.files")).mimicFont(.heading)
                        ForEach(plan.files) { file in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: file.exists ? "exclamationmark.circle" : "doc.badge.plus").foregroundStyle(file.exists ? Color.orange : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    if file.exists { Text(text("generator.file.exists")).mimicFont(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                }
                Button(self.model.busy ? text("run.enqueue") : text("generator.create")) { self.model.generateFromPreview() }
                    .buttonStyle(MimicButtonStyle(primary: true)).disabled(!self.model.canLaunchTool(.generation) || !plan.canGenerate)
                Text(text("generator.safety")).mimicFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
