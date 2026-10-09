//
//  FrameUpdatePerformanceTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 09.10.2026.
import AppKit
import SwiftUI
import Testing
@testable import MimicCore
@testable import Mimic

@MainActor private final class FrameUpdateClock {
    var date = Date(timeIntervalSince1970: 1_791_545_400)
}

@MainActor private final class FrameUpdateUsageAdapter: AIUsageFetching {
    let provider: AIProvider = .codex
    let snapshot: AIUsageSnapshot
    init(date: Date) {
        snapshot = AIUsageSnapshot(provider: .codex, accountID: "fixture", plan: "fixture", windows: [
            AIUsageWindow(period: .weekly, usedPercent: 87, resetsAt: date.addingTimeInterval(86_400))
        ], fetchedAt: date)
    }
    func revision() -> String { "fixture" }
    func fetch(manual: Bool) async throws -> AIUsageFetchResult { .init(snapshot: snapshot, revision: revision()) }
}

private struct FrameUpdateGit: GitBranchService {
    func inspect(_ project: ProjectContext) async throws -> GitCheckoutState { .init(project: project, summary: .init(porcelain: ""), hasOperation: false) }
    func branches(_ project: ProjectContext) async throws -> [LocalBranch] { [] }
    func switchBranch(_ name: String, project: ProjectContext) async throws -> GitCheckoutState { throw BranchError.missing }
}

@MainActor private final class FrameUpdateCredentials: CICredentialStore {
    func token(for _: UUID, interaction _: CICredentialInteraction) throws -> String { "fixture" }
    func save(_: String, for _: UUID) throws { }
    func remove(_: UUID) throws { }
}

private actor FrameUpdateClient: GitLabService {
    let values: [CIPipeline]
    init(date: Date) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        values = try (1...40).map { id in
            let body: [String: Any] = ["id": id, "project_id": 272, "status": "success", "sha": "fixture-\(id)",
                "ref": "feature/fixture/update", "web_url": "https://ci.example.invalid/pipelines/\(id)",
                "created_at": date.addingTimeInterval(Double(id)).ISO8601Format(),
                "started_at": date.ISO8601Format(), "finished_at": date.addingTimeInterval(120).ISO8601Format(), "duration": 120]
            return try decoder.decode(CIPipeline.self, from: JSONSerialization.data(withJSONObject: body))
        }
    }
    func currentUser(connection _: GitLabConnection, token _: String) async throws -> CIUser { .init(id: 1, username: "fixture", name: "Fixture") }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] { [] }
    func pipelines(connection _: GitLabConnection, branch _: String, token _: String) async throws -> [CIPipeline] { values }
    func pipelinePage(connection _: GitLabConnection, username _: String?, page _: Int, perPage _: Int, token _: String) async throws -> CIPipelinePage { .init(pipelines: values) }
    func pipeline(connection _: GitLabConnection, id: Int, token _: String) async throws -> CIPipeline { try #require(values.first { $0.id == id }) }
    func project(baseURL _: URL, path _: String, token _: String) async throws -> CIProject { throw CIError.notFound }
    func details(connection _: GitLabConnection, pipelineID _: Int, token _: String) async throws -> CIPipelineDetails { .init(jobs: [], bridges: []) }
    func commit(connection _: GitLabConnection, sha: String, token _: String) async throws -> CICommit { .init(id: sha, title: "Fixture") }
}

