//
//  AIUsageForecastTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import os
import Testing
@testable import MimicCore

@Suite
struct AIUsagePaceTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func evaluate(_ used: Double, elapsed: Double, duration: Double = 10000) -> AIUsagePace.State {
        AIUsagePace.evaluate(window: .init(period: .session, usedPercent: used, resetsAt: self.start.addingTimeInterval(duration), duration: duration), now: self.start.addingTimeInterval(elapsed))
    }
    @Test func forecastsMatchOpenUsageAndMarkerUsesRemainingDirection() throws {
        #expect(self.evaluate(40, elapsed: 5000) == .healthy(projectedPercent: 80))
        #expect(self.evaluate(47, elapsed: 5000) == .closeToLimit(sparePercent: 6, projectedPercent: 94, tick: 0.5))
        guard case let .runningOut(deadline, projected, tick) = self.evaluate(60, elapsed: 4000) else { Issue.record("Expected run-out"); return }
        #expect(projected == 150 && tick == 0.6)
        #expect(abs(try #require(deadline).timeIntervalSince(self.start) - 6666.6666667) < 0.001)
    }
    @Test func projectionGateAndNearEmptyProtection() {
        #expect(self.evaluate(40, elapsed: 99) == .level(.normal))
        #expect(self.evaluate(40, elapsed: 59, duration: 1000) == .level(.normal))
        #expect(self.evaluate(4, elapsed: 100) == .level(.normal))
        #expect(self.evaluate(1, elapsed: 100) == .level(.normal)) // On-track, but coarse 1% reading.
        #expect(self.evaluate(0, elapsed: 5000) == .level(.normal))
        #expect(self.evaluate(85, elapsed: 10000) == .stale)
    }
    @Test func roundedCushionAndVisibleExhaustion() {
        #expect(self.evaluate(49.9, elapsed: 5000) == .runningOut(at: nil, projectedPercent: 99.8, tick: 0.5))
        #expect(self.evaluate(50, elapsed: 5000) == .runningOut(at: nil, projectedPercent: 100, tick: 0.5))
        #expect(self.evaluate(99.6, elapsed: 5000) == .spent)
        #expect(self.evaluate(100, elapsed: 1) == .spent)
        #expect(self.evaluate(150, elapsed: 1) == .spent)
    }
    @Test func missingInvalidAndStaleDataNeverForecast() {
        #expect(AIUsagePace.evaluate(window: nil, now: self.start) == .unavailable)
        #expect(AIUsagePace.evaluate(window: .init(period: .weekly, usedPercent: .nan), now: self.start) == .unavailable)
        #expect(AIUsagePace.evaluate(window: .init(period: .weekly, usedPercent: 95), now: self.start) == .level(.critical))
        #expect(AIUsagePace.evaluate(window: .init(period: .weekly, usedPercent: 100), stale: true, now: self.start) == .stale)
        #expect(AIUsagePace.evaluate(window: .init(period: .weekly, usedPercent: 85, resetsAt: self.start.addingTimeInterval(5), duration: .infinity), now: self.start) == .level(.warning))
    }
}

