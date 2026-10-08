//
//  SimulatorVideoPacketsTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 07.10.2026.
import Foundation
import Testing
import MimicCore

struct SimulatorVideoPacketsTests {
    private func add(_ range: ClosedRange<UInt64>, to history: inout SimulatorVideoPackets, size: Int = 32) {
        for sequence in range { history.append(sequence: sequence, data: Data(repeating: UInt8(sequence % 256), count: size), keyframe: sequence % 30 == 1) }
    }
    @Test func overlappingPollsReserveDistinctPacketsForEachViewer() {
        var history = SimulatorVideoPackets(); add(1...6, to: &history)
        let first = history.read(after: 0, reservation: "viewer-a")
        #expect(first.packets.count == 6 && !first.needsKeyframe)
        #expect(history.read(after: 0, reservation: "viewer-a").packets.isEmpty)
        #expect(history.read(after: 0, reservation: "viewer-b").packets == first.packets)
        add(7...8, to: &history)
        #expect(history.read(after: 0, reservation: "viewer-a").packets.count == 2)
        #expect(history.read(after: 6, reservation: "viewer-a").packets.isEmpty)
        history.removeReservation("viewer-a")
        #expect(history.read(after: 0, reservation: "replacement-grant").packets.count == 8)
        #expect(history.read(after: 0, reservation: nil).packets.count == 8)
        #expect(history.read(after: 0, reservation: nil).packets.count == 8)
    }
    @Test func boundedHistoryAndBatchRecoverAtKeyframe() {
        var history = SimulatorVideoPackets(); add(1...80, to: &history)
        let recovered = history.read(after: 1, reservation: "a")
        #expect(!recovered.needsKeyframe && recovered.packets.count == 12)
        #expect(Data(base64Encoded: recovered.packets[0])?.first == 61)
        #expect(history.read(after: 1, reservation: "a").packets.count == 8)
        var gap = SimulatorVideoPackets(); add(2...6, to: &gap)
        #expect(gap.read(after: 0, reservation: "a").needsKeyframe)
        var large = SimulatorVideoPackets(); add(1...6, to: &large, size: 200_000)
        #expect(large.read(after: 0, reservation: "a").packets.count == 2)
        #expect(large.read(after: 0, reservation: "a").packets.count == 2)
    }
}
