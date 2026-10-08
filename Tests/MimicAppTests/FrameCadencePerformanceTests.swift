//
//  FrameCadencePerformanceTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 08.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

private struct FrameCadenceGit: GitBranchService {
    func inspect(_ project: ProjectContext) async throws -> GitCheckoutState { .init(project: project, summary: GitSummary(porcelain: ""), hasOperation: false) }
    func branches(_ project: ProjectContext) async throws -> [LocalBranch] { [] }
    func switchBranch(_ name: String, project: ProjectContext) async throws -> GitCheckoutState { throw BranchError.missing }
}

/// Opt-in native benchmark: 87 devices, duplicate names and five-second Codex/catalogue heartbeats.
/// No AX reads, credentials, live simulators or subprocesses occur during the measurement window.
@Suite(.serialized) @MainActor struct FrameCadencePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_CADENCE_OUTPUT"] != nil))
    func retainedPanelWithHeartbeats() async throws {
        try await runFrameDiagnosticsApplication { try await measure() }
    }

    private func measure() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = try #require(environment["MIMIC_CADENCE_OUTPUT"])
        let seconds = Double(environment["MIMIC_CADENCE_SECONDS"] ?? "90") ?? 90
        let suite = "FrameCadence-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let project = ProjectContext(path: directory.path, branch: "fixture", commit: "fixture", developerDirectory: "/fixture/Developer")
        let devices = (0..<87).map { index in
            SimulatorDevice(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, name: "iPhone \(index / 3)", runtime: "iOS 27.0", state: index < 3 ? "Booted" : "Shutdown")
        }
        let services = SimulatorPanelServices(catalog: { _ in .init(devices: devices, developer: "/fixture/Developer") }, inspect: { $0 }, open: { _, _ in })
        let model = TaskCoordinator(directory: directory, simulatorServices: services, branchService: FrameCadenceGit(), defaults: defaults)
        model.aiUsage.stop()
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        model.projects = [project]; model.selectedProjectPath = project.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: directory)
        model.appearance.select(.tileGrid)
        model.installSimulatorPreview(devices, developer: "/fixture/Developer")
        model.frameDiagnostics.enabled = true
        model.panelVisibilityChanged(true)
        if environment["MIMIC_CADENCE_SCENE"] == "settings" { model.openSettings(group: .appearance, source: .keyboard) }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 560, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.title = "Mimic frame cadence (fixture)"
        let host = NSHostingView(rootView: MimicPanel(model: model).frame(width: 560, height: 620))
        window.contentView = host; window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .seconds(2))
        let view = try #require(findDiagnostics(in: host))
        view.updateSampling(); _ = try #require(view.displayLink)
        view.resetMeasurements()
        let start = ProcessInfo.processInfo.systemUptime
        var heartbeat = 0
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if Int(elapsed / 5) > heartbeat {
                heartbeat = Int(elapsed / 5)
                await model.refreshPanelContext(project.path)
                model.refreshSimulators()
                model.ciMonitor.objectWillChange.send()
                if heartbeat.isMultiple(of: 2) { model.aiUsage.objectWillChange.send() }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let result: [String: BridgeValue] = ["cadence": try BridgeValue.encode(view.report), "mainThreadCPUSeconds": .number(view.mainThreadCPUSeconds), "heartbeats": .number(Double(heartbeat))]
        try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: output), options: .atomic)
        #expect(view.report.intervalCount > 0)
    }

    private func findDiagnostics(in view: NSView) -> FrameDiagnosticsNativeView? {
        (view as? FrameDiagnosticsNativeView) ?? view.subviews.lazy.compactMap { findDiagnostics(in: $0) }.first
    }
}
