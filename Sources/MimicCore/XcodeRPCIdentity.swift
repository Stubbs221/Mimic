// Created by Василий Маслов on 04.10.2026.
import Foundation

/// Xcode 26.5's mcpbridge ignores string JSON-RPC IDs. Only the wire identity is adapted.
public struct XcodeRPCIdentity: Sendable {
    private var sequence = 1_000_000
    private var originals: [Int: String] = [:]
    public init() { }
    public mutating func outgoing(_ data: Data) throws -> Data {
        var object = try JSONDecoder().decode([String: BridgeValue].self, from: data)
        if object["method"]?.string != nil, let original = object["id"]?.string {
            guard originals.count < 1000 else { throw BuildError.capacity }
            sequence += 1; originals[sequence] = original; object["id"] = .number(Double(sequence))
        }
        return try JSONEncoder().encode(object)
    }
    public mutating func incoming(_ data: Data) throws -> Data {
        var object = try JSONDecoder().decode([String: BridgeValue].self, from: data)
        if object["method"] == nil, let id = object["id"]?.integer, let original = originals.removeValue(forKey: id) { object["id"] = .string(original) }
        return try JSONEncoder().encode(object)
    }
}
