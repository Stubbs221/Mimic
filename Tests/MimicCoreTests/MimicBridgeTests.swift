//
//  MimicBridgeTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation
import Darwin
import Testing
@testable import MimicCore

struct MimicBridgeTests {
    @Test func aPeerWhichStopsReadingCannotBlockReplyDeliveryForever() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        var budget: Int32 = 1024
        try #require(setsockopt(descriptors[1], SOL_SOCKET, SO_SNDBUF, &budget, socklen_t(MemoryLayout<Int32>.size)) == 0)
        #expect(throws: MimicBridgeError.timeout) {
            try MimicSocket.send(Data(repeating: 65, count: MimicSocket.maximumBytes), to: descriptors[1], timeout: 100)
        }
    }
    @Test func partialMessagesCannotExtendTheReceiveDeadline() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let reader = descriptors[0], writer = descriptors[1], finished = DispatchSemaphore(value: 0)
        MimicSocket.configure(writer)
        defer { close(reader); finished.wait() }
        DispatchQueue.global().async {
            defer { close(writer); finished.signal() }
            for byte: UInt8 in [65, 66, 67, 68, 69, 10] {
                usleep(30_000)
                var value = byte
                if write(writer, &value, 1) != 1 { break }
            }
        }
        #expect(throws: MimicBridgeError.timeout) { try MimicSocket.receive(reader, timeout: 100) }
    }
    @Test @MainActor func videoPipelinesLeaveRoomForLiveness() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/mcp-" + UUID().uuidString.prefix(8))
        let path = directory.appendingPathComponent("m.sock").path
        let listener = MimicBridgeListener(path: path)
        defer { listener.stop(); try? FileManager.default.removeItem(at: directory) }
        var handled = 0
        try listener.start { request in
            handled += 1
            try? await Task.sleep(for: .milliseconds(200))
            return .init(id: request.id, result: .bool(true))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let reply = try await MimicSocket.call(.init(method: "fixture_video"), path: path)
                    #expect(reply.result == .bool(true))
                }
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(50))
                let reply = try await MimicSocket.call(.init(method: "bridge_ping"), path: path)
                #expect(reply.result["version"].integer == 3)
            }
            try await group.waitForAll()
        }
        #expect(handled == 12, "Liveness must not invoke native app-state handling")
    }
    @Test @MainActor func socketRoundTripIsPrivateAndVersioned() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/mcp-" + UUID().uuidString.prefix(8))
        let path = directory.appendingPathComponent("m.sock").path
        let listener = MimicBridgeListener(path: path)
        defer { listener.stop(); try? FileManager.default.removeItem(at: directory) }
        try listener.start { request in .init(id: request.id, result: .object(["method": .string(request.method)])) }
        let reply = try await MimicSocket.call(.init(method: "get_state"), path: path)
        #expect(reply.result["method"].string == "get_state")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let version = try await MimicSocket.call(.init(method: "get_state", version: 1), path: path)
        #expect(version.error != nil)
        let second = MimicBridgeListener(path: path)
        #expect(throws: MimicBridgeError.occupied) { try second.start { .init(id: $0.id) } }
        listener.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
    @Test func valueRoundTripAndFramingBound() throws {
        let value: BridgeValue = .object(["text": .string("строка\nследующая"), "items": .array([.bool(true), .null, .number(5)])])
        #expect(try JSONDecoder().decode(BridgeValue.self, from: JSONEncoder().encode(value)) == value)
        #expect(throws: MimicBridgeError.invalidMessage) { try MimicSocket.address(String(repeating: "a", count: 200)) }
        #expect(throws: MimicBridgeError.invalidMessage) { try MimicSocket.send(Data(repeating: 0, count: MimicSocket.maximumBytes + 1), to: -1) }
    }
    @Test func pluginExportUsesExactAppHelperWithoutShell() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/MimicPlugin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("App with spaces.app")
        let helper = app.appendingPathComponent("Contents/Helpers/MimicMCP")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let icon = app.appendingPathComponent("Contents/Resources/MimicPluginIcon.png")
        try FileManager.default.createDirectory(at: icon.deletingLastPathComponent(), withIntermediateDirectories: true)
        let iconData = Data([0x89, 0x50, 0x4E, 0x47])
        try iconData.write(to: icon)
        let export = try MimicPluginExporter.export(app: app, directory: directory.appendingPathComponent("plugin"), readme: "Fixture instructions")
        let manifest = try JSONDecoder().decode(BridgeValue.self, from: Data(contentsOf: export.appendingPathComponent("plugins/mimic/.codex-plugin/plugin.json")))
        #expect(manifest["version"].string == MimicVersion.version)
        let marketplace = try JSONDecoder().decode(BridgeValue.self, from: Data(contentsOf: export.appendingPathComponent(".agents/plugins/marketplace.json")))
        #expect(marketplace["name"].string == "mimic-desktop")
        #expect(manifest["interface"]["composerIcon"].string == "./assets/icon.png")
        #expect(manifest["interface"]["logo"].string == "./assets/icon.png")
        #expect(try Data(contentsOf: export.appendingPathComponent("plugins/mimic/assets/icon.png")) == iconData)
        // Re-export replaces the independent plugin mark supplied by a newer app bundle.
        let updatedIcon = Data([0x89, 0x50, 0x4E, 0x47, 1])
        try updatedIcon.write(to: icon)
        _ = try MimicPluginExporter.export(app: app, directory: export, readme: "Fixture instructions")
        #expect(try Data(contentsOf: export.appendingPathComponent("plugins/mimic/assets/icon.png")) == updatedIcon)
        let config = try JSONDecoder().decode(BridgeValue.self, from: Data(contentsOf: export.appendingPathComponent("plugins/mimic/.mcp.json")))
        #expect(config["mcpServers"]["mimic"]["command"].string == helper.path)
        #expect(config["mcpServers"]["mimic"]["args"].array == [])
        #expect(try String(contentsOf: export.appendingPathComponent("README.md"), encoding: .utf8) == "Fixture instructions")
    }
    @Test func pluginRevisionDetectsSameVersionHelperAndPanelChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicPluginRevision-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("Contents/Helpers/MimicMCP")
        let panel = root.appendingPathComponent("Contents/Resources/Mimic_MimicMCP.bundle/panel.html")
        for file in [helper, panel] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data("helper-a".utf8).write(to: helper); try Data("panel-a".utf8).write(to: panel)
        let original = try MimicPluginExporter.installationRevision(app: root)
        #expect(try MimicPluginExporter.installationRevision(app: root) == original)
        try Data("helper-b".utf8).write(to: helper)
        let changedHelper = try MimicPluginExporter.installationRevision(app: root)
        #expect(changedHelper != original)
        try Data("panel-b".utf8).write(to: panel)
        #expect(try MimicPluginExporter.installationRevision(app: root) != changedHelper)
    }

}
