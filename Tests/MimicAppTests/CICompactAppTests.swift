// Created by Василий Маслов on 06.10.2026.
import AppKit
import SwiftUI
import Testing
@testable import MimicCore
@testable import Mimic

@MainActor private final class CompactAppCredentials: CICredentialStore {
    func token(for _: UUID, interaction _: CICredentialInteraction) throws -> String { "fixture" }
    func save(_: String, for _: UUID) throws { }
    func remove(_: UUID) throws { }
}

private actor CompactAppClient: GitLabService {
    let twoRuns: Bool
    init(twoRuns: Bool = false) { self.twoRuns = twoRuns }
    func project(baseURL _: URL, path _: String, token _: String) async throws -> CIProject { throw CIError.notFound }
    func currentUser(connection _: GitLabConnection, token _: String) async throws -> CIUser { CIUser(id: 1, username: "me", name: "Fixture") }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] { [] }
    func pipelines(connection: GitLabConnection, branch _: String, token: String) async throws -> [CIPipeline] { var result = [try await self.pipeline(connection: connection, id: connection.projectID, token: token)]; if self.twoRuns { result.append(try await self.pipeline(connection: connection, id: connection.projectID + 100, token: token)) }; return result }
    func pipelinePage(connection: GitLabConnection, username _: String?, page _: Int, perPage _: Int, token: String) async throws -> CIPipelinePage {
        CIPipelinePage(pipelines: try await self.pipelines(connection: connection, branch: "", token: token))
    }
    func pipeline(connection: GitLabConnection, id: Int, token _: String) async throws -> CIPipeline {
        let date = Date().addingTimeInterval(-120).ISO8601Format()
        let body: [String: Any] = ["id": id, "project_id": connection.projectID, "status": "running", "sha": "fixture", "ref": "feature/me/" + String(repeating: "long-branch-😀", count: 20),
            "web_url": connection.baseURL.appendingPathComponent("pipelines/\(id)").absoluteString, "created_at": date, "started_at": date, "duration": 120]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CIPipeline.self, from: JSONSerialization.data(withJSONObject: body))
    }
    func details(connection: GitLabConnection, pipelineID _: Int, token _: String) async throws -> CIPipelineDetails {
        CIPipelineDetails(jobs: [CIJob(id: 1, name: "ui-tests-" + String(repeating: "оченьдлиннаяджоба", count: 20), stage: "test", status: "running", webURL: connection.baseURL, allowFailure: false),
            CIJob(id: 2, name: "complete", stage: "test", status: "success", webURL: connection.baseURL, allowFailure: false)], bridges: [])
    }
    func commit(connection _: GitLabConnection, sha: String, token _: String) async throws -> CICommit { CICommit(id: sha, title: "Fixture") }
}

@MainActor private final class CompactAppFixture {
    let defaults: UserDefaults
    let suite = "CompactApp-" + UUID().uuidString
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompactApp-" + UUID().uuidString)
    let model: TaskCoordinator
    let a: ProjectContext
    let b: ProjectContext
    let first: GitLabConnection
    let second: GitLabConnection
    init(twoRuns: Bool = false) throws {
        self.defaults = try #require(UserDefaults(suiteName: self.suite))
        self.a = ProjectContext(path: self.directory.appendingPathComponent("a").path, branch: "local-a")
        self.b = ProjectContext(path: self.directory.appendingPathComponent("b").path, branch: "local-b")
        self.first = GitLabConnection(baseURL: URL(string: "https://ci.example.invalid")!, projectID: 11, projectPath: "team/a")
        self.second = GitLabConnection(baseURL: URL(string: "https://ci.example.invalid")!, projectID: 12, projectPath: "team/b")
        let store = DefaultsCIConfigurationStore(defaults: self.defaults)
        var configuration = CIConfiguration(); configuration.connections = [self.first, self.second]
        configuration.checkouts = [self.a.path: self.first.id, self.b.path: self.second.id]; store.save(configuration)
        let client = CompactAppClient(twoRuns: twoRuns), settings = CISettingsModel(credentials: CompactAppCredentials(), store: store, client: client)
        self.model = TaskCoordinator(directory: self.directory, defaults: self.defaults, ciClient: client, ciSettings: settings)
        self.model.projects = [self.a, self.b]; self.model.selectedProjectPath = self.a.path
        settings.selectCheckout(self.a.path)
        self.model.ciMonitor.setDesktop(CIContext(project: self.a, connection: self.first))
        self.model.motionSettings.reduceMotionOverride = true
    }
    func stop() {
        self.model.ciMonitor.stop(); self.model.profileRemote.stop(); self.model.remoteTests.stop()
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.directory)
    }
}

