//
//  ResourceLifecycleTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 21.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct ResourceLifecycleTests {
    @Test func historyBarrierOrdersSnapshotsAndRetainsUnchangedUnknownFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = TaskRecord(action: .format, project: .init(path: root.path))
        var second = TaskRecord(action: .localization, project: .init(path: root.path))
        let file = root.appendingPathComponent("history.json")
        var objects = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([first, second])) as? [[String: Any]])
        objects[0]["futureField"] = "preserve"
        try JSONSerialization.data(withJSONObject: objects).write(to: file)
        let writer = TaskHistoryPersistence(store: .init(directory: root))
        writer.save([first, second]); try await writer.flush()
        second.status = .running; writer.save([first, second])
        second.status = .succeeded; writer.save([first, second])
        try await writer.flush()
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        #expect(saved.first(where: { $0["id"] as? String == first.id.uuidString })?["futureField"] as? String == "preserve")
        #expect(try HistoryStore(directory: root).load().first(where: { $0.id == second.id })?.status == .succeeded)
        #expect(writer.savedRevision == writer.revision)
    }

    @Test func failedHistoryBarrierCanRecoverWithoutReplayingAnOlderSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let writer = TaskHistoryPersistence(store: .init(directory: root))
        var record = TaskRecord(action: .format, project: .init(path: root.path))
        writer.save([record])
        await #expect(throws: (any Error).self) { try await writer.flush() }
        #expect(writer.hasUnflushedChanges)
        try FileManager.default.removeItem(at: root)
        record.status = .cancelled; writer.save([record]); try await writer.flush()
        #expect(try HistoryStore(directory: root).load().first?.status == .cancelled)
    }

    @Test func panelRevisionSkipsUnchangedPayloadAndCannotBorrowAnotherOwnerToken() async throws {
        let suite = "ResourceLifecycle-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        model.aiUsage.stop()
        let bridge = MimicIntegration(model: model, defaults: defaults)
        func poll(_ owner: String, _ token: String) async throws -> BridgeValue {
            try await bridge.handle(.init(method: "panel_poll_state", parameters: ["afterRevision": .string(token)], threadID: owner))
        }
        try await Task.sleep(for: .milliseconds(100))
        let first = try await poll("fixture-a", "")
        let token = try #require(first["revision"].string)
        #expect(first["changed"] == .bool(true))
        let unchanged = try await poll("fixture-a", token)
        #expect(unchanged["changed"] == .bool(false) && unchanged["state"] == .null)
        let other = try await poll("fixture-b", token)
        #expect(other["changed"] == .bool(true) && other["revision"].string != token)
        model.message = "fixture change"
        #expect(try await poll("fixture-a", token)["changed"] == .bool(true))
        model.stopAndExit()
        try await Task.sleep(for: .milliseconds(100))
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func backgroundAIScanHasFiveMinuteBudgetAndManualRefreshBypassesIt() async throws {
        let suite = "ResourceAI-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var date = Date(), scans = 0
        let usage = AIUsageCoordinator(defaults: defaults, adapters: [], scanUsage: { scans += 1; return .init(activity: nil) }, clock: { date })
        await usage.tick(); await usage.tick()
        #expect(scans == 1)
        date.addTimeInterval(299); await usage.tick(); #expect(scans == 1)
        date.addTimeInterval(1); await usage.tick(); #expect(scans == 2)
        await usage.tick(forceScan: true); #expect(scans == 3)
        usage.stop()
    }
}
