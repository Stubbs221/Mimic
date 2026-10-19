// Created by Василий Маслов on 12.10.2026.
import Foundation
import Testing
@testable import MimicCore

@MainActor struct CodexPanelAppearanceTests {
    @Test(arguments: [PanelAppearance.tileGrid, .legacy]) func migrationIsOnceAndIndependent(previous: PanelAppearance) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexPanelAppearanceStore(directory: directory, previous: previous)
        #expect(store.value.selection.rawValue == previous.rawValue)
        #expect(store.value.revision == 0 && !store.persistenceFailed)
        let saved = try store.select(.windowsXP, expectedRevision: 0)
        #expect(saved.revision == 1)
        #expect(try store.select(.windowsXP, expectedRevision: 1) == saved)
        #expect(CodexPanelAppearanceStore(directory: directory, previous: .legacy).value == saved)
        #expect(throws: CodexAppearanceError.self) { try store.select(.windows95, expectedRevision: 0) }
        #expect(store.value == saved)
    }
    @Test func failedSaveKeepsMemoryAndDiskAndCanRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = CodexPanelAppearanceStore(directory: directory, previous: .legacy)
        var fail = true
        let store = CodexPanelAppearanceStore(directory: directory, previous: .tileGrid) { data, url in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        #expect(throws: CocoaError.self) { try store.select(.windows95, expectedRevision: 0) }
        #expect(store.value.selection == .legacy && store.value.revision == 0)
        #expect(CodexPanelAppearanceStore(directory: directory, previous: .tileGrid).value == store.value)
        fail = false
        #expect(try store.select(.windows95, expectedRevision: 0).revision == 1)
    }
    @Test func failedMigrationAndCorruptionAreVisible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = CodexPanelAppearanceStore(directory: directory, previous: .legacy) { _, _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(failed.persistenceFailed && failed.value.selection == .legacy)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("codex-appearance.json"))
        let damaged = CodexPanelAppearanceStore(directory: directory, previous: .legacy)
        #expect(damaged.persistenceFailed && damaged.value.selection == .tileGrid)
        #expect(try damaged.select(.legacy, expectedRevision: 0).revision == 1)
    }
}