@Suite(.serialized) @MainActor struct CICompactAppTests {
    private func wait(_ label: String = "fixture state", _ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "Timed out: \(label)")
    }

    @Test func twoSummaryBridgeAndPrivateDetailsKeepChatAndNativeSelectionIndependent() async throws {
        let fixture = try CompactAppFixture(twoRuns: true); defer { fixture.stop() }
        let model = fixture.model, integration = MimicIntegration(model: fixture.model, defaults: fixture.defaults)
        try integration.workspaceStore.save(PanelWorkspace(checkout: fixture.a.path), for: "a")
        try integration.workspaceStore.save(PanelWorkspace(checkout: fixture.b.path), for: "b")
        _ = try await integration.handle(.init(method: "get_state", threadID: "a"))
        _ = try await integration.handle(.init(method: "get_state", threadID: "b"))
        try await self.wait { model.ci.compactSummaries.count == 2 && model.ci.compactSummaries.allSatisfy { $0.completed == 1 } }
        let reply = try await integration.handle(.init(method: "get_state", threadID: "a"))
        #expect(reply["ciSummaries"].array?.count == 2 && reply["ciSummary"] == reply["ciSummaries"].array?.first)
        let selected = try #require(model.ci.compactSummaries.last)
        let request = MimicBridgeRequest(method: "panel_get_ci_details", parameters: ["identity": .string(selected.identity), "refresh": .bool(false)], threadID: "a")
        let detail = try await integration.handle(request)
        #expect(detail["summary"]["pipelineID"].integer == selected.pipelineID)
        #expect(detail["summary"]["checkout"].string == fixture.a.path)
        #expect(detail["jobs"].array?.count == 2 && model.ci.selectedPipelineID == nil && model.ciInspection == nil)
        do {
            _ = try await integration.handle(.init(method: "panel_get_ci_details", parameters: request.parameters, threadID: "b"))
            Issue.record("Another checkout's CI scope was accepted")
        } catch { }
        #expect(model.project == fixture.a && model.ci.selectedPipelineID == nil)
        model.ci.credentialsChanged()
        do {
            _ = try await integration.handle(request)
            Issue.record("Old credential scope was accepted before account discovery")
        } catch { }
    }

    @Test func bridgeSummaryIsCheckoutScopedAndNativeNavigationDoesNotSwitchAdmission() async throws {
        let fixture = try CompactAppFixture(); defer { fixture.stop() }
        let model = fixture.model, integration = MimicIntegration(model: model, defaults: fixture.defaults)
        try integration.workspaceStore.save(PanelWorkspace(checkout: fixture.a.path), for: "a")
        try integration.workspaceStore.save(PanelWorkspace(checkout: fixture.b.path), for: "b")
        _ = try await integration.handle(.init(method: "get_state", threadID: "a"))
        _ = try await integration.handle(.init(method: "get_state", threadID: "b"))
        try await self.wait { model.ci.compactSummary?.completed == 1 && model.ciMonitor.overlay != nil }
        var stateB = try await integration.handle(.init(method: "get_state", threadID: "b"))
        for _ in 0..<100 where stateB["ciSummary"] == .null {
            try await Task.sleep(for: .milliseconds(5)); stateB = try await integration.handle(.init(method: "get_state", threadID: "b"))
        }
        let stateA = try await integration.handle(.init(method: "get_state", threadID: "a"))
        #expect(stateA["ciSummary"]["pipelineID"].integer == 11 && stateB["ciSummary"]["pipelineID"].integer == 12)
        #expect(stateA["ciSummary"]["checkout"].string == fixture.a.path && stateB["ciSummary"]["checkout"].string == fixture.b.path)
        #expect(stateA["ciSummary"]["startedAt"].string?.contains("T") == true)
        let unbound = try await integration.handle(.init(method: "get_state", threadID: "unbound"))
        #expect(unbound["ciSummary"] == .null)
        let summary = try #require(model.ciMonitor.heartbeat(threadID: "b", context: CIContext(project: fixture.b, connection: fixture.second)))
        var opened = false; model.showPanel = { opened = true }
        model.showCI(summary)
        #expect(opened && model.panelLayout.expanded == .ci && model.expandedSection == .ci)
        #expect(model.ciPresentedState.context?.connection == fixture.second && model.ciPresentedState.selectedPipelineID == 12)
        #expect(model.project == fixture.a && model.ci.context?.connection == fixture.first)
        model.clearCIInspection(); #expect(model.ciInspection == nil && model.ciPresentedState === model.ci)
    }

    @Test func sharedWindowKeepsHostAndCIWhenBootstrapCompletes() async throws {
        let fixture = try CompactAppFixture(); defer { fixture.stop() }
        let model = fixture.model
        try await self.wait { model.ciMonitor.overlay?.completed == 1 }
        let panel = BootstrapActivityPanel(model: model, defaults: fixture.defaults, completionDelay: .milliseconds(40))
        defer { model.stateChanged = nil; panel.stop(); panel.window.orderOut(nil) }
        // WindowServer may expose no screen in a sandboxed test process.
        panel.anchor = { NSRect(x: 100, y: 100, width: 800, height: 800) }
        model.stateChanged = { panel.update() }
        model.installBootstrapPreview(); panel.update()
        let host = try #require(panel.window.contentView)
        try await self.wait("combined height") { panel.window.contentView?.layoutSubtreeIfNeeded(); return panel.window.frame.height > 200 }
        let combinedHeight = panel.window.frame.height
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/Mimic-ci-combined.png"))
        }
        let index = try #require(model.records.indices.last)
        model.records[index].status = .succeeded; model.records[index].finishedAt = .now; panel.update()
        try await self.wait("Bootstrap hidden and window shrunk") { panel.isCompletionHidden && panel.window.frame.height < combinedHeight }
        #expect(panel.window.contentView === host && panel.window.isVisible && model.ciMonitor.overlay != nil)
        // The single-section window must match intrinsic content, including its last job row.
        let ciOnly = NSHostingView(rootView: CIActivitySection(summary: try #require(model.ciMonitor.overlay), open: {}, hide: {}))
        let ciHeight = ciOnly.fittingSize.height
        try await self.wait("CI intrinsic height") { abs(panel.window.frame.height - ciHeight) <= 1 }
        host.layoutSubtreeIfNeeded()
        let ciBitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: ciBitmap)
        try #require(ciBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/Mimic-ci-only.png"))
        // The viewport, rather than the scroll content, owns the bottom rounded corners.
        #expect((ciBitmap.colorAt(x: 0, y: ciBitmap.pixelsHigh - 1)?.alphaComponent ?? 1) < 0.1)
        panel.window.setContentSize(NSSize(width: 320, height: 90))
        host.layoutSubtreeIfNeeded()
        let limited = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: limited)
        #expect((limited.colorAt(x: 0, y: limited.pixelsHigh - 1)?.alphaComponent ?? 1) < 0.1)
        try #require(limited.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/Mimic-ci-limited.png"))
        model.ciMonitor.hideCI(); panel.update()
        try await self.wait("both sections hidden") { !panel.window.isVisible }
        #expect(model.ci.compactSummary?.status == "running")
        panel.window.setFrame(BootstrapActivityPanel.clamped(NSRect(x: -100, y: -100, width: 320, height: 160), to: NSRect(x: 0, y: 0, width: 800, height: 600)), display: false)
        #expect(panel.window.frame.minX == 0 && panel.window.frame.minY == 0)
    }

    @Test func closingCIKeepsBootstrapVisibleAndDoesNotCancelEitherOperation() async throws {
        let fixture = try CompactAppFixture(); defer { fixture.stop() }
        let model = fixture.model
        try await self.wait { model.ciMonitor.overlay?.completed == 1 }
        let panel = BootstrapActivityPanel(model: model, defaults: fixture.defaults)
        panel.anchor = { NSRect(x: 100, y: 100, width: 800, height: 800) }
        model.stateChanged = { panel.update() }
        defer { model.stateChanged = nil; panel.stop(); panel.window.orderOut(nil) }
        model.installBootstrapPreview(); panel.update()
        try await self.wait("combined height") { panel.window.contentView?.layoutSubtreeIfNeeded(); return panel.window.frame.height > 200 }
        let height = panel.window.frame.height, host = panel.window.contentView
        model.ciMonitor.hideCI(); panel.update()
        try await self.wait("CI hidden, Bootstrap remains") { panel.window.frame.height < height }
        #expect(panel.window.isVisible && panel.window.contentView === host)
        #expect(model.records.last?.status == .queued && model.ci.compactSummary?.status == "running")
    }

    @Test func nativeCompactGridSnapshotsAndOverlayFitLongValues() async throws {
        let fixture = try CompactAppFixture(twoRuns: true); defer { fixture.stop() }
        let model = fixture.model
        let style = PanelAppearance(rawValue: ProcessInfo.processInfo.environment["MIMIC_PANEL_APPEARANCE"] ?? "legacy") ?? .legacy
        let width: CGFloat = style == .tileGrid ? 528 : 488
        try await self.wait { model.ci.compactSummaries.count == 2 && model.ci.compactSummaries.allSatisfy { $0.completed == 1 } }
        let summary = try #require(model.ci.compactSummary)
        let compact = NSHostingView(rootView: CICompactBody(summary: summary).frame(width: 214))
        #expect(compact.fittingSize.height <= 112)
        let output = URL(fileURLWithPath: "/private/tmp/Mimic-ci-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] { for contrast in [false, true] {
            let view = PanelGrid(model: model, layout: model.panelLayout)
                .environment(\.colorScheme, dark ? .dark : .light).environment(MimicAppearancePreview(increasedContrast: contrast))
                .environment(\.mimicMotionSettings, model.motionSettings).frame(width: width).environment(\.mimicPanelAppearance, style)
            let host = NSHostingView(rootView: view), size = host.fittingSize
            #expect(abs(size.width - width) < 1)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host; host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("native-grid-\(dark ? "dark" : "light")-\(contrast ? "contrast" : "normal").png"))
            window.contentView = nil; window.close()
            model.panelLayout.begin(); model.panelLayout.edit { try $0.resize(.ci, to: .full) }; model.panelLayout.finish()
            let wide = NSHostingView(rootView: PanelGrid(model: model, layout: model.panelLayout)
                .environment(\.colorScheme, dark ? .dark : .light).environment(MimicAppearancePreview(increasedContrast: contrast))
                .environment(\.mimicMotionSettings, model.motionSettings).frame(width: width).environment(\.mimicPanelAppearance, style))
            let wideSize = wide.fittingSize
            let wideWindow = NSWindow(contentRect: NSRect(origin: .zero, size: wideSize), styleMask: [.borderless], backing: .buffered, defer: false)
            wideWindow.isReleasedWhenClosed = false; wideWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            wideWindow.contentView = wide; wide.frame = NSRect(origin: .zero, size: wideSize); wide.layoutSubtreeIfNeeded()
            let wideBitmap = try #require(wide.bitmapImageRepForCachingDisplay(in: wide.bounds)); wide.cacheDisplay(in: wide.bounds, to: wideBitmap)
            try #require(wideBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("native-wide-\(dark ? "dark" : "light")-\(contrast ? "contrast" : "normal").png"))
            wideWindow.contentView = nil; wideWindow.close()
            model.panelLayout.begin(); model.panelLayout.edit { try $0.resize(.ci, to: .mini) }; model.panelLayout.finish()
        } }
        let section = NSHostingView(rootView: CIActivitySection(summary: summary, open: {}, hide: {}))
        #expect(section.fittingSize.width == 320 && section.fittingSize.height < 260)
    }

    @Test func expandedRowUsesContentHeightWithoutHiddenPeersOrEmptySlots() {
        let row = PanelLayoutRow(slots: [.utils, .builds])
        let cells = [PanelGridCell(row: row.id, slot: 0, block: .utils), PanelGridCell(row: row.id, slot: 1, block: .builds)]
        let collapsed = NSHostingView(rootView: PanelGridLayout(rows: [row], cells: cells, expanded: nil) {
            Text("Fixture").frame(height: MimicMetrics.collapsedCardHeight)
            Text("Fixture").frame(height: MimicMetrics.collapsedCardHeight)
        }.frame(width: 488))
        #expect(abs(collapsed.fittingSize.height - 160) < 1)
        let expanded = NSHostingView(rootView: PanelGridLayout(rows: [row], cells: cells, expanded: .utils) {
            Text("Fixture").frame(height: 54)
            Text("Hidden peer").frame(height: MimicMetrics.collapsedCardHeight)
        }.frame(width: 488))
        #expect(abs(expanded.fittingSize.height - 54) < 1)
    }
}
