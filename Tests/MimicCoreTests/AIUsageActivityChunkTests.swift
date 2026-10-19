//
//  AIUsageActivityChunkTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 12.10.2026.
import Foundation
import Testing
@testable import MimicCore

@Suite
struct AIUsageActivityChunkTests {
    /// Padding moves records across read boundaries without changing their usage metadata.
    @Test(arguments: [1_048_496, 1_048_576, 2_097_232])
    func chunkedColdWarmAndAppendMatchCompactLogs(padding: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageChunks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(AIUsageDecoder.date("2026-10-12T15:00:00Z"))
        let compact = AIUsageLocations(home: root.appendingPathComponent("compact"), environment: [:])
        let chunked = AIUsageLocations(home: root.appendingPathComponent("chunked"), environment: [:])
        let scanners = [compact, chunked].map {
            AIUsageActivityScanner(locations: $0, pricing: AIUsagePricingStore(directory: root.appendingPathComponent("pricing")))
        }
        let context = #"{"type":"turn_context","payload":{"model":"gpt-5"}}"#
        let first = #"{"type":"event_msg","timestamp":"2026-10-12T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"#
        let second = #"{"type":"event_msg","timestamp":"2026-10-12T12:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"output_tokens":10,"total_tokens":30}}}}"#
        let claude = #"{"type":"assistant","timestamp":"2026-10-12T11:00:00Z","message":{"role":"assistant","id":"fixture","model":"claude-sonnet-4-20250514","usage":{"input_tokens":7,"output_tokens":2}}}"#
        for (index, locations) in [compact, chunked].enumerated() {
            let codexFile = locations.codex.appendingPathComponent("sessions/main.jsonl")
            let claudeFile = locations.claude.appendingPathComponent("projects/main.jsonl")
            for file in [codexFile, claudeFile] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            // Ignored service records and oversized usage records must not affect the result.
            let service = index == 0 ? "" : String(repeating: " ", count: padding) + "\n"
            let oversized = index == 0 ? "" : String(second.dropLast()) + ",\"ignored\":\"" + String(repeating: "x", count: 2 * 1024 * 1024) + "\"}\n"
            try (context + "\n" + service + first + "\n" + oversized + "malformed\n" + second).write(to: codexFile, atomically: true, encoding: .utf8)
            try (service + claude + "\n").write(to: claudeFile, atomically: true, encoding: .utf8)
        }
        let cold = await scanners[0].scanUsage(now: now, refreshPricing: false)
        #expect(await scanners[1].scanUsage(now: now, refreshPricing: false) == cold)
        #expect(cold.histories[.codex]?.map(\.tokens).reduce(0, +) == 15)
        #expect(cold.histories[.claude]?.map(\.tokens).reduce(0, +) == 9)
        #expect(cold.activity?.provider == .claude)
        for scanner in scanners { #expect(await scanner.scanUsage(now: now, refreshPricing: false) == cold) }

        // The trailing record remains owned by its cursor after the read pool drains.
        for locations in [compact, chunked] {
            let handle = try FileHandle(forWritingTo: locations.codex.appendingPathComponent("sessions/main.jsonl"))
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data("\n".utf8))
        }
        let appended = await scanners[0].scanUsage(now: now, refreshPricing: false)
        #expect(await scanners[1].scanUsage(now: now, refreshPricing: false) == appended)
        #expect(appended.histories[.codex]?.map(\.tokens).reduce(0, +) == 30)
        #expect(appended.activity?.date == AIUsageDecoder.date("2026-10-12T12:00:00Z"))
        let restarted = AIUsageActivityScanner(locations: chunked, pricing: AIUsagePricingStore(directory: root.appendingPathComponent("pricing")))
        #expect(await restarted.scanUsage(now: now, refreshPricing: false) == appended)
    }
}
