//
//  TerminalSubscriptionExpiryTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 12.10.2026.
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Mimic
import MimicCore

@MainActor private final class ExpiryWeakSubscription {
    weak var value: PanelTerminalSubscription?
    weak var channel: PanelTerminalChannel?
    init(_ value: PanelTerminalSubscription) { self.value = value; self.channel = value.channel }
}

@MainActor private struct ExpiryFixture {
    let root: URL
    let defaults: UserDefaults
    let model: TaskCoordinator
    let integration: MimicIntegration
    let taskID: UUID
    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalExpiry-" + UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        let integration = MimicIntegration(model: model, defaults: defaults)
        let project = ProjectContext(path: root.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        var workspace = PanelWorkspace(); workspace.checkout = project.path
        try integration.workspaceStore.save(workspace, for: "fixture-chat")
        var record = TaskRecord(action: .bootstrap, project: project); record.status = .running
        model.records = [record]
        self.root = root; self.defaults = defaults; self.model = model; self.integration = integration; self.taskID = record.id
    }
    func subscription(expires: Date, taskID: UUID? = nil) throws -> PanelTerminalSubscription {
        let peer = P256.KeyAgreement.PrivateKey()
        let channel = try PanelTerminalChannel(taskID: taskID ?? self.taskID, threadID: "fixture-chat", clientKey: peer.publicKey.x963Representation, now: expires.addingTimeInterval(-900))
        return PanelTerminalSubscription(channel, model: self.model)
    }
    func stop() {
        self.integration.stop(); self.model.records = []; self.model.stopAndExit()
        self.defaults.removePersistentDomain(forName: self.root.lastPathComponent)
        try? FileManager.default.removeItem(at: self.root)
    }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalSubscriptionExpiryTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func exactTTLBoundaryReleasesOnlyExpiredObserverAndBuffers() throws {
        let fixture = try ExpiryFixture(); defer { fixture.stop() }
        let deadline = Date().addingTimeInterval(900)
        let expired = try fixture.subscription(expires: deadline), live = try fixture.subscription(expires: deadline.addingTimeInterval(10))
        expired.snapshot = Data(repeating: 65, count: 128 * 1024); expired.last = Data(repeating: 66, count: 128 * 1024)
        fixture.integration.terminalChannels = [expired.channel.id: expired, live.channel.id: live]
        fixture.integration.expireTerminalChannels(now: deadline.addingTimeInterval(-0.001))
        #expect(fixture.integration.terminalChannels.count == 2)
        #expect(try expired.channel.seal(Data([1]), now: deadline.addingTimeInterval(-0.001)).sequence == 1)
        #expect(throws: PanelChannelError.self) { try expired.channel.seal(Data([1]), now: deadline) }
        fixture.integration.expireTerminalChannels(now: deadline)
        #expect(fixture.integration.terminalChannels.count == 1 && fixture.integration.terminalChannels[live.channel.id] === live)
        #expect(expired.snapshot.isEmpty && expired.last.isEmpty)
        fixture.model.terminalOutput?(fixture.taskID, Data("SYNTHETIC_OUTPUT".utf8))
        #expect(expired.snapshot.isEmpty && String(decoding: live.snapshot, as: UTF8.self) == "SYNTHETIC_OUTPUT")
        #expect(fixture.model.records[0].status == .running)
        #expect(fixture.integration.terminalExpiryDeadline == live.channel.expiresAt)
    }