@Suite
struct AIUsageHistoryTests {
    @Test func calendarWindowIncludesIdleDaysAndAggregatesDuplicatesAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
        let first = try #require(calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)))
        let outside = try #require(calendar.date(byAdding: .day, value: -31, to: now))
        let points = AIUsageHistory.points(daily: [.init(date: now, tokens: 12), .init(date: now, tokens: 8), .init(date: first, tokens: 1), .init(date: outside, tokens: 1000)], now: now, calendar: calendar)
        #expect(points.count == 31 && Set(points.map(\.date)).count == 31)
        #expect(points.first?.date == first && points.first?.tokens == 1 && points.last?.tokens == 20)
        #expect(points.map(\.tokens).reduce(0, +) == 21 && points[29].tokens == 0)
        #expect(AIUsageHistory.points(daily: [.init(date: outside, tokens: 1)], now: now, calendar: calendar).isEmpty)
        #expect(AIUsageHistory.points(daily: [.init(date: now, tokens: 0)], now: now, calendar: calendar).isEmpty)
    }
    @Test func codexDeltasCopiesAndChildReplayAreCountedOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageHistory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = AIUsageLocations(home: root, environment: [:])
        let store = AIUsagePricingStore(directory: root.appendingPathComponent("pricing"))
        let scanner = AIUsageActivityScanner(locations: locations, pricing: store)
        let main = #"{"type":"turn_context","payload":{"model":"gpt-5"}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-05T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-05T11:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15},"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-05T12:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"output_tokens":10,"total_tokens":30}}}}"# + "\n"
        for path in ["sessions/main.jsonl", "sessions/copied.jsonl", "archived_sessions/main.jsonl"] {
            let file = locations.codex.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try main.write(to: file, atomically: true, encoding: .utf8)
        }
        let child = #"{"type":"session_meta","timestamp":"2026-10-05T13:00:00Z","payload":{"parent_thread_id":"parent"}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-05T13:00:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"output_tokens":10,"total_tokens":30}}}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-05T13:00:02Z","payload":{"type":"task_started","started_at":1791205200}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-05T13:00:03Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":25,"output_tokens":15,"total_tokens":40}}}}"# + "\n"
        try child.write(to: locations.codex.appendingPathComponent("sessions/child.jsonl"), atomically: true, encoding: .utf8)
        let now = try #require(AIUsageDecoder.date("2026-10-05T14:00:00Z"))
        let result = await scanner.scanUsage(now: now, refreshPricing: false)
        #expect(result.histories[.codex]?.map(\.tokens).reduce(0, +) == 40)
        #expect(result.activity?.date == AIUsageDecoder.date("2026-10-05T13:00:03Z"))
        #expect(await scanner.scanUsage(now: now, refreshPricing: false) == result)
    }
    @Test func lastUsageWithoutCumulativeTotalsSelectsAgentButReplayDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageReplayActivity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = AIUsageLocations(home: root, environment: [:])
        let scanner = AIUsageActivityScanner(locations: locations, pricing: AIUsagePricingStore(directory: root.appendingPathComponent("pricing")))
        let parent = locations.codex.appendingPathComponent("sessions/a-main.jsonl")
        try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = #"{"type":"event_msg","timestamp":"2026-10-05T10:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}}}"#
        try (record + "\n").write(to: parent, atomically: true, encoding: .utf8)
        let now = try #require(AIUsageDecoder.date("2026-10-05T14:00:00Z"))
        #expect(await scanner.scan(now: now)?.date == AIUsageDecoder.date("2026-10-05T10:00:00Z"))
        let child = #"{"type":"session_meta","timestamp":"2026-10-05T13:00:00Z","payload":{"parent_thread_id":"parent"}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-05T13:00:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-05T13:00:02Z","payload":{"type":"task_started","started_at":1791205200}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-05T13:00:03Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}}}"# + "\n"
        try child.write(to: locations.codex.appendingPathComponent("sessions/child.jsonl"), atomically: true, encoding: .utf8)
        #expect(await scanner.scan(now: now)?.date == AIUsageDecoder.date("2026-10-05T10:00:00Z"))
    }
    @Test func claudeCacheAdvisorDedupUnknownAndIncompleteRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageClaudeHistory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = AIUsageLocations(home: root, environment: [:])
        let scanner = AIUsageActivityScanner(locations: locations, pricing: AIUsagePricingStore(directory: root.appendingPathComponent("pricing")))
        let file = locations.claude.appendingPathComponent("projects/main.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let parent = #"{"type":"assistant","timestamp":"2026-10-05T11:00:00Z","requestId":"request","message":{"role":"assistant","id":"main","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation":{"ephemeral_5m_input_tokens":2,"ephemeral_1h_input_tokens":1},"iterations":[{"type":"message","model":null},{"type":"advisor_message","model":"claude-sonnet-4-20250514","input_tokens":2,"output_tokens":3}]}}}"#
        let unknown = #"{"type":"assistant","timestamp":"2026-10-05T12:00:00Z","message":{"role":"assistant","id":"unknown","model":"unknown-fixture-99199","usage":{"input_tokens":1,"output_tokens":2}}}"#
        try (parent + "\n" + parent + "\n" + "malformed\n" + unknown).write(to: file, atomically: true, encoding: .utf8)
        let now = try #require(AIUsageDecoder.date("2026-10-05T14:00:00Z"))
        let first = await scanner.scanUsage(now: now, refreshPricing: false)
        #expect(first.histories[.claude]?.map(\.tokens).reduce(0, +) == 26)
        #expect(first.activity?.date == AIUsageDecoder.date("2026-10-05T11:00:00Z"))
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data("\n".utf8))
        let second = await scanner.scanUsage(now: now, refreshPricing: false)
        #expect(second.histories == first.histories && second.activity?.date == AIUsageDecoder.date("2026-10-05T12:00:00Z"))
        #expect(second.unknownModels[.claude] == ["unknown-fixture-99199"])
    }
}

