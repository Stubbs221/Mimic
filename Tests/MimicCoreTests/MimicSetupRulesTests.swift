//
//  MimicSetupRulesTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct MimicSetupRulesTests {
    @Test func preservesOtherInstructionsAndProjectsAndIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Setup rules " + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("AGENTS.md")
        let original = "Personal instructions\n\nKeep this exact whitespace.\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let backup = try #require(try MimicSetupRules.update(project: "/tmp/project one", enabled: true, home: home))
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        let instructions = try String(contentsOf: file, encoding: .utf8)
        #expect(instructions.contains("`checkout` set to the absolute working directory of this chat (including a descendant directory)"))
        #expect(instructions.contains("Opening and binding must not send additional messages to the chat."))
        #expect(try MimicSetupRules.update(project: "/tmp/project one", enabled: true, home: home) == nil)
        try MimicSetupRules.update(project: "/tmp/project two", enabled: true, home: home)
        try MimicSetupRules.update(project: "/tmp/project one", enabled: false, home: home)
        #expect(try !MimicSetupRules.contains(project: "/tmp/project one", home: home))
        #expect(try MimicSetupRules.contains(project: "/tmp/project two", home: home))
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix(original))
        #expect(try MimicSetupRules.update(project: "/tmp/project one", enabled: false, home: home) == nil)
    }
    @Test func malformedBlockAndUnsafePathDoNotChangeFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try MimicSetupRules.update(project: "/tmp/project", enabled: true, home: home)
        let file = home.appendingPathComponent("AGENTS.md")
        var s = try String(contentsOf: file, encoding: .utf8)
        s = s.replacingOccurrences(of: ":end -->", with: ":broken -->")
        try s.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: MimicSetupRules.RuleError.self) { try MimicSetupRules.update(project: "/tmp/project", enabled: false, home: home) }
        #expect(throws: MimicSetupRules.RuleError.self) { try MimicSetupRules.update(project: "/tmp/project\nnew rule", enabled: true, home: home) }
        #expect(try String(contentsOf: file, encoding: .utf8) == s)
    }
    @Test func respectsCustomCodexHome() {
        #expect(MimicSetupRules.codexHome(environment: ["CODEX_HOME": "/tmp/custom codex"]).path == "/tmp/custom codex")
    }
}

struct MimicSetupInstallerTests {
    private func executable(_ body: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent("fake codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    @Test func usesOnlyOfficialCommandsAndDoesNotRemoveMarketplace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = try self.executable("printf '%s\\n' \"$*\" >> \"$(dirname \"$0\")/calls\"\nexit 0\n", in: root)
        try await MimicPluginInstaller.install(marketplace: root.appendingPathComponent("market place"), codex: codex)
        try await MimicPluginInstaller.uninstall(codex: codex)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.contains("plugin marketplace add --help"))
        #expect(calls.contains("plugin add mimic@mimic-desktop"))
        #expect(calls.contains("plugin remove mimic@mimic-desktop"))
        #expect(!calls.contains("marketplace remove"))
    }
    @Test func failureMissingCommandAndTimeout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = try self.executable("exit 2\n", in: root)
        await #expect(throws: MimicBridgeError.self) { try await MimicPluginInstaller.check(codex: bad, timeout: 1) }
        let sleeping = try self.executable("exec /bin/sleep 10\n", in: root)
        let started = Date()
        await #expect(throws: MimicBridgeError.self) { try await MimicPluginInstaller.check(codex: sleeping, timeout: 0.1) }
        #expect(Date().timeIntervalSince(started) < 2)
        await #expect(throws: (any Error).self) { try await MimicPluginInstaller.check(codex: root.appendingPathComponent("missing")) }
    }
}
