//
//  MimicUpdateTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation
import Testing
import MimicCore
import Sparkle
@testable import Mimic

@MainActor
struct MimicUpdateTests {
    private struct BackupFailure: Error { }
    private func fixture() throws -> (TaskCoordinator, MimicIntegration, URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicUpdateTests-" + UUID().uuidString)
        let suite = "MimicUpdateTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        let integration = MimicIntegration(model: model, defaults: defaults)
        integration.developmentExit = { }
        return (model, integration, root, defaults, suite)
    }
    @Test func reservationClosesAllAdmissionSurfacesAndHasAnOwner() async throws {
        let (model, integration, root, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let owner = UUID()
        #expect(try await integration.prepareUpdate(owner: owner))
        #expect(model.updateReserved)
        #expect(!model.builds.mayAdmit()); #expect(!model.simulatorScreen.mayAdmit())
        #expect(!model.analysis.mayAdmit()); #expect(!model.aiSettings.mayAdmit())
        #expect(!model.canSelectProject); #expect(!model.canSwitchBranch)
        await #expect(throws: MimicIntegration.IntegrationError.self) {
            try await integration.handle(.init(method: "run_local_action"))
        }
        #expect(defaults.data(forKey: "mcpLocalRequests") == nil)
        integration.releaseUpdate(owner: UUID())
        #expect(model.updateReserved)
        integration.releaseUpdate(owner: owner)
        #expect(!model.updateReserved); #expect(model.analysis.mayAdmit())
    }
    @Test func backupFailureReopensAdmissionWithoutExiting() async throws {
        let (model, integration, root, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var exits = 0
        integration.developmentExit = { exits += 1 }
        integration.prepareUpdateBackup = { throw BackupFailure() }
        await #expect(throws: BackupFailure.self) { try await integration.prepareUpdate(owner: UUID()) }
        #expect(!model.updateReserved); #expect(exits == 0)
    }
    @Test func finalRecheckPreservesNewWork() async throws {
        let (model, integration, root, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let record = TaskRecord(action: .format, project: ProjectContext(path: root.path))
        integration.prepareUpdateBackup = { model.records = [record] }
        #expect(try await !integration.prepareUpdate(owner: UUID()))
        #expect(!model.updateReserved); #expect(model.records.first?.status == .queued)
    }
    @Test func downloadedUpdateWaitsForQueuedWorkThenInstallsOnce() async throws {
        let (model, integration, root, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let updater = MimicUpdater(integration: integration, lifecycle: MimicUpdateLifecycle(model: model, defaults: defaults), defaults: defaults)
        model.records = [TaskRecord(action: .format, project: ProjectContext(path: root.path))]
        var choices: [SPUUserUpdateChoice] = []
        updater.showReady(toInstallAndRelaunch: { choices.append($0) })
        try await Task.sleep(for: .milliseconds(30))
        #expect(choices.isEmpty); #expect(model.records.first?.status == .queued)
        model.records = []
        try await Task.sleep(for: .milliseconds(650))
        #expect(choices == [.install]); #expect(model.updateReserved); #expect(updater.state == .installing)
        updater.dismissUpdateInstallation()
    }
    @Test func failedFinalBackupCancelsSparkleReplacement() async throws {
        let (model, integration, root, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let updater = MimicUpdater(integration: integration, lifecycle: MimicUpdateLifecycle(model: model, defaults: defaults), defaults: defaults)
        integration.prepareUpdateBackup = { throw BackupFailure() }
        var choices: [SPUUserUpdateChoice] = []
        updater.showReady(toInstallAndRelaunch: { choices.append($0) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(choices == [.skip]); #expect(!model.updateReserved); #expect(updater.state == .failed)
    }
    @Test func disablingAutomaticUpdatesCancelsPendingInstallation() async throws {
        let (model, integration, root, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let updater = MimicUpdater(integration: integration, lifecycle: MimicUpdateLifecycle(model: model, defaults: defaults), defaults: defaults)
        model.records = [TaskRecord(action: .format, project: ProjectContext(path: root.path))]
        var choices: [SPUUserUpdateChoice] = []
        updater.showReady(toInstallAndRelaunch: { choices.append($0) })
        updater.automatic = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(choices == [.skip]); #expect(!model.updateReserved); #expect(model.records.first?.status == .queued)
    }
    @Test func deferringDuringFinalBackupCannotInstallFromALateReply() async throws {
        let (model, integration, root, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let updater = MimicUpdater(integration: integration, lifecycle: MimicUpdateLifecycle(model: model, defaults: defaults), defaults: defaults)
        var resume: CheckedContinuation<Void, Never>?
        integration.prepareUpdateBackup = { await withCheckedContinuation { resume = $0 } }
        var choices: [SPUUserUpdateChoice] = []
        updater.showReady(toInstallAndRelaunch: { choices.append($0) })
        let deadline = ContinuousClock.now + .seconds(2)
        while resume == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        _ = try #require(resume)
        #expect(model.updateReserved)
        updater.deferInstallation()
        #expect(choices == [.skip]); #expect(!model.updateReserved)
        model.records = [TaskRecord(action: .format, project: ProjectContext(path: root.path))]
        resume?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(choices == [.skip]); #expect(updater.state == .idle); #expect(!model.updateReserved)
        #expect(model.records.first?.status == .queued)
    }
    @Test func ordinaryNoUpdateAndCancelAreNotFailures() throws {
        let (model, integration, root, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let updater = MimicUpdater(integration: integration, lifecycle: MimicUpdateLifecycle(model: model, defaults: defaults), defaults: defaults)
        updater.showUpdaterError(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)), acknowledgement: { })
        #expect(updater.state == .current)
        updater.showUpdaterError(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)), acknowledgement: { })
        #expect(updater.state == .idle)
    }

    @Test func installerFailureReleasesAdmissionAndKeepsHistory() async throws {
        let (model, integration, root, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let updater = MimicUpdater(integration: integration, lifecycle: MimicUpdateLifecycle(model: model, defaults: defaults), defaults: defaults)
        var finished = TaskRecord(action: .format, project: ProjectContext(path: root.path))
        finished.status = .succeeded; model.records = [finished]
        var choices: [SPUUserUpdateChoice] = []
        updater.showReady(toInstallAndRelaunch: { choices.append($0) })
        try await Task.sleep(for: .milliseconds(30))
        #expect(choices == [.install]); #expect(model.updateReserved)
        var retries = 0
        updater.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
        updater.showUpdaterError(NSError(domain: SUSparkleErrorDomain, code: 4008), acknowledgement: { })
        try await Task.sleep(for: .milliseconds(1100))
        #expect(retries == 0)
        #expect(!model.updateReserved); #expect(updater.state == .failed)
        #expect(model.records.first?.id == finished.id); #expect(model.records.first?.status == .succeeded)
        updater.dismissUpdateInstallation()
    }

}
