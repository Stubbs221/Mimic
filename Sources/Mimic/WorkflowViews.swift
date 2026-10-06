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
            if self.action == .generation { GeneratorForm(model: self.model) }
            else {
                MimicDisclosure(text("action.result")) { Text(text("action." + self.action.rawValue + ".effects")).font(MimicMetrics.secondary).foregroundStyle(.secondary) }.font(MimicMetrics.secondary)
                ReadinessView(model: self.model, action: self.action)
                CommandDisclosure(model: self.model, action: self.action)
                Button(self.model.busy ? text("run.enqueue") : text("run")) { self.model.request(self.action) }
                    .buttonStyle(MimicButtonStyle(primary: true)).disabled(self.model.switchingBranch || self.model.project == nil || self.model.readiness[self.action] != [])
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
                        Label(text("ready.no"), systemImage: "exclamationmark.circle").font(MimicMetrics.body.weight(.medium)).foregroundStyle(.orange)
                        Text(missing.joined(separator: ", ")).font(MimicMetrics.secondary).textSelection(.enabled)
                        Button(text("ready.open.settings")) { self.model.openSettings(group: .environment) }
                    }
                }
            } else { HStack { ProgressView().controlSize(.small); Text(text("diagnostic.loading")).font(MimicMetrics.secondary) } }
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
            }.font(MimicMetrics.secondary)
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
                        ForEach(GeneratorKind.allCases, id: \.self) { Text(text($0.titleKey)).tag($0) }
                    }
                    TextField(text("generator.name.placeholder"), text: self.$model.generatorName).textFieldStyle(.roundedBorder).accessibilityLabel(text("generator.name"))
                    if !self.model.generatorName.isEmpty, !GenerationRequest.validName(self.model.generatorName) { Text(text("generator.name.invalid")).font(MimicMetrics.secondary).foregroundStyle(.orange) }
                }.disabled(self.model.switchingBranch)
            }
            if !self.model.generationError.isEmpty { Text(self.model.generationError).font(MimicMetrics.secondary).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Button(text("generator.preview")) { self.model.previewGeneration() }.buttonStyle(MimicButtonStyle())
                .disabled(self.model.switchingBranch || !GenerationRequest.validName(self.model.generatorName) || self.model.planningGeneration || self.model.project == nil || self.model.readiness[.generation] != [])
            if self.model.planningGeneration { HStack { ProgressView().controlSize(.small); Text(text("generator.planning")).font(MimicMetrics.secondary) } }
            if let plan = model.generationPlan {
                Surface {
                    VStack(alignment: .leading, spacing: MimicMetrics.medium) {
                        Text("\(plan.files.count) " + text("generator.files")).font(MimicMetrics.heading)
                        ForEach(plan.files) { file in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: file.exists ? "exclamationmark.circle" : "doc.badge.plus").foregroundStyle(file.exists ? Color.orange : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    if file.exists { Text(text("generator.file.exists")).font(MimicMetrics.secondary).foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                }
                Button(self.model.busy ? text("run.enqueue") : text("generator.create")) { self.model.generateFromPreview() }
                    .buttonStyle(MimicButtonStyle(primary: true)).disabled(self.model.switchingBranch || !plan.canGenerate)
                Text(text("generator.safety")).font(MimicMetrics.secondary).foregroundStyle(.secondary)
            } else { ReadinessView(model: self.model, action: .generation) }
        }
    }
}

struct SimulatorCatalogContent: View {
    @ObservedObject
    var model: TaskCoordinator
    private var devices: [SimulatorDevice] { self.model.orderedSimulators.filter { self.model.simulatorSearch.isEmpty || ($0.name + $0.runtime).localizedCaseInsensitiveContains(self.model.simulatorSearch) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Spacer()
                Button { self.model.refreshSimulators() } label: { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).disabled(self.model.loadingSimulators).accessibilityLabel(text("refresh"))
            }
            TextField(text("simulators.search"), text: self.$model.simulatorSearch).textFieldStyle(.roundedBorder)
            if self.model.loadingSimulators { HStack { ProgressView().controlSize(.small); Text(text("simulators.loading")).font(MimicMetrics.secondary) } }
            if !self.model.simulatorError.isEmpty {
                Text(self.model.simulatorError).font(MimicMetrics.secondary).foregroundStyle(.orange)
                Button(text("ready.open.settings")) { self.model.openSettings(group: .environment) }
            } else if self.devices.isEmpty, !self.model.loadingSimulators {
                EmptyState(symbol: "iphone", title: text("simulators.empty"), message: text("simulators.empty.help"))
            }
            LazyVStack(alignment: .leading, spacing: MimicMetrics.small) {
                ForEach(self.devices) { device in SimulatorRow(model: self.model, device: device) }
            }
        }
    }
}