    @Test func autonomousDeadlineReschedulesEarlierThenKeepsLiveViewerAndRejectsLatePoll() async throws {
        let fixture = try ExpiryFixture(); defer { fixture.stop() }
        let live = try fixture.subscription(expires: Date().addingTimeInterval(900))
        fixture.integration.terminalChannels[live.channel.id] = live
        let expired = try fixture.subscription(expires: Date().addingTimeInterval(0.15))
        fixture.integration.terminalChannels[expired.channel.id] = expired
        #expect(fixture.integration.terminalExpiryDeadline == expired.channel.expiresAt)
        // No bridge request or manual sweep occurs before this predicate succeeds.
        try await self.wait { fixture.integration.terminalChannels[expired.channel.id] == nil }
        #expect(Date() >= expired.channel.expiresAt)
        #expect(fixture.integration.terminalChannels[live.channel.id] === live)
        #expect(fixture.integration.terminalExpiryDeadline == live.channel.expiresAt)
        fixture.model.terminalOutput?(fixture.taskID, Data("STILL_LIVE".utf8))
        #expect(expired.snapshot.isEmpty && String(decoding: live.snapshot, as: UTF8.self) == "STILL_LIVE")
        do {
            _ = try await fixture.integration.terminalRequest(.init(method: "panel_terminal_poll", parameters: ["channelID": .string(expired.channel.id.uuidString)], threadID: "fixture-chat"), threadID: "fixture-chat")
            Issue.record("Expired terminal channel accepted a late poll")
        } catch let error as MimicIntegration.IntegrationError { #expect(error.code == "channel") }
    }

    @Test func explicitCloseAndStopCancelDeadlineAndReleaseObservers() async throws {
        let fixture = try ExpiryFixture(); defer { fixture.stop() }
        let peer = P256.KeyAgreement.PrivateKey()
        let opened = try await fixture.integration.panelRequest(.init(method: "panel_terminal_open", parameters: ["taskID": .string(fixture.taskID.uuidString), "publicKey": .string(peer.publicKey.x963Representation.base64EncodedString())], threadID: "fixture-chat"))
        let id = try #require(opened["channelID"].string.flatMap(UUID.init(uuidString:)))
        let weak = ExpiryWeakSubscription(try #require(fixture.integration.terminalChannels[id]))
        #expect(fixture.integration.terminalExpiryTask != nil)
        let result = try await fixture.integration.panelRequest(.init(method: "panel_terminal_close", parameters: ["channelID": .string(id.uuidString)], threadID: "fixture-chat"))
        #expect(result["closed"] == .bool(true) && weak.value == nil && fixture.model.terminalOutput == nil)
        #expect(fixture.integration.terminalExpiryTask == nil && fixture.integration.terminalExpiryDeadline == nil)
        let channel = try fixture.subscription(expires: Date().addingTimeInterval(900)).channel
        fixture.integration.terminalChannels[channel.id] = PanelTerminalSubscription(channel, model: fixture.model)
        let stopped = ExpiryWeakSubscription(try #require(fixture.integration.terminalChannels[channel.id]))
        fixture.integration.stop()
        #expect(stopped.value == nil && fixture.model.terminalOutput == nil)
        #expect(fixture.integration.terminalExpiryTask == nil && fixture.integration.terminalExpiryDeadline == nil)
    }

    @Test(arguments: [1, 2, 3]) func scheduledExpiryFreesEightMiBWithoutTraffic(repeat index: Int) async throws {
        let fixture = try ExpiryFixture(); defer { fixture.stop() }
        var subscriptions: [UUID: PanelTerminalSubscription] = [:], weak: [ExpiryWeakSubscription] = []
        let deadline = Date().addingTimeInterval(0.6)
        for _ in 0..<32 {
            let subscription = try fixture.subscription(expires: deadline)
            // Independent synthetic allocations reproduce the retained snapshot + last upper bound.
            subscription.snapshot = Data(repeating: 65, count: 128 * 1024)
            subscription.last = Data(repeating: 66, count: 128 * 1024)
            subscriptions[subscription.channel.id] = subscription; weak.append(ExpiryWeakSubscription(subscription))
        }
        let bytes = subscriptions.values.reduce(0) { $0 + $1.snapshot.count + $1.last.count }
        #expect(bytes == 8 * 1024 * 1024)
        fixture.integration.terminalChannels = subscriptions; subscriptions = [:]
        var before = malloc_statistics_t(); malloc_zone_statistics(nil, &before)
        try await self.wait { fixture.integration.terminalChannels.isEmpty }
        var after = malloc_statistics_t(); malloc_zone_statistics(nil, &after)
        #expect(weak.allSatisfy { $0.value == nil && $0.channel == nil })
        #expect(fixture.model.terminalOutput == nil && fixture.integration.terminalExpiryTask == nil)
        #expect(before.size_in_use > after.size_in_use + 7 * 1024 * 1024)
        print("F5_MEMORY repeat=\(index) payloadBytes=\(bytes) heapBefore=\(before.size_in_use) heapAfter=\(after.size_in_use)")
    }

    @Test func expiryDoesNotCancelLivePTYOrAnotherObserver() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalExpiryPTY-" + UUID().uuidString)
        let checkout = root.appendingPathComponent("checkout"), storage = root.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("App/App.xcworkspace"), withIntermediateDirectories: true)
        for arguments in [["init", "-q", checkout.path], ["-C", checkout.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-qm", "Fixture"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", arguments).0 == 0)
        }
        var manifest = try #require(JSONSerialization.jsonObject(with: Profile11Fixture.data()) as? [String: Any])
        var actions = try #require(manifest["actions"] as? [[String: Any]])
        let profile = try JSONDecoder().decode(MimicProfile.self, from: Profile11Fixture.data())
        let actionID = try #require(profile.interface?.bindings.first { $0.role == .format }?.actionID)
        let index = try #require(actions.firstIndex { $0["id"] as? String == actionID })
        let script = checkout.appendingPathComponent("expiry-pty-fixture.sh")
        try ("# Created by Василий Маслов on 12.10.2026.\n" + "stty -echo; printf READY; IFS= read -r value; test \"$value\" = FINISH || exit 7; printf DONE\n").write(to: script, atomically: true, encoding: .utf8)
        actions[index]["steps"] = [["executable": "/bin/bash", "arguments": [script.path], "directory": "${checkout}"]]
        manifest["actions"] = actions
        _ = try Profile11Fixture.install(directory: storage, data: JSONSerialization.data(withJSONObject: manifest))
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
        let model = TaskCoordinator(directory: storage, helperURL: helper, defaults: defaults)
        let integration = MimicIntegration(model: model, defaults: defaults), nativeOwner = UUID()
        defer {
            integration.stop(); model.detachTerminal(owner: nativeOwner); model.stopAndExit()
            defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root)
        }
        let project = try EnvironmentInspector.project(path: checkout.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        var native = Data(); model.attachTerminal(owner: nativeOwner) { _, bytes in native.append(bytes) }
        model.request(.format)
        try await self.wait { String(decoding: native, as: UTF8.self).contains("READY") }
        let id = try #require(model.activeID), peer = P256.KeyAgreement.PrivateKey()
        let expiredChannel = try PanelTerminalChannel(taskID: id, threadID: "expired", clientKey: peer.publicKey.x963Representation, now: Date().addingTimeInterval(-899.85))
        let liveChannel = try PanelTerminalChannel(taskID: id, threadID: "live", clientKey: peer.publicKey.x963Representation)
        let expired = PanelTerminalSubscription(expiredChannel, model: model), live = PanelTerminalSubscription(liveChannel, model: model)
        integration.terminalChannels = [expiredChannel.id: expired, liveChannel.id: live]
        try await self.wait { integration.terminalChannels[expiredChannel.id] == nil }
        #expect(model.activeID == id && model.records.first { $0.id == id }?.status == .running)
        #expect(model.input(id: id, data: Data("FINISH\n".utf8)))
        try await self.wait { model.activeID == nil }
        #expect(model.records.first { $0.id == id }?.status == .succeeded)
        #expect(String(decoding: native, as: UTF8.self).contains("DONE"))
        #expect(String(decoding: live.snapshot, as: UTF8.self).contains("DONE") && expired.snapshot.isEmpty)
        #expect(integration.terminalChannels[liveChannel.id] === live)
    }
}
