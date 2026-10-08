//
//  LiquidGlassPreview.swift
//  Mimic
//
//  Created by Василий Маслов on 03.10.2026.
#if DEBUG
import SwiftUI
import MimicCore

/// A separate DEBUG bundle hosts the production panel with disposable data.
/// These controls never appear in the release application or touch system preferences.
struct LiquidGlassPreviewPanel: View {
    @ObservedObject var model: TaskCoordinator
    @State private var dataset = "demo"
    @State private var mode = "normal"
    @State private var dark = false
    @State private var speed = 1.0

    var body: some View {
        self.previewContents
            .onChange(of: self.speed) { _, value in self.changeSpeed(value) }
            .onChange(of: self.dark) { _, value in self.model.motionSettings.darkOverride = value }
            .onChange(of: self.mode) { _, value in self.changeMode(value) }
            .onChange(of: self.dataset) { _, _ in self.installData() }
            .onAppear { self.installData() }
    }

    private var previewContents: some View {
        VStack(spacing: 0) {
            self.appearanceControls
            self.motionControls
            self.previewPanel
        }.frame(width: MimicMetrics.panelWidth)
            .preferredColorScheme(self.dark ? .dark : .light)
            .environment(\.colorScheme, self.dark ? .dark : .light)
    }

    private var previewPanel: some View {
        MimicPanel(model: self.model).environment(self.previewAppearance)
    }
    private var previewAppearance: MimicAppearancePreview {
        MimicAppearancePreview(reduceTransparency: self.mode == "opaque" || self.mode == "combined", reduceMotion: self.mode == "motion" || self.mode == "combined", increasedContrast: self.mode == "contrast" || self.mode == "combined")
    }
    private func changeSpeed(_ value: Double) { self.model.motionSettings.speed = value }
    private func changeMode(_ value: String) {
        self.model.motionSettings.reduceMotionOverride = value == "motion" || value == "combined"
        self.model.motionSettings.reduceTransparencyOverride = value == "opaque" || value == "combined"
        self.model.motionSettings.contrastOverride = value == "contrast" || value == "combined"
    }

    private var appearanceControls: some View {
        HStack {
                Picker(text("preview.data"), selection: self.$dataset) {
                    ForEach(["demo", "worst", "empty", "one", "large"], id: \.self) { Text(text("preview." + $0)).tag($0) }
                }
                Picker(text("preview.appearance"), selection: self.$mode) {
                    ForEach(["normal", "opaque", "contrast", "motion", "combined"], id: \.self) { Text(text("preview." + $0)).tag($0) }
                }
                Toggle(text("preview.dark"), isOn: self.$dark).toggleStyle(.button)
            }.pickerStyle(.menu).controlSize(.small).padding(8)
    }

    private var motionControls: some View {
        HStack(spacing: 8) {
                Picker(text("preview.motion.speed"), selection: self.$speed) {
                    Text("×1").tag(1.0); Text("×5").tag(5.0)
                }.frame(width: 80)
                Menu(text("preview.motion.scenarios")) {
                    ForEach(["disclosure", "status", "device", "result"], id: \.self) { scenario in
                        Button(text("preview.motion." + scenario)) { self.model.installMotionPreview(scenario) }
                    }
                }
            }.controlSize(.small).padding(.horizontal, 8).padding(.bottom, 8)
    }

    private func installData() {
        self.model.installInlinePanelPreview()
        self.model.readiness[.bootstrap] = []
        if self.dataset == "empty" {
            self.model.projects = []; self.model.selectedProjectPath = ""
            self.model.records = []; self.model.simulators = []
        } else if self.dataset == "worst" {
            let project = ProjectContext(path: "/private/tmp/Mimic-fixture/MobilePlatformInfrastructureCheckout", branch: "feature/infrastructure/dependency-registry-bootstrap-diagnostics", commit: "fixture")
            self.model.projects = [project]; self.model.selectedProjectPath = project.path
            self.model.installSimulatorPreview((0..<9).map { index in
                SimulatorDevice(id: UUID(), name: index < 2 ? "Mimic Apple Probe" : index == 2 ? "iPad Pro 13-inch Mobile Platform Infrastructure Development" : "Apple TV 4K (3rd generation) (at 1080p)",
                                runtime: index > 2 ? "tvOS 27.0" : "iOS 27.0", state: index < 4 ? "Booted" : "Shutdown")
            })
            if let index = self.model.records.firstIndex(where: { $0.status == .failed }) {
                self.model.records[index].error = "/Fastlane/fastfiles/project_dependency_registry_configuration:223: invalid multibyte char (US-ASCII)"
            }
        } else if self.dataset == "one" {
            self.model.records = Array(self.model.records.prefix(1))
        } else if self.dataset == "large", let project = self.model.project {
            self.model.records = (0..<100).map { _ in
                var record = TaskRecord(action: .format, project: project)
                record.status = .succeeded; record.exitCode = 0
                return record
            }
            self.model.simulators = (0..<1000).map { index in SimulatorDevice(id: UUID(), name: "iPad Development \(index + 1)", runtime: "iOS 26.5", state: "Shutdown") }
        }
        self.model.returnHome(); self.model.expandedSection = nil
        self.model.selectedTaskID = self.model.records.first?.id
    }
}
#endif
