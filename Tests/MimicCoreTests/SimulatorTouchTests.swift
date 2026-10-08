//
//  SimulatorTouchTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 08.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct SimulatorTouchTests {
    private func payload() -> [String: BridgeValue] { ["sessionID": .string(UUID().uuidString), "generation": .string(UUID().uuidString), "gestureID": .string(UUID().uuidString), "sequence": .number(1), "phase": .string("down"), "x": .number(10), "y": .number(20), "timestamp": .number(0)] }
    @Test func malformedEventsAndOutOfBoundsAreRejected() throws {
        for key in ["sequence", "x", "y", "timestamp"] {
            for bad in [BridgeValue.null, .bool(true), .number(.infinity)] {
                var fields = payload(); fields[key] = bad
                #expect(throws: AppleSimulatorError.arguments) { try SimulatorTouchEvent(.object(fields)) }
            }
        }
        var fields = payload(); fields["sequence"] = .number(1.5)
        #expect(throws: AppleSimulatorError.arguments) { try SimulatorTouchEvent(.object(fields)) }
        let event = try SimulatorTouchEvent(.object(payload()))
        #expect(throws: AppleSimulatorError.arguments) { try event.physicalPoint(width: 10, height: 30, orientation: "portrait") }
    }
    @Test func displayRotationIsInvertedForPhysicalDigitizer() throws {
        let event = try SimulatorTouchEvent(.object(payload()))
        let portrait = try event.physicalPoint(width: 402, height: 874, orientation: "portrait")
        #expect(portrait.x == 10 && portrait.y == 20)
        let left = try event.physicalPoint(width: 874, height: 402, orientation: "landscapeLeft")
        #expect(abs(left.x - 381.999) < 0.0001 && left.y == 10)
        let right = try event.physicalPoint(width: 874, height: 402, orientation: "landscapeRight")
        #expect(right.x == 20 && abs(right.y - 863.999) < 0.0001)
    }
    @Test func newVideoSubscriptionWaitsForFreshKeyframe() {
        var packets = SimulatorVideoPackets()
        packets.append(sequence: 1, data: Data([1]), keyframe: true)
        packets.append(sequence: 2, data: Data([2]), keyframe: false)
        packets.beginReservation("new")
        #expect(packets.read(after: 0, reservation: "new").packets.isEmpty)
        packets.append(sequence: 3, data: Data([9]), keyframe: false)
        #expect(packets.read(after: 0, reservation: "new").packets.isEmpty)
        packets.append(sequence: 4, data: Data([3]), keyframe: true)
        #expect(packets.read(after: 0, reservation: "new").packets == [Data([3]).base64EncodedString()])
    }
}
