//
//  SharedPanelAppearanceTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 13.10.2026.
import Foundation
import Observation
import Testing
@testable import MimicCore

@MainActor struct SharedPanelAppearanceTests {
    @Test func bothSurfacesObserveOneRevisionWithoutWritingLayouts() throws {
        let name = "SharedAppearance-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let native = PanelAppearanceStore(defaults: defaults)
        let shared = CodexPanelAppearanceStore(directory: directory, previous: native.selection)
        native.connect(to: shared)
        let layouts = PanelLayoutStore(defaults: defaults)
        let desktop = layouts.load(.desktop), codex = layouts.load(.codex)
        for choice in PanelAppearance.allCases {
            native.select(choice)
            #expect(native.selection.rawValue == shared.value.selection.rawValue)
            #expect(CodexPanelAppearanceStore(directory: directory, previous: .legacy).value == shared.value)
            let next: CodexPanelAppearance = choice == .windows95 ? .windowsXP : .windows95
            try shared.select(next, expectedRevision: shared.value.revision)
            #expect(native.selection.rawValue == next.rawValue)
            #expect(layouts.load(.desktop) == desktop && layouts.load(.codex) == codex)
        }
        #expect(native.selection.compatibleAppearance == .tileGrid)
        #expect(PanelAppearance.legacy.compatibleAppearance == .legacy)
    }

    @Test func failedNativeSaveDoesNotPublishOrPreparePresentation() throws {
        let name = "SharedAppearanceFailure-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        _ = CodexPanelAppearanceStore(directory: directory, previous: .legacy)
        var fail = true, prepared = 0
        let shared = CodexPanelAppearanceStore(directory: directory, previous: .tileGrid) { data, url in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        shared.selectionWillChange = { prepared += 1 }
        let native = PanelAppearanceStore(defaults: defaults); native.connect(to: shared)
        native.select(.windowsXP)
        #expect(native.saveFailed && native.selection == .legacy && prepared == 0)
        fail = false; native.select(.windowsXP)
        #expect(!native.saveFailed && native.selection == .windowsXP && prepared == 1)
        native.deferPresentation()
        try shared.select(.windows95, expectedRevision: shared.value.revision)
        #expect(native.selection == .windowsXP && shared.value.selection == .windows95)
        native.resumePresentation()
        #expect(native.selection == .windows95)
    }
}