@Suite
struct AIUsagePricingTests {
    @Test func publicFeedsUseHourlyTTLAndFailedRefreshKeepsOfflineCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsagePricing-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 10000))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = AIUsagePricingStore(directory: root, clock: { clock.withLock { $0 } }, transport: { _ in
            calls.withLock { $0 += 1 }; throw AIUsageError.network
        })
        let initial = await store.current(refresh: false)
        #expect(initial.resolve(model: "gpt-5") != nil && initial.resolve(model: "claude-sonnet-4-20250514") != nil)
        #expect(initial.resolve(model: "unknown-fixture-99199") == nil)
        await store.refreshDueSources(); #expect(calls.withLock { $0 } == 3)
        await store.refreshDueSources(); #expect(calls.withLock { $0 } == 3)
        clock.withLock { $0.addTimeInterval(1799) }
        await store.refreshDueSources(); #expect(calls.withLock { $0 } == 3)
        clock.withLock { $0.addTimeInterval(1) }
        await store.refreshDueSources(); #expect(calls.withLock { $0 } == 6)
        #expect(await store.current(refresh: false).resolve(model: "gpt-5") != nil)
    }
    @Test func successfulCatalogRefreshIsConditionalAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsagePricingSuccess-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 10000))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let transport: AIUsagePricingStore.Transport = { request in
            calls.withLock { $0 += 1 }
            let url = try #require(request.url)
            let data: String
            if url.host == "models.dev" { data = #"{"fixture":{"models":{"fixture-secondary":{"cost":{"input":1,"output":2}}}}}"# }
            else if url.lastPathComponent == "pricing_supplement.json" { data = #"{"updated_at":"2099-01-01","pricing":{},"alias_rules":[]}"# }
            else { data = #"{"fixture-priced-model":{"input_cost_per_token":0.000001,"output_cost_per_token":0.000002}}"# }
            let status = request.value(forHTTPHeaderField: "If-None-Match") == "fixture-etag" ? 304 : 200
            return (Data((status == 200 ? data : "").utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["ETag": "fixture-etag"])))
        }
        let store = AIUsagePricingStore(directory: root, clock: { clock.withLock { $0 } }, transport: transport)
        _ = await store.current(refresh: false)
        await store.refreshDueSources()
        #expect(await store.current(refresh: false).resolve(model: "fixture-priced-model") != nil)
        #expect(await store.current(refresh: false).resolve(model: "fixture-secondary") != nil)
        clock.withLock { $0.addTimeInterval(3599) }
        await store.refreshDueSources(); #expect(calls.withLock { $0 } == 3)
        clock.withLock { $0.addTimeInterval(1) }
        await store.refreshDueSources(); #expect(calls.withLock { $0 } == 6)
        let restart = AIUsagePricingStore(directory: root, clock: { clock.withLock { $0 } }, transport: transport)
        #expect(await restart.current(refresh: false).resolve(model: "fixture-priced-model") != nil)
        await restart.refreshDueSources(); #expect(calls.withLock { $0 } == 6)
    }
}
