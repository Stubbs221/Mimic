//
//  MimicSetupTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

@MainActor private final class SetupSystemFixture: MimicSetupSystem {
    var loginStatus = "setup.disabled"
    var rejectLogin = false
    var notificationResult = "setup.denied"
    var loginRequests: [Bool] = []
    func setLogin(enabled: Bool) async throws {
        self.loginRequests.append(enabled)
        if self.rejectLogin { throw MimicBridgeError.unavailable }
        self.loginStatus = enabled ? "setup.approval" : "setup.disabled"
    }
    func notifications(enabled: Bool) async -> String { enabled ? self.notificationResult : "setup.disabled" }
}
@MainActor struct MimicSetupTests {
    @Test func defaultsSkipAndDeniedPermissionsDoNotBlockCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MimicSetupTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = TaskCoordinator(directory: root, defaults: defaults)
        let system = SetupSystemFixture()
        let setup = MimicSetupModel(model: model, defaults: defaults, home: root.appendingPathComponent("codex"), system: system, codex: nil)
        #expect(setup.autoOpen && setup.login && setup.notify)
        #expect(!setup.canContinue)
        let project = ProjectContext(path: "/tmp/setup project", branch: "branch", commit: "sha")
        model.projects = [project]; model.selectedProjectPath = project.path
        #expect(setup.canContinue)
        setup.next(); await setup.connect()
        #expect(setup.statuses["setup.codex"] == "setup.codex.missing")
        setup.next(skip: true); #expect(!setup.canContinue)
        setup.next(skip: true); setup.next(skip: true)
        #expect(setup.step == 4)
        await setup.apply()
        #expect(setup.finished && setup.step == 5)
        #expect(setup.statuses["setup.login"] == "setup.approval")
        #expect(setup.statuses["setup.notify"] == "setup.denied")
        #expect(!defaults.bool(forKey: "setupNotifications"))
        #expect(defaults.bool(forKey: "setupNotificationChoice"))
        #expect(try MimicSetupRules.contains(project: project.path, home: root.appendingPathComponent("codex")))
        #expect(model.records.isEmpty)
        #expect(!setup.report.contains(project.path))
        await setup.uninstall()
        #expect(try !MimicSetupRules.contains(project: project.path, home: root.appendingPathComponent("codex")))
        #expect(system.loginRequests == [true, false])
    }
    @Test func loginFailureAndRuleFailureAreIndependentAndRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MimicSetupTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = TaskCoordinator(directory: root, defaults: defaults)
        let project = ProjectContext(path: "/tmp/unsafe\nproject", branch: "branch", commit: "sha")
        model.projects = [project]; model.selectedProjectPath = project.path
        let system = SetupSystemFixture(); system.rejectLogin = true; system.notificationResult = "setup.enabled"
        let setup = MimicSetupModel(model: model, defaults: defaults, home: root.appendingPathComponent("codex"), system: system, codex: nil)
        await setup.apply()
        #expect(setup.finished)
        #expect(setup.statuses["setup.autoOpen"] == "setup.rules.failed")
        #expect(setup.statuses["setup.login"] == "setup.login.failed")
        #expect(setup.statuses["setup.notify"] == "setup.enabled")
        #expect(defaults.bool(forKey: "setupNotifications"))
        #expect(model.records.isEmpty)
    }
    @Test func notificationsIgnoreHistoryAndOnlyReportNewSuccessOrFailure() throws {
        let suite = "MimicSetupNotifications-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "setupNotifications")
        var deliveries: [Bool] = []
        let notifications = MimicTaskNotifications(defaults: defaults, deliver: { _, success in deliveries.append(success) })
        var record = TaskRecord(action: .format, project: ProjectContext(path: "/tmp/fixture", branch: "branch", commit: "sha"))
        record.status = .failed
        notifications.update(records: [record], runs: [])
        #expect(deliveries.isEmpty)
        record.status = .running; notifications.update(records: [record], runs: [])
        record.status = .succeeded; notifications.update(records: [record], runs: [])
        notifications.update(records: [record], runs: [])
        #expect(deliveries == [true])
        record.status = .running; notifications.update(records: [record], runs: [])
        record.status = .cancelled; notifications.update(records: [record], runs: [])
        #expect(deliveries == [true])
        defaults.set(false, forKey: "setupNotifications")
        record.status = .failed; notifications.update(records: [record], runs: [])
        #expect(deliveries == [true])
    }

}
