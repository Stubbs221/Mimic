//
//  TransportFramingTests.swift
//  MimicMCPTests
//
//  Created by Василий Маслов on 07.10.2026.
import Foundation
import MCP
import Testing
#if canImport(System)
import System
#else
import SystemPackage
#endif
@testable import MimicMCP

struct TransportFramingTests {
    /// Two video pipelines and heartbeat share stdout; a slow host forces partial pipe writes.
    @Test func concurrentLargeRepliesKeepJSONLinesIntact() async throws {
        let input = Pipe(), output = Pipe()
        defer {
            for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting] { try? handle.close() }
        }
        let transport = MimicInitializationTransport(stdio: StdioTransport(
            input: FileDescriptor(rawValue: input.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: output.fileHandleForWriting.fileDescriptor)))
        try await transport.connect()
        let messages = try (0..<13).map { id in
            try JSONSerialization.data(withJSONObject: ["id": id, "payload": String(repeating: id.isMultiple(of: 2) ? "A" : "B", count: id == 12 ? 32 : 180_000)])
        }
        let expectedBytes = messages.reduce(0) { $0 + $1.count + 1 }
        let reader = Task { try await Self.readSlowly(output.fileHandleForReading, count: expectedBytes) }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for message in messages { group.addTask { try await transport.send(message) } }
                try await group.waitForAll()
            }
            try output.fileHandleForWriting.close()
            let bytes = try await reader.value
            await transport.disconnect()
            let lines = bytes.split(separator: 10)
            #expect(lines.count == messages.count)
            let expected = Set(messages)
            let intact = Set(lines.map(Data.init)) == expected
            #expect(intact, "Responses must remain complete JSON lines under pipe backpressure")
        } catch {
            await transport.disconnect()
            try? output.fileHandleForWriting.close()
            _ = try? await reader.value
            throw error
        }
    }

    @concurrent private static func readSlowly(_ handle: FileHandle, count: Int) async throws -> Data {
        try await Task.sleep(for: .milliseconds(30))
        var data = Data()
        while data.count < count, let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
            data.append(chunk)
            try await Task.sleep(for: .milliseconds(1))
        }
        return data
    }
}
