//
//  MimicUpdateBackupTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct MimicUpdateBackupTests {
    @Test func backupPreservesAppHistoryProfileAndPluginWithoutPrivateRuntimeFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicBackupTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Mimic.app"), support = root.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for name in ["history.json", "Profiles", "CodexPlugin", "Bridge", "Development", "Diagnostics"] {
            if name.hasSuffix("json") { try Data("[]".utf8).write(to: support.appendingPathComponent(name)) }
            else {
                try FileManager.default.createDirectory(at: support.appendingPathComponent(name), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: support.appendingPathComponent(name + "/marker"))
            }
        }
        let preferences = Data("preferences".utf8)
        let backup = try await MimicUpdateBackup.create(app: app, support: support, preferences: preferences, destination: support.appendingPathComponent("UpdateBackups"))
        #expect(try Data(contentsOf: backup.appendingPathComponent("preferences.plist")) == preferences)
        for name in ["history.json", "Profiles", "CodexPlugin"] { #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Data/" + name).path)) }
        for name in ["Bridge", "Development", "Diagnostics", "UpdateBackups"] { #expect(!FileManager.default.fileExists(atPath: backup.appendingPathComponent("Data/" + name).path)) }
        #expect(try Data(contentsOf: support.appendingPathComponent("history.json")) == Data("[]".utf8))
    }
    @Test func failedBackupLeavesNoCompletedBackupOrChangesToSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicBackupTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Mimic.app"), support = root.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Profiles"), withDestinationURL: app)
        let backups = support.appendingPathComponent("UpdateBackups")
        await #expect(throws: (any Error).self) { try await MimicUpdateBackup.create(app: app, support: support, preferences: Data(), destination: backups) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
        #expect(try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) == Data("fixture".utf8))
    }
}
