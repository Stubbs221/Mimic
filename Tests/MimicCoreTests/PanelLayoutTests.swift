//
//  PanelLayoutTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct PanelLayoutTests {
    @Test func sizeAndSideInsertionAreAtomicAndPreserveAllNeighbours() throws {
        let original = PanelLayout.standard(for: .desktop), ids = [UUID(), UUID(), UUID()]
        var mini = original
        try mini.insert(.bootstrap, at: .boundary(before: original.rows[1].id), size: .mini, miniSlot: 1, generatedRowIDs: ids)
        #expect(mini.rows.first?.slots == [nil, .bootstrap])
        #expect(mini.size(of: .bootstrap) == .mini)
        var full = original
        try full.insert(.builds, at: .boundary(before: original.rows[1].id), size: .full, generatedRowIDs: ids)
        #expect(full.rows[1].slots == [.builds]); #expect(full.rows[2].slots == [.utils, nil])
        #expect(Set(full.blocks) == Set(original.blocks))
        var repeated = original
        try repeated.insert(.builds, at: .boundary(before: original.rows[1].id), size: .full, generatedRowIDs: ids)
        #expect(repeated == full)
        var occupied = original
        try occupied.insert(.bootstrap, at: .slot(row: original.rows[1].id, slot: 1), size: .mini, generatedRowIDs: ids)
        #expect(occupied.rows[1].slots[1] == .bootstrap); #expect(Set(occupied.blocks) == Set(original.blocks))
        try occupied.validate(for: .desktop)
        var invalid = original
        #expect(throws: PanelLayoutError.invalid) { try invalid.insert(.bootstrap, at: .slot(row: original.rows[1].id, slot: 0), size: .full) }
        #expect(invalid == original)
    }
    @Test func insertionRotatesBothDirectionsAndPreservesUnrelatedHoles() throws {
        let rows = [PanelLayoutRow(slots: [.utils, .builds]), PanelLayoutRow(slots: [.ci, .simulators]), PanelLayoutRow(slots: [nil, .format])]
        var forward = PanelLayout(rows: rows)
        try forward.insert(.utils, at: .slot(row: rows[1].id, slot: 1))
        #expect(forward.rows.map(\.slots) == [[.builds, .ci], [.simulators, .utils], [nil, .format]])
        try forward.insert(.utils, at: .slot(row: rows[0].id, slot: 0))
        #expect(forward.rows == rows)
        try forward.insert(.builds, at: .slot(row: rows[2].id, slot: 0))
        #expect(forward.rows.map(\.slots) == [[.utils, nil], [.ci, .simulators], [.builds, .format]])
    }
    @Test func insertionAcrossFullRowsDisplacesUntilVacancyOrAddsMiniRow() throws {
        let rows = [PanelLayoutRow(slots: [.utils, .format]), PanelLayoutRow(slots: [.bootstrap]), PanelLayoutRow(slots: [.ci, .builds]), PanelLayoutRow(slots: [.simulators, nil]), PanelLayoutRow(slots: [.ai])]
        var layout = PanelLayout(rows: rows)
        try layout.insert(.utils, at: .slot(row: rows[2].id, slot: 0))
        #expect(layout.rows.map(\.slots) == [[nil, .format], [.bootstrap], [.utils, .ci], [.builds, .simulators], [.ai]])
        var full = PanelLayout(rows: Array(rows.prefix(3)) + [rows[4]])
        try full.insert(.utils, at: .slot(row: rows[2].id, slot: 1))
        #expect(full.rows.map(\.slots) == [[nil, .format], [.bootstrap], [.ci, .utils], [.builds, nil], [.ai]])
    }
    @Test func insertionPreservesSizesFullIdentityAndIsAtomicOnBadTarget() throws {
        var layout = PanelLayout.standard(for: .desktop), original = layout
        let bootstrap = layout.rows[0].id
        try layout.insert(.bootstrap, at: .boundary(before: nil))
        #expect(layout.rows.last?.id == bootstrap)
        #expect(layout.size(of: .bootstrap) == .full)
        try layout.insert(.utils, at: .boundary(before: bootstrap))
        #expect(layout.size(of: .utils) == .mini)
        #expect(layout.rows[0].slots == [nil, .builds])
        original = layout
        #expect(throws: PanelLayoutError.invalid) { try layout.insert(.bootstrap, at: .slot(row: layout.rows[0].id, slot: 0)) }
        #expect(layout == original)
        try layout.validate(for: .desktop)
    }
    @Test func everyInsertionRetainsAllBlocksAndTheirSizes() throws {
        let original = PanelLayout.standard(for: .desktop)
        for block in original.blocks {
            for row in original.rows {
                let targets: [PanelInsertionTarget] = [.boundary(before: row.id)] + (row.size == .mini && original.size(of: block) == .mini ? [.slot(row: row.id, slot: 0), .slot(row: row.id, slot: 1)] : [])
                for target in targets {
                    var next = original; try next.insert(block, at: target); try next.validate(for: .desktop)
                    #expect(Set(next.blocks) == Set(original.blocks))
                    for kind in original.blocks { #expect(next.size(of: kind) == original.size(of: kind)) }
                }
            }
        }
    }
    @Test func removalAndExpansionDoNotCompactNeighbours() throws {
        var layout = PanelLayout.standard(for: .codex)
        layout.remove(.utils)
        #expect(layout.rows[1].slots == [nil, .builds])
        try layout.resize(.builds, to: .full)
        #expect(layout.rows[1].slots == [.builds])
        try layout.validate(for: .codex)
    }
    @Test func moveNeverOverwritesOccupiedSlotsAndKeepsSourceOnFailure() throws {
        var layout = PanelLayout.standard(for: .codex); let original = layout
        #expect(throws: PanelLayoutError.occupied) { try layout.move(.builds, to: layout.rows[2].id, slot: 0) }
        #expect(layout == original)
        layout.remove(.simulators)
        try layout.move(.builds, to: layout.rows[2].id, slot: 1)
        #expect(layout.rows.last?.slots == [.ci, .builds])
        #expect(layout.rows[1].slots == [.utils, nil])
    }
    @Test func replacementAndResizePreserveEveryOtherBlock() throws {
        var layout = PanelLayout.standard(for: .desktop)
        try layout.replace(.utils, with: .format)
        try layout.resize(.format, to: .full)
        #expect(layout.rows[1].slots == [.format])
        #expect(layout.rows[2].slots == [.builds, nil])
        #expect(throws: PanelLayoutError.duplicate) { try layout.add(.format) }
        try layout.validate(for: .desktop)
    }
    @Test @MainActor func concurrentEditorsCannotOverwriteSavedLayout() throws {
        let suite = "PanelLayoutTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelLayoutStore(defaults: defaults); var first = store.load(.codex); let second = first
        #expect(store.load(.codex) == first)
        first.remove(.ci); let saved = try store.save(first, for: .codex, expectedRevision: first.revision)
        #expect(saved.revision == 1)
        #expect(throws: PanelLayoutError.conflict) { try store.save(second, for: .codex, expectedRevision: 0) }
        #expect(store.load(.desktop).blocks.contains(.ai))
        #expect(!store.load(.codex).blocks.contains(.ai))
    }
    @Test func invalidShapesAndUnsupportedSurfaceFailValidation() throws {
        #expect(throws: PanelLayoutError.invalid) { try PanelLayout(rows: [.init(slots: [nil, nil])]).validate(for: .codex) }
        #expect(throws: PanelLayoutError.invalid) { try PanelLayout.standard(for: .desktop).validate(for: .codex) }
    }
}
