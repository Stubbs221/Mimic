//
//  MimicDevelopmentUpdateTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

private struct DevelopmentGitFixture: GitBranchService {
    func inspect(_ project: ProjectContext) async throws -> GitCheckoutState {
        .init(project: project, summary: GitSummary(porcelain: ""), hasOperation: true)
    }
    func branches(_ project: ProjectContext) async throws -> [LocalBranch] { [] }
    func switchBranch(_ name: String, project: ProjectContext) async throws -> GitCheckoutState { throw BranchError.operation }
}

@MainActor
struct MimicDevelopmentUpdateTests {
    @Test(arguments: ["queued", "running"])
    func serverCIObservationDoesNotBlockDevelopmentUpdate(_ status: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MimicDevelopment-" + UUID().uuidString)
        let suite = "MimicDevelopment-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let snapshot = try Profile11Fixture.snapshot(directory: directory, legacyCI: true)
        let execution = try snapshot.execution(role: .uiTests, values: [.branch: "develop", .plan: "SMOKE"])
        let checkout = ProjectContext(path: directory.path, branch: "develop")
        let connection = JenkinsConnection(baseURL: URL(string: "https://jenkins.example.invalid")!, username: "fixture")
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let run: [String: Any] = ["id": id.uuidString, "requestID": id.uuidString, "checkout": try object(checkout),
                                  "execution": try object(execution), "jenkins": try object(connection), "branch": "develop",
                                  "createdAt": 0, "status": status, "queueURL": "https://jenkins.example.invalid/queue/item/7/", "jobs": []]
        try JSONSerialization.data(withJSONObject: [run]).write(to: directory.appendingPathComponent("profile-remote-runs.json"))
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        defer { model.profileRemote.stop() }
        #expect(model.profileRemote.runs.first?.status == status)
        #expect(model.canQuitForDevelopmentUpdate)
        let integration = MimicIntegration(model: model, defaults: defaults)
        var exits = 0
        integration.developmentExit = { exits += 1 }
        let reply = try await integration.handle(.init(method: "prepare_development_update"))
        #expect(reply["ready"] == .bool(true))
        try await Task.sleep(for: .milliseconds(20))
        #expect(exits == 1)
        #expect(model.profileRemote.runs.first?.id == id)
        model.profileRemote.stop()
        let restored = TaskCoordinator(directory: directory, defaults: defaults)
        defer { restored.profileRemote.stop() }
        #expect(restored.profileRemote.runs.first?.id == id)
        #expect(restored.profileRemote.runs.first?.status == status)
        #expect(restored.profileRemote.runs.first?.queueURL?.absoluteString == "https://jenkins.example.invalid/queue/item/7/")
    }

    private func fixture() throws -> (TaskCoordinator, URL, UserDefaults, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MimicDevelopment-" + UUID().uuidString)
        let suite = "MimicDevelopment-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (TaskCoordinator(directory: directory, defaults: defaults), directory, defaults, suite)
    }

    @Test(arguments: [TaskStatus.queued, .running])
    func pendingWorkPreventsExitWithoutCancellation(_ status: TaskStatus) async throws {
        let (model, directory, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        var record = TaskRecord(action: .format, project: ProjectContext(path: "/private/tmp/development-fixture"))
        record.status = status; model.records = [record]
        let integration = MimicIntegration(model: model, defaults: defaults)
        var exits = 0
        integration.developmentExit = { exits += 1 }
        let reply = try await integration.handle(.init(method: "prepare_development_update"))
        #expect(reply["ready"] == .bool(false))
        #expect(exits == 0); #expect(model.records.first?.status == status)
    }

    @Test func idleExitRechecksNewAdmissions() async throws {
        let (model, directory, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let integration = MimicIntegration(model: model, defaults: defaults)
        var exits = 0
        integration.developmentExit = { exits += 1 }
        #expect(model.canQuitForDevelopmentUpdate)
        let observation = try await integration.handle(.init(method: "get_development_update_state"))
        #expect(observation["ready"] == .bool(true)); #expect(exits == 0)
        let reply = try await integration.handle(.init(method: "prepare_development_update"))
        #expect(reply["ready"] == .bool(true))
        let record = TaskRecord(action: .format, project: ProjectContext(path: "/private/tmp/development-fixture"))
        model.records = [record]
        try await Task.sleep(for: .milliseconds(20))
        #expect(exits == 0); #expect(model.records.first?.status == .queued)
        model.records = []
        _ = try await integration.handle(.init(method: "prepare_development_update"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(exits == 1)
    }

    @Test func rejectsParametersAndMissingExitOwner() async throws {
        let (model, directory, defaults, suite) = try self.fixture()
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let integration = MimicIntegration(model: model, defaults: defaults)
        let reply = try await integration.handle(.init(method: "prepare_development_update"))
        #expect(reply["ready"] == .bool(false))
        await #expect(throws: MimicIntegration.IntegrationError.self) {
            try await integration.handle(.init(method: "prepare_development_update", parameters: ["force": .bool(true)]))
        }
    }

    @Test func unresolvedBuildBlocksDevelopmentReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MimicDevelopment-" + UUID().uuidString)
        let suite = "MimicDevelopment-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        var record = BuildActivity(project: ProjectContext(path: "/private/tmp/development-fixture"), parameters: .init(), source: "fixture")
        record.status = .unknown
        try BuildHistoryStore(directory: directory).save([record])
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        #expect(!model.canQuitForDevelopmentUpdate)
        #expect(model.builds.records.first?.status == .unknown)
    }

    @Test func buildPreflightBlocksExitBeforeRecordExists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MimicDevelopment-" + UUID().uuidString)
        let suite = "MimicDevelopment-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let project = ProjectContext(path: "/private/tmp/development-fixture", branch: "fixture", commit: "fixture")
        let builds = BuildCoordinator(directory: directory, helper: URL(fileURLWithPath: "/missing-fixture-helper"), defaults: defaults, inspect: { project in
            try await Task.sleep(for: .milliseconds(100))
            return project
        }, resolveDeveloper: { _ in "/fixture/Developer" })
        let model = TaskCoordinator(directory: directory, buildCoordinator: builds, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path
        let submission = Task {
            try await builds.submit(id: UUID(), project: project, parameters: .init(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"), source: "fixture")
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while builds.admittingCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(builds.admittingCount == 1); #expect(builds.records.isEmpty)
        #expect(!model.canQuitForDevelopmentUpdate)
        _ = try await submission.value
        #expect(builds.admittingCount == 0)
    }

    @Test func externalCheckoutOperationDoesNotBlockIdleAppReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MimicDevelopment-" + UUID().uuidString)
        let suite = "MimicDevelopment-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let model = TaskCoordinator(directory: directory, branchService: DevelopmentGitFixture(), defaults: defaults)
        let project = ProjectContext(path: "/private/tmp/development-fixture")
        model.projects = [project]; model.selectedProjectPath = project.path
        model.refreshGit()
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.hasGitOperation, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(model.hasGitOperation); #expect(model.canQuitForDevelopmentUpdate)
    }
}
