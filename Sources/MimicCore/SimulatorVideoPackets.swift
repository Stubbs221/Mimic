//
//  SimulatorVideoPackets.swift
//  MimicCore
//
//  Created by Василий Маслов on 07.10.2026.
import Foundation

/// Bounded encoded history shared by viewers. Reservations avoid retransmitting a batch
/// while earlier MCP responses are still in flight; each grant gets a fresh reservation.
public struct SimulatorVideoPackets {
    private struct Packet { let sequence: UInt64; let bytes: Int; let keyframe: Bool; let encoded: String }
    private var packets: [Packet] = []
    private var bytes = 0
    private var reservations: [String: UInt64] = [:]
    private var awaitingKeyframes: Set<String> = []
    public init() {}

    /// Encode once at ingress, rather than once for every viewer and overlapping poll.
    public mutating func append(sequence: UInt64, data: Data, keyframe: Bool) {
        guard data.count <= 512_000, packets.last.map({ sequence > $0.sequence }) ?? true else { return }
        packets.append(.init(sequence: sequence, bytes: data.count, keyframe: keyframe, encoded: data.base64EncodedString()))
        bytes += data.count
        while packets.count > 45 || bytes > 1_500_000 { bytes -= packets.removeFirst().bytes }
    }
    /// A new subscription starts after the current history, so it waits for a
    /// freshly requested IDR instead of replaying an old GOP.
    public mutating func beginReservation(_ token: String) { reservations[token] = packets.last?.sequence ?? 0; awaitingKeyframes.insert(token) }
    public mutating func removeReservation(_ token: String) { reservations[token] = nil; awaitingKeyframes.remove(token) }

    /// A nil reservation preserves stateless delivery for an older, already-open panel.
    /// Missing history resumes at the latest IDR; packet and batch wire limits stay unchanged.
    public mutating func read(after: UInt64, reservation: String?) -> (packets: [String], needsKeyframe: Bool) {
        let cursor = max(after, reservation.flatMap { reservations[$0] } ?? 0)
        var available = packets.filter { $0.sequence > cursor }
        if reservation.map({ awaitingKeyframes.contains($0) }) == true || cursor == 0 || available.first.map({ $0.sequence != cursor + 1 }) == true {
            guard let index = available.lastIndex(where: \.keyframe) else { return ([], true) }
            available = Array(available[index...]); if let reservation { awaitingKeyframes.remove(reservation) }
        }
        var result: [String] = [], size = 0, last = cursor
        for packet in available.prefix(12) {
            guard size + packet.bytes <= 450_000 else { break }
            result.append(packet.encoded); size += packet.bytes; last = packet.sequence
        }
        if let reservation { reservations[reservation] = last }
        return (result, false)
    }
}