/// The same retained panel and fixed services exercise AI ticks and complete CI response bursts.
/// No live account, simulator, subprocess or accessibility query participates in the measurement.
@Suite(.serialized) @MainActor struct FrameUpdatePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_UPDATE_AUDIT_OUTPUT"] != nil))
    func retainedPanelWithAIAndCIBursts() async throws {
        try await runFrameDiagnosticsApplication { try await measure() }
    }

    private func measure() async throws {
        let env = ProcessInfo.processInfo.environment
        let output = try #require(env["MIMIC_UPDATE_AUDIT_OUTPUT"])
        let seconds = Double(env["MIMIC_UPDATE_AUDIT_SECONDS"] ?? "90") ?? 90
        let repetitions = Int(env["MIMIC_UPDATE_AUDIT_REPEATS"] ?? "3") ?? 3
        let scenes = (env["MIMIC_UPDATE_AUDIT_SCENES"] ?? "mini,full,settings").split(separator: ",").map(String.init)
        var results: [[String: BridgeValue]] = []
        for scene in scenes {
            for repetition in 1...repetitions {
                results.append(try await run(scene: scene, repetition: repetition, seconds: seconds))
                try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: output), options: .atomic)
                print("Completed frame fixture: \(scene) \(repetition)/\(repetitions)")
            }
        }
    }

    private func run(scene: String, repetition: Int, seconds: Double) async throws -> [String: BridgeValue] {
        let suite = "FrameUpdate-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let project = ProjectContext(path: root.path, branch: "fixture", commit: "fixture", developerDirectory: "/fixture/Developer")
        let clock = FrameUpdateClock(), adapter = FrameUpdateUsageAdapter(date: FrameUpdateClock().date)
        let points = (0..<31).map { AIUsageDailyPoint(date: clock.date.addingTimeInterval(Double($0 - 30) * 86_400), tokens: ($0 + 1) * 1_234_567) }
        let usage = AIUsageCoordinator(defaults: defaults, adapters: [adapter], scanUsage: { .init(activity: nil, histories: [.codex: points]) }, clock: { clock.date })
        await usage.tick()
        let client = try FrameUpdateClient(date: clock.date)
        let connection = GitLabConnection(baseURL: URL(string: "https://ci.example.invalid")!, projectID: 272, projectPath: "fixture/project")
        let store = DefaultsCIConfigurationStore(defaults: defaults)
        var config = CIConfiguration(); config.connections = [connection]; config.checkouts = [project.path: connection.id]; store.save(config)
        let settings = CISettingsModel(credentials: FrameUpdateCredentials(), store: store, client: client)
        let devices = (0..<87).map { SimulatorDevice(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))!, name: "iPhone \($0 / 3)", runtime: "iOS 27.0", state: $0 < 3 ? "Booted" : "Shutdown") }
        let services = SimulatorPanelServices(catalog: { _ in .init(devices: devices, developer: "/fixture/Developer") }, inspect: { $0 }, open: { _, _ in })
        let model = TaskCoordinator(directory: root, simulatorServices: services, branchService: FrameUpdateGit(), defaults: defaults, ciClient: client, ciSettings: settings, usageCoordinator: usage,
                                    inspectProject: { ($0, [], GitSummary(porcelain: "")) })
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.projects = [project]; model.selectedProjectPath = project.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: root); model.appearance.select(.tileGrid)
        model.installSimulatorPreview(devices, developer: "/fixture/Developer")
        model.ciMonitor.setDesktop(.init(project: project, connection: connection))
        model.motionSettings.reduceMotionOverride = true
        model.panelLayout.begin(); model.panelLayout.edit { try $0.resize(.ai, to: scene == "mini" ? .mini : .full); try $0.resize(.ci, to: scene == "mini" ? .mini : .full) }; model.panelLayout.finish()
        model.frameDiagnostics.enabled = true; model.panelVisibilityChanged(true)
        if scene == "settings" { model.openSettings(group: .application, source: .keyboard) }
        let window = NSPanel(contentRect: .init(x: 120, y: 120, width: 560, height: 620), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.title = "Mimic AI/CI frame fixture"
        let host = NSHostingView(rootView: MimicPanel(model: model).frame(width: 560, height: 620))
        window.contentView = host; window.orderFrontRegardless(); defer { window.close() }
        try await Task.sleep(for: .seconds(2))
        let view = try #require(findDiagnostics(in: host)); _ = try #require(view.displayLink)
        view.resetMeasurements()
        let start = ProcessInfo.processInfo.systemUptime
        var heartbeat = 0, aiTicks = 0, samplingOutages = 0
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            if view.displayLink == nil { samplingOutages += 1 }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if Int(elapsed / 5) > heartbeat {
                heartbeat = Int(elapsed / 5)
                await model.refreshPanelContext(project.path); model.refreshSimulators(); model.ci.refresh()
                if heartbeat.isMultiple(of: 2) { clock.date.addTimeInterval(10); await usage.tick(); aiTicks += 1 }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(view.displayLink != nil && view.report.intervalCount > 0)
        #expect(samplingOutages == 0 && view.report.elapsedSeconds >= seconds - 1, "The full measurement requires continuous window visibility")
        return ["scene": .string(scene), "repetition": .number(Double(repetition)), "cadence": try .encode(view.report),
                "mainThreadCPUSeconds": .number(view.mainThreadCPUSeconds), "heartbeats": .number(Double(heartbeat)), "aiTicks": .number(Double(aiTicks)), "samplingOutages": .number(Double(samplingOutages))]
    }

    private func findDiagnostics(in view: NSView) -> FrameDiagnosticsNativeView? {
        (view as? FrameDiagnosticsNativeView) ?? view.subviews.lazy.compactMap { findDiagnostics(in: $0) }.first
    }
}
