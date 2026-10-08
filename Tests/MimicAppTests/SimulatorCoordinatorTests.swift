//
//  SimulatorCoordinatorTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Combine
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
    var failClose = false
    var captureFailure: AppleSimulatorError?
    var authorizedWorkspaces: [URL] = []
    var onAuthorize: (() -> Void)?
    var pauseCapture = false
    var captureContinuation: CheckedContinuation<Void, Never>?
    init(device: UUID) { self.device = device }
    func connect(developerDirectory: String) async throws { calls.append("connect") }
    func authorize(workspace: URL) async throws { calls.append("authorize"); authorizedWorkspaces.append(workspace); onAuthorize?() }
    func startSession(deviceID: UUID, workspace: URL?) async throws -> AppleSimulatorDescriptor {
        calls.append("start")
        let device = deviceID
        let session = AppleSimulatorSession { _, _ in .object(["deviceUUID": .string(device.uuidString), "deviceIsSimulator": .bool(true), "interactionSessionKey": .string("fixture-secret")]) }
        let descriptor = try await session.start(deviceID: deviceID, workspace: workspace); self.descriptor = descriptor; return descriptor
    }
    func capture(_ id: UUID) async throws -> SimulatorFrame {
        calls.append("capture")
        if pauseCapture { await withCheckedContinuation { captureContinuation = $0 } }
        if let captureFailure { throw captureFailure }
        revision += 1; return frame(id)
    }
    func perform(_ id: UUID, action: AppleSimulatorAction, revision: UInt64) async throws -> SimulatorFrame { calls.append("perform"); if failAction { throw AppleSimulatorError.connectionLost }; self.revision += 1; return frame(id) }
    func install(_ id: UUID) async throws { calls.append("install") }
    func close(_ id: UUID) async throws { calls.append("close"); if failClose { throw AppleSimulatorError.connectionLost } }
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
    @Test func failedCloseDisconnectsAndAllowsNewSession() async throws {
        let (owner, driver, project, path) = fixture(); defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let start = try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device)
        owner.start(start); try await completed(owner, start.id)
        driver.failClose = true
        let close = try await owner.submit(id: UUID(), kind: .close, project: project, device: driver.device, sessionID: try #require(owner.descriptor?.id))
        owner.start(close); try await completed(owner, close.id)
        #expect(owner.activity(close.id)?.status == .failed)
        #expect(owner.activity(close.id)?.errorCode == "connectionLost")
        #expect(!owner.busy && owner.descriptor == nil)
        #expect(driver.calls.suffix(2) == ["close", "disconnect"])
        let next = try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device)
        owner.start(next); try await completed(owner, next.id)
        #expect(owner.activity(next.id)?.status == .succeeded)
        #expect(driver.calls.filter { $0 == "start" }.count == 2)
    }
    @Test func failedExitCloseDoesNotBlockQueueAfterRestart() async throws {
        let (owner, driver, project, path) = fixture(); defer { try? FileManager.default.removeItem(at: path) }
        let start = try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device)
        owner.start(start); try await completed(owner, start.id)
        driver.failClose = true; owner.stop()
        for _ in 0..<200 { if owner.canExit { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(owner.canExit)
        #expect(owner.records.last?.kind == .close && owner.records.last?.status == .failed)
        #expect(driver.calls.suffix(2) == ["close", "disconnect"])
        let restored = SimulatorCoordinator(directory: path)
        #expect(!restored.busy)
        #expect(restored.records.last?.status == .failed)
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
    @Test func checkoutViewerManualActionUsesPinnedOwnerAndRejectsHiddenViewer() async throws {
        let (owner, driver, project, path) = fixture()
        let suite = "MimicViewerAction-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { owner.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: path) }
        let workspace = path.appendingPathComponent("Access.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try owner.rememberAccess(workspace: workspace, developer: project.developerDirectory!)
        let model = TaskCoordinator(directory: path, simulatorCoordinator: owner, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path
        let facade = MimicIntegration(model: model, defaults: defaults), viewer = UUID()
        let attached = try await owner.attachViewer(viewer, thread: "", project: project, device: driver.device, request: UUID())
        let startID = try #require(attached["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
        owner.start(try #require(owner.activity(startID))); try await completed(owner, startID)
        let actionID = UUID()
        let parameters: [String: BridgeValue] = ["viewerID": .string(viewer.uuidString), "requestID": .string(actionID.uuidString), "revision": .number(1), "action": .object(["type": .string("home")])]
        let result = try await facade.handle(.init(method: "simulator_ui_viewer_action", parameters: parameters))
        #expect(result["id"].string == actionID.uuidString)
        let action = try #require(owner.activity(actionID)); #expect(action.deviceOnly == true)
        owner.start(action); try await completed(owner, actionID)
        #expect(driver.calls.filter { $0 == "perform" }.count == 1)
        _ = try owner.viewerHeartbeat(viewer, thread: "", visible: false)
        await #expect(throws: AppleSimulatorError.occupied) { try await facade.handle(.init(method: "simulator_ui_viewer_action", parameters: parameters)) }
        #expect(driver.calls.filter { $0 == "perform" }.count == 1)
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

    @Test func sharedViewersKeepIndependentLeasesAndPassiveFramesDoNotInvalidateCommands() async throws {
        let (owner, driver, project, path) = fixture()
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let workspace = path.appendingPathComponent("Access.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try owner.rememberAccess(workspace: workspace, developer: project.developerDirectory!)
        let first = UUID(), second = UUID()
        let attached = try await owner.attachViewer(first, thread: "first", project: project, device: driver.device, request: UUID())
        let activityID = try #require(attached["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
        owner.start(try #require(owner.activity(activityID))); try await completed(owner, activityID)
        let shared = try await owner.attachViewer(second, thread: "second", project: project, device: driver.device, request: UUID())
        #expect(shared["activity"] == .null)
        let initial = owner.viewerMetadata(thread: "first", project: project)
        let sessionID = try #require(initial["session"]["id"].string.flatMap(UUID.init(uuidString:)))
        let revision = try #require(initial["session"]["revision"].integer)
        let frame = try await owner.viewerObservation(first, thread: "first", refresh: true)
        #expect(frame["revision"].integer == revision)
        #expect(driver.calls.filter { $0 == "start" }.count == 1)
        #expect(driver.calls.filter { $0 == "capture" }.count == 2)
        owner.detachViewer(first, thread: "first")
        #expect(owner.viewerMetadata(thread: "second", project: project)["session"]["id"].string == sessionID.uuidString)
        #expect(!driver.calls.contains("close"))
        #expect(throws: AppleSimulatorError.noSession) { try owner.viewerHeartbeat(second, thread: "foreign", visible: false) }
        let action = try await owner.submit(id: UUID(), kind: .action, project: project, device: driver.device, sessionID: sessionID, action: .tap(x: 5, y: 5), revision: UInt64(revision))
        owner.start(action); try await completed(owner, action.id)
        #expect(driver.calls.filter { $0 == "perform" }.count == 1)
        #expect(owner.viewerMetadata(thread: "second", project: project)["session"]["revision"].integer == revision + 1)
    }

    @Test(arguments: [AppleSimulatorError.connectionLost, .noSession, .invalidResponse])
    func failedPassiveCaptureRetiresSessionAndExplicitAttachReconnects(failure: AppleSimulatorError) async throws {
        let (owner, driver, project, path) = fixture()
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let workspace = path.appendingPathComponent("Access.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try owner.rememberAccess(workspace: workspace, developer: project.developerDirectory!)
        let viewer = UUID()
        let attached = try await owner.attachViewer(viewer, thread: "first", project: project, device: driver.device, request: UUID())
        let activityID = try #require(attached["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
        owner.start(try #require(owner.activity(activityID))); try await completed(owner, activityID)
        let original = try #require(owner.viewerMetadata(thread: "first", project: project)["session"]["id"].string)
        driver.captureFailure = failure
        await #expect(throws: failure) { try await owner.viewerObservation(viewer, thread: "first", refresh: true) }
        #expect(owner.viewerMetadata(thread: "first", project: project)["session"] == .null)
        #expect(driver.calls.filter { $0 == "disconnect" }.count == 1)
        #expect(!driver.calls.contains("perform") && !driver.calls.contains("close"))
        driver.captureFailure = nil
        let replacement = try await owner.attachViewer(viewer, thread: "first", project: project, device: driver.device, request: UUID())
        let replacementID = try #require(replacement["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
        owner.start(try #require(owner.activity(replacementID))); try await completed(owner, replacementID)
        let fresh = try await owner.viewerObservation(viewer, thread: "first", refresh: true)
        let replacementSession = try #require(fresh["sessionID"].string)
        #expect(replacementSession != original)
        #expect(driver.calls.filter { $0 == "start" }.count == 2)
    }

    @Test func busyPassiveCaptureKeepsHealthySession() async throws {
        let (owner, driver, project, path) = fixture()
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let workspace = path.appendingPathComponent("Access.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try owner.rememberAccess(workspace: workspace, developer: project.developerDirectory!)
        let viewer = UUID()
        let attached = try await owner.attachViewer(viewer, thread: "first", project: project, device: driver.device, request: UUID())
        let activityID = try #require(attached["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
        owner.start(try #require(owner.activity(activityID))); try await completed(owner, activityID)
        let original = owner.viewerMetadata(thread: "first", project: project)["session"]["id"]
        driver.captureFailure = .occupied
        await #expect(throws: AppleSimulatorError.occupied) { try await owner.viewerObservation(viewer, thread: "first", refresh: true) }
        #expect(owner.viewerMetadata(thread: "first", project: project)["session"]["id"] == original)
        #expect(!driver.calls.contains("disconnect"))
    }

    @Test func concurrentViewersShareCaptureAndDetachedViewerRejectsLateFrame() async throws {
        let (owner, driver, project, path) = fixture()
        defer { driver.captureContinuation?.resume(); owner.stop(); try? FileManager.default.removeItem(at: path) }
        let workspace = path.appendingPathComponent("Access.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try owner.rememberAccess(workspace: workspace, developer: project.developerDirectory!)
        let first = UUID(), second = UUID()
        let attached = try await owner.attachViewer(first, thread: "first", project: project, device: driver.device, request: UUID())
        let activityID = try #require(attached["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
        owner.start(try #require(owner.activity(activityID))); try await completed(owner, activityID)
        _ = try await owner.attachViewer(second, thread: "second", project: project, device: driver.device, request: UUID())
        let revision = owner.viewerMetadata(thread: "second", project: project)["session"]["revision"]
        let suite = "BranchCapture-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TaskCoordinator(directory: path.appendingPathComponent("model"), simulatorCoordinator: owner, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path; model.gitSummary = GitSummary(porcelain: "")
        model.expandedSection = .branches; model.branchSearch = "target"
        #expect(model.canSwitchBranch, "An idle simulator session does not own the checkout queue")
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        driver.pauseCapture = true
        let firstFrame = Task { try await owner.viewerObservation(first, thread: "first", refresh: true) }
        while driver.captureContinuation == nil { await Task.yield() }
        #expect(changes > 0 && model.branchSwitchBlocker == .simulator)
        #expect(!model.canSwitchBranch && !model.switchBranch("target"))
        #expect(model.expandedSection == .branches && model.branchSearch == "target")
        #expect(model.branchError == BranchSwitchBlocker.simulator.message)
        #expect(model.branchSwitch.operations.isEmpty)
        let beforeCaptureFinished = changes
        var secondStarted = false
        let secondFrame = Task { secondStarted = true; return try await owner.viewerObservation(second, thread: "second", refresh: true) }
        while !secondStarted { await Task.yield() }
        #expect(driver.calls.filter { $0 == "capture" }.count == 2)
        owner.detachViewer(first, thread: "first")
        driver.pauseCapture = false; driver.captureContinuation?.resume(); driver.captureContinuation = nil
        await #expect(throws: AppleSimulatorError.noSession) { try await firstFrame.value }
        let frame = try await secondFrame.value
        #expect(frame["revision"] == revision)
        #expect(driver.calls.filter { $0 == "capture" }.count == 2)
        #expect(!driver.calls.contains("close"))
        #expect(!owner.busy)
        #expect(changes > beforeCaptureFinished && model.canSwitchBranch)
    }

    @Test func independentDevicesAndRestartedChildUnknownRemainDiscoverable() async throws {
        let path = URL(fileURLWithPath: "/private/tmp/MimicMultiSimulatorTests-" + UUID().uuidString)
        let first = UUID(), second = UUID(), project = ProjectContext(path: path.path, branch: "fixture", commit: "fixture-sha", developerDirectory: "/fixture/Developer")
        var drivers: [SimulatorDriverFixture] = []
        let owner = SimulatorCoordinator(directory: path, supports: { _ in true }, makeDriver: { let driver = SimulatorDriverFixture(device: UUID()); drivers.append(driver); return driver }, inspect: { $0 }, catalogue: { _ in [first,second].map { .init(id: $0, name: "iPhone", runtime: "iOS 27", state: "Booted") } })
        owner.currentProject = { project }
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let workspace = path.appendingPathComponent("Access.xcworkspace"); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try owner.rememberAccess(workspace: workspace, developer: project.developerDirectory!)
        for (device, thread) in [(first,"first"),(second,"second")] {
            let result = try await owner.attachViewer(UUID(), thread: thread, project: project, device: device, request: UUID())
            let id = try #require(result["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
            owner.start(try #require(owner.activity(id))); try await completed(owner, id)
        }
        #expect(drivers.count == 2)
        let one = owner.viewerMetadata(thread: "first", project: project), two = owner.viewerMetadata(thread: "second", project: project)
        #expect(one["session"]["deviceID"].string == first.uuidString)
        #expect(two["session"]["deviceID"].string == second.uuidString)
        let session = try #require(one["session"]["id"].string.flatMap(UUID.init(uuidString:)))
        drivers[0].failAction = true
        let action = try await owner.submit(id: UUID(), kind: .action, project: project, device: first, sessionID: session, action: .home, revision: 1)
        owner.start(action); try await completed(owner, action.id)
        let restarted = SimulatorCoordinator(directory: path)
        #expect(restarted.busy)
        #expect(restarted.activity(action.id)?.status == .unknown)
        #expect(restarted.viewerMetadata(thread: "unrelated", project: project)["activities"].array?.contains { $0["id"].string == action.id.uuidString } == true)
        try await restarted.releaseUnknown(action.id)
        #expect(!restarted.busy)
    }

    @Test func heartbeatExpiryClosesOnlyAfterLastViewerLeaseWithoutStoppingDevice() async throws {
        let (owner, driver, project, path) = fixture()
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        var clock = Date(); owner.now = { clock }
        let workspace = path.appendingPathComponent("Access.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try owner.rememberAccess(workspace: workspace, developer: project.developerDirectory!)
        let first = UUID(), second = UUID()
        let attached = try await owner.attachViewer(first, thread: "same-chat", project: project, device: driver.device, request: UUID())
        let activityID = try #require(attached["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
        owner.start(try #require(owner.activity(activityID))); try await completed(owner, activityID)
        _ = try await owner.attachViewer(second, thread: "same-chat", project: project, device: driver.device, request: UUID())
        clock = clock.addingTimeInterval(25)
        _ = try owner.viewerHeartbeat(second, thread: "same-chat", visible: false)
        clock = clock.addingTimeInterval(10); owner.expireViewers()
        #expect(throws: AppleSimulatorError.noSession) { try owner.viewerHeartbeat(first, thread: "same-chat", visible: true) }
        let hidden = try owner.viewerHeartbeat(second, thread: "same-chat", visible: false)
        #expect(hidden["session"]["deviceID"].string == driver.device.uuidString)
        owner.detachViewer(second, thread: "same-chat")
        clock = clock.addingTimeInterval(59); await owner.expireIdleSessions()
        #expect(!owner.records.contains { $0.kind == .close })
        clock = clock.addingTimeInterval(1); await owner.expireIdleSessions()
        let close = try #require(owner.records.first { $0.kind == .close })
        owner.start(close); try await completed(owner, close.id)
        #expect(driver.calls.suffix(2) == ["close", "disconnect"])
    }

    @Test func xcode26DiscoveryNeverInvokesDeviceCatalogueOrNativeDriver() async throws {
        let path = URL(fileURLWithPath: "/private/tmp/MimicXcode26-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let contents = path.appendingPathComponent("Xcode.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Developer"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "fixture.Xcode", "CFBundleShortVersionString": "26.0", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let project = ProjectContext(path: path.path, branch: "fixture", commit: "fixture", developerDirectory: contents.appendingPathComponent("Developer").path)
        let driver = SimulatorDriverFixture(device: UUID())
        let owner = SimulatorCoordinator(directory: path, makeDriver: { driver }, inspect: { $0 }, catalogue: { _ in Issue.record("Unsupported Xcode must not enumerate devices"); return [] })
        owner.currentProject = { project }
        let config = try await owner.configuration(project: project)
        #expect(config["visible"] == .bool(false) && config["devices"].array?.isEmpty == true)
        await #expect(throws: AppleSimulatorError.unsupported) { try await owner.attachViewer(UUID(), thread: "chat", project: project, device: driver.device, request: UUID()) }
        #expect(driver.calls.isEmpty)
    }

    @Test func projectlessViewerUsesExplicitWorkspaceAndManualControlWithoutCheckoutAuthority() async throws {
        let (owner, driver, _, path) = fixture()
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        owner.currentProject = { nil }
        let developer = EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
        let workspace = path.appendingPathComponent("Access.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try owner.rememberAccess(workspace: workspace, developer: developer)
        let viewer = UUID()
        let attached = try await owner.attachViewer(viewer, thread: "projectless", project: nil, device: driver.device, request: UUID())
        let startID = try #require(attached["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
        let start = try #require(owner.activity(startID)); #expect(start.deviceOnly == true && start.profileID == nil)
        owner.start(start); try await completed(owner, startID)
        #expect(try owner.viewerHeartbeat(viewer, thread: "projectless", visible: true)["session"]["deviceID"].string == driver.device.uuidString)
        let action = try owner.viewerAction(viewer, thread: "projectless", request: UUID(), action: .tap(x: 5, y: 5), revision: 1)
        let id = try #require(action["id"].string.flatMap(UUID.init(uuidString:)))
        owner.start(try #require(owner.activity(id))); try await completed(owner, id)
        #expect(driver.calls.filter { $0 == "perform" }.count == 1)
        #expect(!driver.calls.contains("install"))
    }

    @Test func installationRechecksPinnedProfileImmediatelyBeforeNativeExecution() async throws {
        let (owner, driver, project, path) = fixture()
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let profile = try JSONDecoder().decode(MimicProfile.self, from: Data(#"{"schemaVersion":1,"id":"fixture","version":"1","title":"Fixture","requiredFiles":[],"actions":[]}"#.utf8))
        var snapshot = ProfileSnapshot(profile: profile, revision: "one", directory: path.path)
        owner.currentProfile = { snapshot }
        let start = try await owner.submit(id: UUID(), kind: .start, project: project, device: driver.device)
        owner.start(start); try await completed(owner, start.id)
        #expect(owner.metadata["session"]["context"]["profileID"].string == "fixture")
        #expect(owner.metadata["session"]["context"]["profileRevision"].string == "one")
        let install = try await owner.submit(id: UUID(), kind: .install, project: project, device: driver.device, sessionID: try #require(owner.descriptor?.id))
        snapshot = ProfileSnapshot(profile: profile, revision: "two", directory: path.path)
        owner.start(install); try await completed(owner, install.id)
        #expect(owner.activity(install.id)?.status == .failed)
        #expect(owner.activity(install.id)?.errorCode == "context")
        #expect(!driver.calls.contains("install"))
    }

    @Test func sharedDeviceInstallRebindsToCurrentChatWorkspaceAndRejectsAuthorizationRace() async throws {
        let (owner, driver, project, path) = fixture()
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let access = path.appendingPathComponent("Access.xcworkspace")
        try FileManager.default.createDirectory(at: access, withIntermediateDirectories: true)
        try owner.rememberAccess(workspace: access, developer: project.developerDirectory!)
        let viewer = UUID(), attached = try await owner.attachViewer(viewer, thread: "first", project: project, device: driver.device, request: UUID())
        let startID = try #require(attached["activity"]["id"].string.flatMap(UUID.init(uuidString:)))
        owner.start(try #require(owner.activity(startID))); try await completed(owner, startID)
        let session = try #require(owner.viewerHeartbeat(viewer, thread: "first", visible: true)["session"]["id"].string.flatMap(UUID.init(uuidString:)))
        let install = try await owner.submit(id: UUID(), kind: .install, project: project, device: driver.device, sessionID: session)
        owner.start(install); try await completed(owner, install.id)
        #expect(owner.activity(install.id)?.status == .succeeded)
        #expect(driver.authorizedWorkspaces.last?.path == project.workspace)

        let other = ProjectContext(path: path.path, branch: project.branch, commit: project.commit, developerDirectory: project.developerDirectory, appleTarget: AppleTarget(path: "Other.xcworkspace"))
        owner.currentProject = { other }
        let nextSession = try #require(owner.viewerHeartbeat(viewer, thread: "first", visible: true)["session"]["id"].string.flatMap(UUID.init(uuidString:)))
        let second = try await owner.submit(id: UUID(), kind: .install, project: other, device: driver.device, sessionID: nextSession)
        owner.start(second); try await completed(owner, second.id)
        #expect(owner.activity(second.id)?.status == .succeeded)
        #expect(driver.authorizedWorkspaces.last?.path == other.workspace)
        #expect(driver.calls.filter { $0 == "install" }.count == 2)

        owner.currentProject = { project }
        let finalSession = try #require(owner.viewerHeartbeat(viewer, thread: "first", visible: true)["session"]["id"].string.flatMap(UUID.init(uuidString:)))
        let raced = try await owner.submit(id: UUID(), kind: .install, project: project, device: driver.device, sessionID: finalSession)
        driver.onAuthorize = { owner.currentProject = { other } }
        owner.start(raced); try await completed(owner, raced.id)
        #expect(owner.activity(raced.id)?.status == .failed)
        #expect(owner.activity(raced.id)?.errorCode == "context")
        #expect(driver.calls.filter { $0 == "install" }.count == 2)
    }

}
