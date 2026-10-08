//
//  SimulatorTouch.swift
//  MimicCore
//
//  Created by Василий Маслов on 08.10.2026.
import Foundation

/// App-only single-contact input. A geometry grant belongs to one viewer and is
/// invalidated by cancellation, device/session replacement or rotation.
public struct SimulatorTouchEvent: Sendable {
    public enum Phase: String, Sendable { case down, move, up, cancel, heartbeat }
    public let sessionID: UUID
    public let generation: UUID
    public let gestureID: UUID
    public let sequence: UInt64
    public let phase: Phase
    public let x: Double
    public let y: Double
    public let timestamp: Double

    public init(_ value: BridgeValue) throws {
        guard let fields = value.object,
              Set(fields.keys) == ["sessionID", "generation", "gestureID", "sequence", "phase", "x", "y", "timestamp"],
              let session = value["sessionID"].string.flatMap(UUID.init(uuidString:)),
              let generation = value["generation"].string.flatMap(UUID.init(uuidString:)),
              let gesture = value["gestureID"].string.flatMap(UUID.init(uuidString:)),
              let phase = value["phase"].string.flatMap(Phase.init(rawValue:)),
              case let .number(sequence) = value["sequence"], sequence >= 1, sequence <= 9_007_199_254_740_991, sequence.rounded(.down) == sequence,
              case let .number(x) = value["x"], x.isFinite, x >= 0,
              case let .number(y) = value["y"], y.isFinite, y >= 0,
              case let .number(timestamp) = value["timestamp"], timestamp.isFinite, timestamp >= 0 else { throw AppleSimulatorError.arguments }
        sessionID = session; self.generation = generation; gestureID = gesture
        self.sequence = UInt64(sequence); self.phase = phase; self.x = x; self.y = y; self.timestamp = timestamp
    }

    /// The framebuffer is physically portrait; the panel displays the oriented
    /// image. Invert that display transform before passing points to DTUHID.
    public func physicalPoint(width: Double, height: Double, orientation: String) throws -> (x: Double, y: Double) {
        guard width > 0, height > 0, x < width, y < height else { throw AppleSimulatorError.arguments }
        switch orientation {
        case "portrait": return (x, y)
        case "portraitUpsideDown": return (max(0, width - x - 0.001), max(0, height - y - 0.001))
        case "landscapeLeft": return (max(0, height - y - 0.001), x)
        case "landscapeRight": return (y, max(0, width - x - 0.001))
        default: throw AppleSimulatorError.arguments
        }
    }
}
