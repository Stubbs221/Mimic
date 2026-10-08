//
//  SimulatorContinuousInputTests.swift
//  MimicTests
//
//  Created by Василий Маслов on 08.10.2026.
import Foundation
import MimicCore
import Testing
@testable import AppleSimulatorMCP
@testable import Mimic

@MainActor private final class TouchDriverFixture: SimulatorInputDriver {
    var onFailure: (() -> Void)?
    var stopped = true
    var fail = false
    var delayStop = false
    var phases: [SimulatorTouchEvent.Phase] = []
    func start(device: UUID, developer: String) async throws { stopped = false }
    func send(phase: SimulatorTouchEvent.Phase, gesture: UUID, x: Double, y: Double, timestamp: Double) async throws {
        phases.append(phase)
        if fail { throw AppleSimulatorError.connectionLost }
    }
    func stop() async { while delayStop { try? await Task.sleep(for: .milliseconds(5)) }; stopped = true }
}

@MainActor private final class TouchAppleFixture: SimulatorNativeDriver {
    let device = UUID()
    var performed = 0
    func connect(developerDirectory: String) async throws {}
    func authorize(workspace: URL) async throws {}
    func startSession(deviceID: UUID, workspace: URL?) async throws -> AppleSimulatorDescriptor {
        let session = AppleSimulatorSession { [device] _, _ in .object(["deviceUUID": .string(device.uuidString), "deviceIsSimulator": .bool(true), "interactionSessionKey": .string("fixture")]) }
        return try await session.start(deviceID: deviceID, workspace: workspace)
    }
    func capture(_ id: UUID) async throws -> SimulatorFrame { .init(sessionID: id, revision: 1, width: 402, height: 874, jpeg: Data([1]), hierarchy: "", targets: [], applicationState: "Running") }
    func perform(_ id: UUID, action: AppleSimulatorAction, revision: UInt64) async throws -> SimulatorFrame { performed += 1; return try await capture(id) }
    func install(_ id: UUID) async throws {}
    func close(_ id: UUID) async throws {}
    func disconnect() async {}
}

@MainActor struct SimulatorContinuousInputTests {
    private func fixture() async throws -> (SimulatorCoordinator, TouchDriverFixture, TouchAppleFixture, ProjectContext, UUID, BridgeValue, URL) {
        let path = URL(fileURLWithPath: "/private/tmp/MimicTouchTests-" + UUID().uuidString)
        let workspace = path.appendingPathComponent("Fixture.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let apple = TouchAppleFixture(), input = TouchDriverFixture()
        let device = apple.device
        let project = ProjectContext(path: path.path, branch: "fixture", commit: "fixture", developerDirectory: "/fixture/Xcode27/Contents/Developer", appleTarget: AppleTarget(path: "Fixture.xcworkspace"))
        let owner = SimulatorCoordinator(directory: path, supports: { _ in true }, makeDriver: { apple }, inspect: { $0 }, catalogue: { _ in [.init(id: device, name: "Fixture", runtime: "iOS 27", state: "Booted")] }, makeInput: { input })
        owner.currentProject = { project }
        try owner.rememberAccess(workspace: workspace, developer: project.developerDirectory!)
        let record = try await owner.submit(id: UUID(), kind: .start, project: project, device: apple.device)
        owner.start(record)
        for _ in 0..<200 { if owner.activity(record.id)?.status == .succeeded { break }; try await Task.sleep(for: .milliseconds(5)) }
        let viewer = UUID()
        _ = try await owner.attachViewer(viewer, thread: "fixture", project: project, device: apple.device, request: UUID())
        let access = try await owner.inputAccess(viewer, thread: "fixture")
        return (owner, input, apple, project, viewer, access, path)
    }
    private func event(_ access: BridgeValue, _ phase: String, _ sequence: Int, gesture: UUID, x: Double = 100, y: Double = 200) throws -> SimulatorTouchEvent {
        try SimulatorTouchEvent(.object(["sessionID": access["sessionID"], "generation": access["generation"], "gestureID": .string(gesture.uuidString), "phase": .string(phase), "sequence": .number(Double(sequence)), "x": .number(x), "y": .number(y), "timestamp": .number(123)]))
    }
    @Test func touchOwnsFIFOAndRejectsAppleAndOutOfOrderEvents() async throws {
        let (owner, input, apple, project, viewer, access, path) = try await fixture()
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        let gesture = UUID()
        _ = try await owner.inputEvent(viewer, thread: "fixture", event: event(access, "down", 1, gesture: gesture))
        #expect(owner.busy)
        #expect(owner.viewerMetadata(thread: "fixture", project: project)["inputOwner"].string == viewer.uuidString)
        await #expect(throws: AppleSimulatorError.occupied) { try await owner.submit(id: UUID(), kind: .action, project: project, device: apple.device, sessionID: owner.descriptor?.id, action: .home, revision: 1) }
        await #expect(throws: AppleSimulatorError.arguments) { try await owner.inputEvent(viewer, thread: "fixture", event: event(access, "move", 3, gesture: gesture)) }
        _ = try await owner.inputEvent(viewer, thread: "fixture", event: event(access, "move", 2, gesture: gesture))
        _ = try await owner.inputEvent(viewer, thread: "fixture", event: event(access, "up", 3, gesture: gesture))
        #expect(!owner.busy && apple.performed == 0)
        #expect(input.phases == [.down, .move, .up])
        #expect(owner.frame == nil, "HID changes invalidate the old Apple observation")
    }
    @Test func hiddenViewerKeepsQueueUntilHelperExitAndInvalidatesGrant() async throws {
        let (owner, input, _, _, viewer, access, path) = try await fixture()
        defer { input.delayStop = false; owner.stop(); try? FileManager.default.removeItem(at: path) }
        let gesture = UUID()
        _ = try await owner.inputEvent(viewer, thread: "fixture", event: event(access, "down", 1, gesture: gesture))
        input.delayStop = true
        _ = try owner.viewerHeartbeat(viewer, thread: "fixture", visible: false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(owner.busy)
        input.delayStop = false
        for _ in 0..<100 { if !owner.busy { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(!owner.busy && input.stopped)
        _ = try owner.viewerHeartbeat(viewer, thread: "fixture", visible: true)
        await #expect(throws: AppleSimulatorError.noSession) { try await owner.inputEvent(viewer, thread: "fixture", event: event(access, "move", 2, gesture: gesture)) }
    }
    @Test func uncertainSendIsNotReplayedAndRetiresHelper() async throws {
        let (owner, input, _, _, viewer, access, path) = try await fixture()
        defer { owner.stop(); try? FileManager.default.removeItem(at: path) }
        input.fail = true
        await #expect(throws: AppleSimulatorError.connectionLost) { try await owner.inputEvent(viewer, thread: "fixture", event: event(access, "down", 1, gesture: UUID())) }
        for _ in 0..<100 { if !owner.busy { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(input.stopped && input.phases == [.down] && !owner.busy)
    }
}
