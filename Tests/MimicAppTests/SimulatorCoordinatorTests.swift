//
//  SimulatorCoordinatorTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
import MimicCore
@testable import AppleSimulatorMCP
@testable import Mimic

@MainActor private final class SimulatorDriverFixture: SimulatorNativeDriver {
    let device: UUID
    var calls: [String] = []
    var descriptor: AppleSimulatorDescriptor?
    var revision: UInt64 = 0
    var failAction = false
    init(device: UUID) { self.device = device }
    func connect(developerDirectory: String) async throws { calls.append("connect") }
    func authorize(workspace: URL) async throws { calls.append("authorize") }
    func startSession(deviceID: UUID, workspace: URL?) async throws -> AppleSimulatorDescriptor {
        calls.append("start")
        let device = deviceID
        let session = AppleSimulatorSession { _, _ in .object(["deviceUUID": .string(device.uuidString), "deviceIsSimulator": .bool(true), "interactionSessionKey": .string("fixture-secret")]) }
        let descriptor = try await session.start(deviceID: deviceID, workspace: workspace); self.descriptor = descriptor; return descriptor
    }
    func capture(_ id: UUID) async throws -> SimulatorFrame { calls.append("capture"); revision += 1; return frame(id) }
    func perform(_ id: UUID, action: AppleSimulatorAction, revision: UInt64) async throws -> SimulatorFrame { calls.append("perform"); if failAction { throw AppleSimulatorError.connectionLost }; self.revision += 1; return frame(id) }
    func install(_ id: UUID) async throws { calls.append("install") }
    func close(_ id: UUID) async throws { calls.append("close") }
    func disconnect() async { calls.append("disconnect") }
    private func frame(_ id: UUID) -> SimulatorFrame { .init(sessionID: id, revision: revision, width: 402, height: 874, jpeg: Data([1, 2, 3]), hierarchy: "private-fixture-hierarchy", targets: [], applicationState: "Running") }
}
@MainActor struct SimulatorCoordinatorTests {
    private func fixture() -> (SimulatorCoordinator, SimulatorDriverFixture, ProjectContext, URL) {
        let path = URL(fileURLWithPath: "/private/tmp/MimicSimulatorTests-" + UUID().uuidString), device = UUID()
        let project = ProjectContext(path: path.path, branch: "fixture", commit: "fixture-sha", developerDirectory: "/fixture/Xcode27/Contents/Developer", appleTarget: AppleTarget(path: "Fixture.xcworkspace"))
        let driver = SimulatorDriverFixture(device: device)
        let owner = SimulatorCoordinator(directory: path, supports: { _ in true }, makeDriver: { driver }, inspect: { $0 }, catalogue: { _ in [.init(id: device, name: "iPhone Fixture", runtime: "iOS 27", state: "Booted")] })
        owner.currentProject = { project }; return (owner, driver, project, path)
    }
    private func completed(_ owner: SimulatorCoordinator, _ id: UUID) async throws {
        for _ in 0..<200 { if owner.records.first(where: { $0.id == id })?.status.isPending == false { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Fixture operation did not complete")
    }
    @Test func sharedQueueAdmissionKeepsNativeActionsAndTextPrivate() async throws {
        let (owner, driver, project, path) = fixture(); defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let id = UUID(), record = try await owner.submit(id: id, kind: .start, project: project, device: driver.device)
        #expect(driver.calls.isEmpty); #expect(record.status == .queued)
        owner.start(record); try await completed(owner, id)
        let descriptor = try #require(owner.descriptor), revision = try #require(owner.frame?.revision)
        let actionID = UUID(), action = AppleSimulatorAction.text("PRIVATE-TYPED-FIXTURE")
        let typed = try await owner.submit(id: actionID, kind: .action, project: project, device: driver.device, sessionID: descriptor.id, action: action, revision: revision)
        let duplicate = try await owner.submit(id: actionID, kind: .action, project: project, device: driver.device, sessionID: descriptor.id, action: action, revision: revision)
        #expect(typed.id == duplicate.id); owner.start(typed); try await completed(owner, actionID)
        #expect(driver.calls.filter { $0 == "perform" }.count == 1)
        let saved = try String(contentsOf: path.appendingPathComponent("SimulatorActivities.json"), encoding: .utf8)
        let metadata = String(decoding: try JSONEncoder().encode(owner.metadata), as: UTF8.self)
        for value in ["PRIVATE-TYPED-FIXTURE", "private-fixture-hierarchy", "fixture-secret", "AQID"] { #expect(!saved.contains(value)); #expect(!metadata.contains(value)) }
        #expect(try owner.observation(sessionID: descriptor.id)["hierarchy"].string == "private-fixture-hierarchy")
        let close = try await owner.submit(id: UUID(), kind: .close, project: project, device: driver.device, sessionID: descriptor.id)
        owner.start(close); try await completed(owner, close.id); #expect(owner.descriptor == nil); #expect(driver.calls.suffix(2) == ["close", "disconnect"])
    }
    @Test func completedRequestRejectsChangedActionRevisionAndUnverifiableRestart() async throws {
        let (owner, driver, project, path) = fixture(); defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let start = try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device)
        owner.start(start); try await completed(owner, start.id)
        let descriptor = try #require(owner.descriptor), revision = try #require(owner.frame?.revision), id = UUID()
        let action = AppleSimulatorAction.text("PRIVATE-COMPLETED-TEXT")
        let first = try await owner.submit(id: id, kind: .action, project: project, device: driver.device, sessionID: descriptor.id, action: action, revision: revision)
        owner.start(first); try await completed(owner, id)
        let replay = try await owner.submit(id: id, kind: .action, project: project, device: driver.device, sessionID: descriptor.id, action: action, revision: revision)
        #expect(replay.status == .succeeded)
        for changed in [AppleSimulatorAction.home, .tap(x: 5, y: 5), .text("DIFFERENT-PRIVATE-TEXT")] {
            await #expect(throws: BuildError.duplicate) { try await owner.submit(id: id, kind: .action, project: project, device: driver.device, sessionID: descriptor.id, action: changed, revision: revision) }
        }
        await #expect(throws: BuildError.duplicate) { try await owner.submit(id: id, kind: .action, project: project, device: driver.device, sessionID: descriptor.id, action: action, revision: revision + 1) }
        let restarted = SimulatorCoordinator(directory: path)
        await #expect(throws: BuildError.duplicate) { try await restarted.submit(id: id, kind: .action, project: project, device: driver.device, sessionID: descriptor.id, action: action, revision: revision) }
        #expect(driver.calls.filter { $0 == "perform" }.count == 1)
        let disk = try String(contentsOf: path.appendingPathComponent("SimulatorActivities.json"), encoding: .utf8)
        #expect(!disk.contains("PRIVATE-COMPLETED-TEXT") && !disk.contains("fingerprint"))
        let close = try await owner.submit(id: UUID(), kind: .close, project: project, device: driver.device, sessionID: descriptor.id)
        owner.start(close); try await completed(owner, close.id)
    }

    @Test func lostMutationHoldsQueueSurvivesRestartAndNeverReplays() async throws {
        let (owner, driver, project, path) = fixture(); defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let record = try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device); owner.start(record); try await completed(owner, record.id)
        let descriptor = try #require(owner.descriptor), revision = try #require(owner.frame?.revision); driver.failAction = true
        let recordID = UUID(), action = try await owner.submit(id: recordID, kind: .action, project: project, device: driver.device, sessionID: descriptor.id, action: .home, revision: revision)
        owner.start(action); try await completed(owner, recordID)
        #expect(owner.records.last?.status == .unknown); #expect(owner.busy); #expect(owner.frame == nil)
        _ = try await owner.submit(id: recordID, kind: .action, project: project, device: driver.device, sessionID: descriptor.id, action: .home, revision: revision)
        #expect(driver.calls.filter { $0 == "perform" }.count == 1)
        let restarted = SimulatorCoordinator(directory: path)
        #expect(restarted.busy); #expect(restarted.records.last?.status == .unknown)
        try await owner.releaseUnknown(recordID); #expect(!owner.busy); #expect(owner.descriptor == nil)
    }
    @Test func tenThousandCompletedRequestsKeepAdmissionReplayAndRecovery() async throws {
        let (initial, driver, project, path) = fixture(); defer { initial.stop(); try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 0)
        let saved = (0..<10_000).map { index in
            var record = SimulatorActivity(id: UUID(), project: project, developer: project.developerDirectory!, deviceID: driver.device, sessionID: nil, kind: .start, createdAt: date.addingTimeInterval(Double(index)))
            record.status = .succeeded; return record
        }
        let url = path.appendingPathComponent("SimulatorActivities.json")
        try JSONEncoder().encode(saved).write(to: url)
        let owner = SimulatorCoordinator(directory: path, supports: { _ in true }, makeDriver: { driver }, inspect: { $0 }, catalogue: { _ in [.init(id: driver.device, name: "Fixture", runtime: "iOS 27", state: "Booted")] })
        owner.currentProject = { project }
        #expect(owner.records.count == 100 && !owner.busy)
        let old = try #require(saved.first)
        #expect(owner.activity(old.id)?.status == .succeeded)
        let replay = try await owner.submit(id: old.id, kind: .start, project: project, device: driver.device)
        #expect(replay.id == old.id && driver.calls.isEmpty)
        let new = try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device)
        owner.start(new); try await completed(owner, new.id)
        #expect(driver.calls.filter { $0 == "start" }.count == 1 && owner.records.count == 100)
        let close = try await owner.submit(id: UUID(), kind: .close, project: project, device: driver.device, sessionID: try #require(owner.descriptor?.id))
        owner.start(close); try await completed(owner, close.id)
        let restarted = SimulatorCoordinator(directory: path)
        #expect(restarted.records.count == 100 && !restarted.busy)
        #expect(try await restarted.submit(id: old.id, kind: .start, project: project, device: driver.device).status == .succeeded)
        #expect(try JSONDecoder().decode([SimulatorActivity].self, from: Data(contentsOf: url)).count == 10_002)
    }
    @Test func activeCapacityHasSpecificErrorAndUnknownSurvivesRetention() async throws {
        let (initial, driver, project, path) = fixture(); defer { initial.stop(); try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let unknowns = (0..<100).map { _ in
            var record = SimulatorActivity(id: UUID(), project: project, developer: project.developerDirectory!, deviceID: driver.device, sessionID: nil, kind: .install)
            record.status = .unknown; return record
        }
        try JSONEncoder().encode(unknowns).write(to: path.appendingPathComponent("SimulatorActivities.json"))
        let owner = SimulatorCoordinator(directory: path); owner.currentProject = { project }
        await #expect(throws: BuildError.capacity) { try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device) }
        #expect(owner.busy && owner.records.count == 100)
        try await owner.releaseUnknown(unknowns[0].id)
        #expect(owner.activity(unknowns[0].id)?.queueReleased == true && owner.busy)
        let restarted = SimulatorCoordinator(directory: path)
        #expect(restarted.busy && restarted.records.count == 100)
        #expect(restarted.activity(unknowns[0].id)?.queueReleased == true)
    }
    @Test func malformedReplayStorageCannotBeOverwrittenOrAdmitWork() async throws {
        let (initial, driver, project, path) = fixture(); defer { initial.stop(); try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let url = path.appendingPathComponent("SimulatorActivities.json"), data = Data("malformed-fixture".utf8)
        try data.write(to: url)
        let owner = SimulatorCoordinator(directory: path); owner.currentProject = { project }
        await #expect(throws: BuildError.unavailable) { try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device) }
        owner.stop()
        #expect(try Data(contentsOf: url) == data && driver.calls.isEmpty)
    }

    @Test func privatePanelAliasPerformsOneActionWithoutClosingSession() async throws {
        let (owner, driver, initialProject, path) = fixture()
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let project = ProjectContext(path: initialProject.path, branch: initialProject.branch, commit: initialProject.commit, developerDirectory: initialProject.developerDirectory, appleTarget: initialProject.appleTarget)
        let suite = "MimicSimulatorAlias-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { owner.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: path) }
        let model = TaskCoordinator(directory: path, simulatorCoordinator: owner, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path
        let facade = MimicIntegration(model: model, defaults: defaults)
        let context = MimicIntegration.context(project)
        let start = try await facade.handle(.init(method: "start_simulator_session", parameters: ["context": context, "deviceID": .string(driver.device.uuidString), "requestID": .string(UUID().uuidString)]))
        let startID = try #require(start["id"].string.flatMap(UUID.init(uuidString:))); try await completed(owner, startID)
        let descriptor = try #require(owner.descriptor), revision = try #require(owner.frame?.revision)
        let id = UUID()
        let result = try await facade.handle(.init(method: "simulator_ui_action", parameters: ["context": context, "sessionID": .string(descriptor.id.uuidString), "requestID": .string(id.uuidString), "revision": .number(Double(revision)), "action": .object(["type": .string("text"), "text": .string("PRIVATE-ALIAS-TEXT")])]))
        #expect(result["kind"].string == "action"); try await completed(owner, id)
        #expect(driver.calls.filter { $0 == "perform" }.count == 1); #expect(!driver.calls.contains("close")); #expect(owner.descriptor?.id == descriptor.id)
        let metadata = try await facade.handle(.init(method: "get_state"))
        #expect(!String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self).contains("PRIVATE-ALIAS-TEXT"))
    }
    @Test func staleRevisionAndChangedCheckoutDoNotReachApple() async throws {
        let (owner, driver, project, path) = fixture(); defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let record = try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device)
        owner.currentProject = { ProjectContext(path: project.path, branch: "changed") }; owner.start(record); try await completed(owner, record.id)
        #expect(driver.calls.isEmpty); #expect(owner.records.last?.status == .failed)
        owner.currentProject = { project }
        let second = try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device); owner.start(second); try await completed(owner, second.id)
        let id = try #require(owner.descriptor?.id)
        await #expect(throws: AppleSimulatorError.arguments) { try await owner.submit(id: UUID(), kind: .action, project: project, device: driver.device, sessionID: id, action: .home, revision: 0) }
        #expect(!driver.calls.contains("perform"))
    }
}
