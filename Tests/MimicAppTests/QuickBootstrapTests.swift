//
//  QuickBootstrapTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 06.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

private actor AdmissionProbe {
    private(set) var calls: [(ProjectContext, BootstrapOptions)] = []
    private var pending: CheckedContinuation<BootstrapAdmissionResult, Never>?

    func inspect(_ project: ProjectContext, options: BootstrapOptions) async -> BootstrapAdmissionResult {
        self.calls.append((project, options))
        return await withCheckedContinuation { self.pending = $0 }
    }

    func complete(_ result: BootstrapAdmissionResult) {
        let pending = self.pending
        self.pending = nil
        pending?.resume(returning: result)
    }
}

@MainActor
private struct QuickFixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let model: TaskCoordinator
    let project = ProjectContext(path: "/private/tmp/quick-fixture", branch: "original", commit: "fixture-sha")

    init(probe: AdmissionProbe) throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickBootstrap-" + UUID().uuidString)
        self.suite = "QuickBootstrap-" + UUID().uuidString
        self.defaults = try #require(UserDefaults(suiteName: self.suite))
        _ = try Profile11Fixture.install(directory: self.directory)
        self.model = TaskCoordinator(directory: self.directory, defaults: self.defaults, inspectBootstrapAdmission: { await probe.inspect($0, options: $1) })
        self.model.projects = [self.project]
        self.model.selectedProjectPath = self.project.path
        // Hold the queue with a fixture record. No real process or Xcode quit is ever requested.
        var barrier = TaskRecord(action: .format, project: self.project)
        barrier.status = .running
        self.model.records = [barrier]
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: self.directory)
        self.defaults.removePersistentDomain(forName: self.suite)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct QuickBootstrapTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(condition())
    }

    private func waitForInspection(_ probe: AdmissionProbe) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await probe.calls.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await probe.calls.count == 1)
    }

    @Test(arguments: BootstrapPlatform.allCases)
    func quickLaunchUsesScriptDefaultsAndPinsTaskAcrossCheckoutChanges(_ platform: BootstrapPlatform) async throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        let model = fixture.model
        var options = BootstrapOptions()
        options.full = false; options.device = true; options.match = false
        options.dependencies = false; options.uiDependencies = true; options.setup = true
        model.bootstrapOptions = options
        model.requestQuickBootstrap(platform: platform)
        let activity = try #require(model.quickBootstrapActivity)
        #expect(activity.isPreparing(in: model.records)); #expect(model.requestingBootstrap)
        #expect(!model.canRequestQuickBootstrap)
        model.requestQuickBootstrap(platform: platform == .ios ? .tvos : .ios)
        try await self.waitForInspection(probe)
        let expected = BootstrapOptions.standard(platform: platform)
        let inspected = try #require(await probe.calls.first)
        #expect(inspected.0 == fixture.project); #expect(inspected.1 == expected)
        model.projects.append(ProjectContext(path: "/private/tmp/another-checkout"))
        model.selectedProjectPath = "/private/tmp/another-checkout"
        model.bootstrapOptions = BootstrapPreset.simulator.options
        await probe.complete(.ready(fixture.project))
        try await self.waitUntil { !model.requestingBootstrap }
        let captured = try #require(model.records.first { $0.id == activity.request.id })
        #expect(captured.project == fixture.project); #expect(captured.options == expected)
        #expect(captured.status == .queued); #expect(model.records.count == 2)
        #expect(model.quickBootstrapActivity?.record(in: model.records).id == captured.id)
        #expect(model.bootstrapOptions == BootstrapPreset.simulator.options)
        #expect(model.quickBootstrapActivity?.isPreparing(in: model.records) == false)
    }

    @Test(arguments: ["missing: fixture-ruby", "project.invalid", "checkout.changed"])
    func rejectsAdmissionWithoutQueueing(_ error: String) async throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        fixture.model.requestQuickBootstrap(platform: .tvos)
        try await self.waitForInspection(probe)
        await probe.complete(.failed(error))
        try await self.waitUntil { !fixture.model.requestingBootstrap }
        #expect(fixture.model.records.count == 1)
        #expect(fixture.model.quickBootstrapActivity?.error?.isEmpty == false)
        #expect(fixture.model.quickBootstrapActivity?.isPreparing(in: fixture.model.records) == false)
        #expect(fixture.model.unreadFailure)
        #expect(fixture.model.canRequestQuickBootstrap)
    }

    @Test
    func cancellingAdmissionIgnoresLateResult() async throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        fixture.model.requestQuickBootstrap(platform: .ios)
        let id = try #require(fixture.model.quickBootstrapActivity?.request.id)
        try await self.waitForInspection(probe)
        fixture.model.cancelQuickBootstrap(id: id)
        #expect(fixture.model.quickBootstrapActivity?.record(in: []).status == .cancelled)
        await probe.complete(.ready(fixture.project))
        try await self.waitUntil { !fixture.model.requestingBootstrap }
        #expect(fixture.model.records.count == 1); #expect(fixture.model.canRequestQuickBootstrap)
        #expect(fixture.model.quickBootstrapActivity?.isPreparing(in: []) == false)
    }

    @Test
    func cancellingQueuedRequestUsesExistingQueueCancellation() async throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        fixture.model.requestQuickBootstrap(platform: .tvos)
        let id = try #require(fixture.model.quickBootstrapActivity?.request.id)
        try await self.waitForInspection(probe)
        await probe.complete(.ready(fixture.project))
        try await self.waitUntil { !fixture.model.requestingBootstrap }
        fixture.model.cancelQuickBootstrap(id: id)
        #expect(fixture.model.quickBootstrapActivity?.record(in: fixture.model.records).status == .cancelled)
        #expect(fixture.model.records[0].status == .running)
    }

    @Test
    func queuedSnapshotSurvivesCompatibleAndRejectedReimport() async throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        let model = fixture.model, original = try #require(model.activeProfile)
        model.requestQuickBootstrap(platform: .ios)
        let id = try #require(model.quickBootstrapActivity?.request.id)
        try await self.waitForInspection(probe)
        await probe.complete(.ready(fixture.project))
        try await self.waitUntil { !model.requestingBootstrap }
        var json = try #require(JSONSerialization.jsonObject(with: Profile11Fixture.data()) as? [String: Any])
        json["version"] = "2"
        let replacement = try Profile11Fixture.install(directory: fixture.directory, data: JSONSerialization.data(withJSONObject: json))
        model.activeProfile = replacement
        #expect(replacement.revision != original.revision)
        let queued = try #require(model.records.first { $0.id == id })
        #expect(queued.status == .queued); #expect(queued.profileExecution?.snapshot == original)
        let store = ProfileStore(directory: fixture.directory.appendingPathComponent("Profiles"))
        try store.verify(original); try store.verify(replacement)
        json["interface"] = ["version": 1, "bindings": []]
        do {
            _ = try Profile11Fixture.install(directory: fixture.directory, data: JSONSerialization.data(withJSONObject: json))
            Issue.record("An incompatible reimport must be rejected")
        } catch { #expect(try store.active() == replacement) }
        #expect(model.records.first { $0.id == id }?.profileExecution?.snapshot == original)
        model.cancel(id: id)
    }

    @Test
    func exitWaitsForAdmissionAndNeverQueuesItsLateResult() async throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        fixture.model.records = []
        var replies = 0
        fixture.model.afterStopped = { replies += 1 }
        fixture.model.requestQuickBootstrap(platform: .tvos)
        try await self.waitForInspection(probe)
        fixture.model.stopAndExit()
        #expect(replies == 0); #expect(!fixture.model.canRequestQuickBootstrap)
        await probe.complete(.ready(fixture.project))
        try await self.waitUntil { replies == 1 }
        #expect(fixture.model.records.isEmpty)
    }

    @Test
    func admissionReadsCurrentGitInsteadOfCachedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicAdmission-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fixture.xcworkspace"), withIntermediateDirectories: true)
        for name in ["bootstrap.sh", "utils.sh"] {
            try Data("# Fixture only; never executed.\n".utf8).write(to: root.appendingPathComponent(name))
        }
        for arguments in [
            ["init", "-b", "main"], ["add", "."],
            ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"]
        ] {
            let result = EnvironmentInspector.capture("/usr/bin/git", ["-C", root.path] + arguments)
            try #require(result.0 == 0)
        }
        let cached = try EnvironmentInspector.project(path: root.path)
        try #require(EnvironmentInspector.capture("/usr/bin/git", ["-C", root.path, "switch", "-c", "updated"]).0 == 0)
        try #require(EnvironmentInspector.capture("/usr/bin/git", ["-C", root.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "updated"]).0 == 0)
        let actual = try EnvironmentInspector.project(path: root.path)
        #expect(actual.branch != cached.branch); #expect(actual.commit != cached.commit)
        var options = BootstrapOptions()
        options.full = false; options.dependencies = false; options.setup = false
        let result = await BootstrapAdmissionResult.inspect(project: cached, options: options)
        switch result {
        case let .ready(project): #expect(project == actual)
        case let .failed(error):
            Issue.record("Git admission must reach profile validation: \(error)")
        }
        let directory = root.appendingPathComponent("mimic-state")
        _ = try Profile11Fixture.install(directory: directory)
        let suite = "BootstrapAdmission-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Exercise the production admission closure while keeping process launch blocked.
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        model.projects = [cached]; model.selectedProjectPath = cached.path
        var barrier = TaskRecord(action: .format, project: actual)
        barrier.status = .running; model.records = [barrier]
        model.requestQuickBootstrap(platform: .ios)
        try await self.waitUntil { !model.requestingBootstrap }
        let queued = try #require(model.records.last { $0.action == .bootstrap })
        #expect(queued.project == actual)
        #expect(queued.profileExecution != nil)
        #expect(model.quickBootstrapActivity?.error == nil)
    }

    @Test(arguments: BootstrapPlatform.allCases)
    func staleGitContextIsRefreshedBeforeQueueing(_ platform: BootstrapPlatform) async throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        fixture.model.requestQuickBootstrap(platform: platform)
        let original = try #require(fixture.model.quickBootstrapActivity?.request)
        try await self.waitForInspection(probe)
        var changed = fixture.project; changed.branch = "new-branch"; changed.commit = "different-sha"
        await probe.complete(.ready(changed))
        try await self.waitUntil { !fixture.model.requestingBootstrap }
        let queued = try #require(fixture.model.records.first { $0.id == original.id })
        #expect(queued.project == changed)
        #expect(queued.options == .standard(platform: platform))
        #expect(queued.createdAt == original.createdAt)
        #expect(fixture.model.project == changed)
        #expect(fixture.model.quickBootstrapActivity?.request.project == changed)
        #expect(fixture.model.quickBootstrapActivity?.error == nil)
        #expect(!QueuePolicy.matches(fixture.project, request: queued.project))
    }

    @Test(arguments: [false, true])
    func admissionCannotReplaceCheckoutOrXcode(_ changeXcode: Bool) async throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        fixture.model.requestQuickBootstrap(platform: .tvos)
        try await self.waitForInspection(probe)
        let changed = changeXcode
            ? ProjectContext(path: fixture.project.path, developerDirectory: "/fixture/Xcode")
            : ProjectContext(path: "/private/tmp/different-checkout")
        await probe.complete(.ready(changed))
        try await self.waitUntil { !fixture.model.requestingBootstrap }
        #expect(fixture.model.records.count == 1)
        #expect(fixture.model.quickBootstrapActivity?.error == text("checkout.changed"))
    }

    @Test(arguments: [MimicAction.fullCleanup, .derivedDataCleanup])
    func quickCleanupQueuesWithCurrentCheckoutAndIOSDefaults(_ action: MimicAction) async throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        let root = fixture.directory.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fixture.xcworkspace"), withIntermediateDirectories: true)
        for name in ["bootstrap.sh", "utils.sh"] { try Data("# Never executed\n".utf8).write(to: root.appendingPathComponent(name)) }
        for args in [["init", "-b", "main"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"]] {
            try #require(EnvironmentInspector.capture("/usr/bin/git", ["-C", root.path] + args).0 == 0)
        }
        fixture.model.projects = [ProjectContext(path: root.path, branch: "stale", commit: "stale")]
        fixture.model.selectedProjectPath = fixture.model.projects[0].path
        fixture.model.bootstrapOptions = .standard(platform: .tvos)
        #expect(fixture.model.canRequestQuickCleanup)
        fixture.model.requestQuickCleanup(action)
        try await self.waitUntil { fixture.model.records.count == 2 }
        let queued = try #require(fixture.model.records.last)
        #expect(queued.action == action); #expect(queued.status == .queued)
        #expect(queued.project.branch == "main"); #expect(queued.project.commit != "stale")
        #expect(queued.options == .standard(platform: .ios))
        #expect(fixture.model.selectedTaskID == queued.id)
        #expect(fixture.model.quickBootstrapActivity == nil)
        #expect(fixture.model.records.first?.status == .running)
    }

    @Test
    func menuIncludesCleanupAndDisablesMissingCheckout() throws {
        let probe = AdmissionProbe(), fixture = try QuickFixture(probe: probe)
        defer { fixture.cleanUp() }
        let delegate = AppDelegate(model: fixture.model)
        let menu = delegate.quickMenu()
        #expect(menu.items.map(\.title) == ["Bootstrap iOS", "Bootstrap tvOS", "", text("action.fullCleanup"), text("action.derivedDataCleanup"), "", text("interface.map.title"), text("setup.title"), "", text("quit")])
        #expect(menu.items[2].isSeparatorItem); #expect(menu.items[5].isSeparatorItem)
        #expect(menu.items[3].representedObject as? String == MimicAction.fullCleanup.rawValue)
        #expect(menu.items[4].representedObject as? String == MimicAction.derivedDataCleanup.rawValue)
        #expect(menu.items[3].isEnabled && menu.items[4].isEnabled)
        #expect(menu.items[0].isEnabled && menu.items[1].isEnabled)
        #expect(menu.items[9].action == #selector(NSApplication.terminate(_:)))
        fixture.model.selectedProjectPath = ""
        #expect(!delegate.quickMenu().items[0].isEnabled)
        #expect(!delegate.quickMenu().items[3].isEnabled && !delegate.quickMenu().items[4].isEnabled)
        fixture.model.requestQuickBootstrap(platform: .tvos)
        #expect(fixture.model.quickBootstrapActivity == nil)
        fixture.model.selectedProjectPath = fixture.project.path
        fixture.model.bootstrapOptions.full = false
        fixture.model.bootstrapOptions.dependencies = false
        fixture.model.bootstrapOptions.uiDependencies = false
        fixture.model.bootstrapOptions.setup = false
        #expect(delegate.quickMenu().items[1].isEnabled)
    }

    @Test(arguments: [TaskStatus.queued, .running, .succeeded, .failed, .cancelled, .interrupted])
    func activityReadsResultByID(_ status: TaskStatus) {
        let project = ProjectContext(path: "/private/tmp/fixture")
        let record = TaskRecord(action: .bootstrap, project: project)
        let activity = QuickBootstrapActivity(request: record)
        var result = record; result.status = status
        let unrelated = TaskRecord(action: .bootstrap, project: project)
        #expect(activity.record(in: [unrelated, result]).status == status)
        #expect(activity.record(in: [unrelated, result]).id == record.id)
        #expect(!activity.isPreparing(in: [unrelated, result]))
    }

}
