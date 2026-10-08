//
//  SimulatorBridge.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation

/// Persisted queue metadata deliberately excludes commands, typed text, Apple keys and artifact paths.
public struct SimulatorActivity: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case start, install, action, refresh, close }
    public let id: UUID
    public let project: ProjectContext
    public let developer: String
    public let deviceID: UUID
    public let sessionID: UUID?
    public let kind: Kind
    public let createdAt: Date
    public var status: BuildStatus = .queued
    public var queueReleased = false
    public var errorCode: String?
    public var profileID: String?
    public var profileRevision: String?
    /// Device-only views carry no checkout execution authority; legacy project is a queue-display adapter.
    public var deviceOnly: Bool?
    public init(id: UUID, project: ProjectContext, developer: String, deviceID: UUID, sessionID: UUID?, kind: Kind, createdAt: Date = Date()) {
        self.id = id; self.project = project; self.developer = developer; self.deviceID = deviceID; self.sessionID = sessionID; self.kind = kind; self.createdAt = createdAt
    }
    public var holdsQueue: Bool { status == .preparing || status == .running || status == .unknown && !queueReleased }
    public var metadata: BridgeValue {
        .object(["profileID": profileID.map(BridgeValue.string) ?? .null, "profileRevision": profileRevision.map(BridgeValue.string) ?? .null, "id": .string(id.uuidString), "kind": .string(kind.rawValue), "status": .string(status.rawValue), "deviceID": .string(deviceID.uuidString), "sessionID": sessionID.map { .string($0.uuidString) } ?? .null, "createdAt": .string(createdAt.ISO8601Format()), "queueReleased": .bool(queueReleased), "errorCode": errorCode.map(BridgeValue.string) ?? .null])
    }
}

/// The private UI observation is routed in MCP _meta; only explicit observe_simulator exposes it to the model.
public enum SimulatorBridge {
    public static let tools = ["get_simulator_configuration", "start_simulator_session", "install_simulator_app", "perform_simulator_action", "observe_simulator", "close_simulator_session", "get_simulator_activity", "refresh_simulator_screen"]
    public static let viewerTools = ["simulator_ui_devices", "simulator_ui_viewer_action", "simulator_ui_authorize", "simulator_ui_attach", "simulator_ui_detach", "simulator_ui_viewer_heartbeat", "simulator_ui_frame", "simulator_ui_video", "simulator_ui_video_stop", "simulator_ui_video_poll", "simulator_ui_video_size", "simulator_ui_masks", "simulator_ui_input", "simulator_ui_input_event", "simulator_ui_input_cancel"]
    public static let appTools = viewerTools + ["simulator_ui_action", "simulator_ui_observe", "simulator_ui_heartbeat", "simulator_ui_release_unknown"]
    public static func action(_ value: BridgeValue) throws -> AppleSimulatorAction {
        guard let fields = value.object, let kind = value["type"].string else { throw AppleSimulatorError.arguments }
        func exact(_ names: Set<String>) throws { guard Set(fields.keys) == names.union(["type"]) else { throw AppleSimulatorError.arguments } }
        func number(_ key: String) throws -> Double { guard case let .number(n) = value[key], n.isFinite else { throw AppleSimulatorError.arguments }; return n }
        let result: AppleSimulatorAction
        switch kind {
        case "tap": try exact(["x", "y"]); result = try .tap(x: number("x"), y: number("y"))
        case "swipe": try exact(["x", "y", "endX", "endY", "duration"]); result = try .swipe(x: number("x"), y: number("y"), endX: number("endX"), endY: number("endY"), duration: number("duration"))
        case "text": try exact(["text"]); guard let text = value["text"].string else { throw AppleSimulatorError.arguments }; result = .text(text)
        case "key": try exact(["key"]); guard let key = value["key"].string.flatMap(AppleSimulatorAction.Key.init(rawValue:)) else { throw AppleSimulatorError.arguments }; result = .key(key)
        case "home": try exact([]); result = .home
        case "orientation": try exact(["orientation"]); guard let orientation = value["orientation"].string.flatMap(AppleSimulatorAction.Orientation.init(rawValue:)) else { throw AppleSimulatorError.arguments }; result = .orientation(orientation)
        default: throw AppleSimulatorError.arguments
        }
        _ = try result.command(); return result
    }
}
