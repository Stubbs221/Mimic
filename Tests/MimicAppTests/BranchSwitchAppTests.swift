// Created by Василий Маслов on 07.10.2026.
import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

private actor BranchInspectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        await withCheckedContinuation { self.continuation = $0; self.started = true }
    }
    func release() { self.continuation?.resume(); self.continuation = nil }
}

private struct BranchSnapshotFixture: GitBranchService {
    var fails = false
    func inspect(_ project: ProjectContext) async throws -> GitCheckoutState {
        if self.fails { throw BranchError.command("fixture inspection failed") }
        return .init(project: project, summary: GitSummary(porcelain: ""), hasOperation: false)
    }
    func branches(_ project: ProjectContext) async throws -> [LocalBranch] { [.init(name: project.branch), .init(name: "target")] }
    func switchBranch(_ name: String, project: ProjectContext) async throws -> GitCheckoutState { throw BranchError.missing }
}

@Suite(.serialized) @MainActor struct BranchSwitchAppTests {
    private func services() -> SimulatorPanelServices {
        var services = SimulatorPanelServices()
        services.catalog = { _ in .init(devices: [], developer: "/fixture/Developer") }
        return services
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Branch fixture did not reach the expected state")
    }

    @Test func nativeSelectionStartsOneOperationAndUpdatesHeader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeBranch-" + UUID().uuidString)
        let suite = "NativeBranch-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        for args in [["init", "-b", "source"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"], ["branch", "target"]] {
            try #require(EnvironmentInspector.capture("/usr/bin/git", args, directory: checkout.path).0 == 0)
        }
        let project = try EnvironmentInspector.project(path: checkout.path)
        let model = TaskCoordinator(directory: root.appendingPathComponent("storage"), simulatorServices: self.services(), defaults: defaults, inspectProject: { ($0, [], GitSummary(porcelain: "")) })
        model.projects = [project]; model.selectedProjectPath = project.path
        model.expandedSection = .branches; model.branchSearch = "target"; model.loadBranches()
        try await self.waitUntil { !model.loadingBranches }
        #expect(model.canSwitchBranch)
        #expect(model.switchBranch("target"))
        #expect(model.expandedSection != .branches && model.switchingBranch)
        #expect(model.branchSwitch.operations.count == 1)
        #expect(!model.switchBranch("target"))
        #expect(model.branchSwitch.operations.count == 1)
        try await self.waitUntil { !model.branchSwitch.isExecuting }
        #expect(model.branchSwitch.operations.last?.phase == .succeeded)
        let completedAt = try #require(model.branchSwitch.operations.last?.completedAt)
        let restored = BranchSwitchCoordinator(defaults: defaults)
        #expect(restored.operations.last?.completedAt == completedAt)
        #expect(model.project?.branch == "target")
        #expect(EnvironmentInspector.capture("/usr/bin/git", ["branch", "--show-current"], directory: checkout.path).1 == "target")
        try await self.waitUntil { !model.checking }
    }

    @Test func rejectedSelectionRetainsPickerSearchAndReportsActualBlocker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlockedBranch-" + UUID().uuidString)
        let suite = "BlockedBranch-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path, branch: "source", commit: "fixture")
        let model = TaskCoordinator(directory: root, simulatorServices: self.services(), defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path; model.gitSummary = GitSummary(porcelain: "")
        model.expandedSection = .branches; model.branchSearch = "target"
        #expect(model.canSwitchBranch)
        model.records = [TaskRecord(action: .format, project: project)]
        #expect(!model.switchBranch("target"))
        #expect(model.expandedSection == .branches && model.branchSearch == "target")
        #expect(model.branchSwitchBlocker == .tasks && model.branchError == BranchSwitchBlocker.tasks.message)
        #expect(model.branchSwitch.operations.isEmpty)
        #expect(model.switchBranch("source"))
        #expect(model.expandedSection != .branches && model.branchError.isEmpty)
        model.records = []
        let owner = UUID(); #expect(model.reserveUpdate(owner: owner))
        model.expandedSection = .branches
        #expect(!model.switchBranch("target") && model.branchSwitchBlocker == .update)
        #expect(model.branchError == BranchSwitchBlocker.update.message)
        model.releaseUpdate(owner: owner)
        #expect(model.canSwitchBranch)
    }

    @Test func buildPreflightPublishesAndBlocksSelectionBeforeQueueRecordExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchBuildAdmission-" + UUID().uuidString)
        let suite = "BranchBuildAdmission-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path, branch: "source", commit: "fixture", developerDirectory: "/fixture/Developer")
        let gate = BranchInspectionGate()
        let builds = BuildCoordinator(directory: root, helper: root.appendingPathComponent("unused"), defaults: defaults, inspect: { project in
            await gate.wait(); var changed = project; changed.commit = "changed"; return changed
        }, resolveDeveloper: { _ in "/fixture/Developer" })
        let model = TaskCoordinator(directory: root, simulatorServices: self.services(), buildCoordinator: builds, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path; model.gitSummary = GitSummary(porcelain: "")
        model.expandedSection = .branches
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        let admission = Task { try await builds.submit(id: UUID(), project: project, parameters: .init(scheme: "Fixture", destinationID: UUID().uuidString), source: "fixture") }
        try await self.waitUntil { builds.admittingCount == 1 }
        #expect(changes > 0 && builds.records.isEmpty)
        #expect(!model.canSwitchBranch && model.branchSwitchBlocker == .builds)
        #expect(!model.switchBranch("target") && model.expandedSection == .branches)
        let before = changes
        await gate.release()
        await #expect(throws: BuildError.context) { try await admission.value }
        #expect(changes > before && builds.admittingCount == 0 && model.canSwitchBranch)
        #expect(model.branchSwitch.operations.isEmpty)
    }

    @Test func failedInspectionStopsWaitingAndKeepsFailureVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchInspectionFailure-" + UUID().uuidString)
        let suite = "BranchInspectionFailure-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path, branch: "source", commit: "fixture")
        let model = TaskCoordinator(directory: root, simulatorServices: self.services(), branchService: BranchSnapshotFixture(fails: true), defaults: defaults, inspectProject: { _ in (nil, [], nil) })
        model.projects = [project]; model.selectedProjectPath = project.path; model.refresh()
        #expect(model.branchSwitchBlocker == .checking)
        try await self.waitUntil { !model.checking && !model.branchError.isEmpty }
        #expect(model.branchSwitchBlocker == .unavailable)
        #expect(model.branchError == "fixture inspection failed")
        model.loadBranches(); try await self.waitUntil { !model.loadingBranches }
        #expect(!model.canSwitchBranch && !model.checking)
    }

    @Test func staleInspectionCannotKeepWaitingOrOverwritePolledCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchStaleInspection-" + UUID().uuidString)
        let suite = "BranchStaleInspection-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path, branch: "source", commit: "old"), gate = BranchInspectionGate()
        let model = TaskCoordinator(directory: root, simulatorServices: self.services(), branchService: BranchSnapshotFixture(), defaults: defaults, inspectProject: { project in
            await gate.wait(); return (project, ["stale diagnostics"], GitSummary(porcelain: ""))
        })
        model.projects = [project]; model.selectedProjectPath = project.path; model.refresh()
        while !(await gate.started) { try await Task.sleep(for: .milliseconds(10)) }
        var fresh = project; fresh.branch = "polled"; fresh.commit = "fresh"
        model.projects = [fresh]
        await gate.release()
        try await self.waitUntil { !model.checking && model.gitSummary != nil }
        #expect(model.project == fresh && model.canSwitchBranch)
        #expect(model.diagnostic != "stale diagnostics")
    }

    @Test func panelPreferencesAndRequestIDsUseBoundCheckoutWithoutChangingDesktopSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchApp-" + UUID().uuidString)
        let name = "BranchApp-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        for args in [["init", "-b", "source"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"], ["branch", "target"]] {
            try #require(EnvironmentInspector.capture("/usr/bin/git", args, directory: checkout.path).0 == 0)
        }
        let project = try EnvironmentInspector.project(path: checkout.path)
        let desktop = ProjectContext(path: root.appendingPathComponent("desktop").path)
        let model = TaskCoordinator(directory: root.appendingPathComponent("storage"), defaults: defaults)
        model.projects = [desktop, project]; model.selectedProjectPath = desktop.path
        model.checking = true
        let integration = MimicIntegration(model: model, defaults: defaults)
        try integration.workspaceStore.save(PanelWorkspace(checkout: project.path), for: "panel")
        let context = MimicIntegration.context(project), id = UUID()
        _ = try await integration.handle(.init(method: "panel_branch_preferences", parameters: ["context": context, "enabled": .bool(true)], threadID: "panel"))
        #expect(model.branchSwitch.rebaseEnabled(path: project.path)); #expect(!model.branchSwitch.rebaseEnabled(path: desktop.path))
        _ = try await integration.handle(.init(method: "panel_branch_preferences", parameters: ["context": context, "enabled": .bool(false)], threadID: "panel"))
        let parameters: [String: BridgeValue] = ["branch": .string("target"), "context": context, "requestID": .string(id.uuidString)]
        let started = try await integration.handle(.init(method: "panel_switch_branch", parameters: parameters, threadID: "panel"))
        #expect(started["id"].string == id.uuidString); #expect(model.switchingBranch); #expect(!model.canSelectProject)
        #expect(model.developmentUpdateBlockers.contains("git"))
        let duplicate = try await integration.handle(.init(method: "panel_switch_branch", parameters: parameters, threadID: "panel"))
        #expect(duplicate["id"].string == id.uuidString)
        #expect(model.branchSwitch.operations.count == 1)
        let deadline = Date().addingTimeInterval(10)
        while model.branchSwitch.isExecuting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.branchSwitch.operations.last?.phase == .succeeded); #expect(!model.switchingBranch)
        #expect(model.selectedProjectPath == desktop.path)
        #expect(model.projects.first { $0.path == project.path }?.branch == "target")
        let state = try await integration.handle(.init(method: "get_state", threadID: "panel"))
        #expect(state["context"]["branch"].string == "target")
        #expect(state["branchSwitch"]["phase"].string == "succeeded")
        #expect(state["checkoutLocked"] == .bool(false))
        let lateRetry = try await integration.handle(.init(method: "panel_switch_branch", parameters: parameters, threadID: "panel"))
        #expect(lateRetry["id"].string == id.uuidString)
        #expect(model.branchSwitch.operations.count == 1)
    }

    @Test func nativeHeaderRendersLongBranchWithCheckboxAndSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchHeader-" + UUID().uuidString)
        let name = "BranchHeader-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let model = TaskCoordinator(directory: root, defaults: defaults)
        let project = ProjectContext(path: root.path, branch: "feature/vmaslov/testflight-26.10.1-navigation-v2-profile-restoration", commit: "fixture")
        model.projects = [project]; model.selectedProjectPath = project.path
        for dark in [false, true] {
            let host = NSHostingView(rootView: ProjectBar(model: model).padding(16).frame(width: 520).background(dark ? Color.black : Color.white).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 520, height: 70), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded(); host.display()
            #expect(host.fittingSize.width <= 520)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.representation(using: .png, properties: [:]))
            try image.write(to: URL(fileURLWithPath: "/private/tmp/mimic-native-branch-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }
}
