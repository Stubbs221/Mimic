// Created by Василий Маслов on 08.10.2026.
import Foundation
import Testing
@testable import MimicCore

@MainActor struct PanelAppearanceTests {
    @Test func defaultAndSavedChoiceDoNotMigrateEitherLayout() throws {
        let suite = "MimicAppearance-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let layouts = PanelLayoutStore(defaults: defaults)
        var desktop = layouts.load(.desktop); desktop.remove(.ci)
        desktop = try layouts.save(desktop, for: .desktop, expectedRevision: 0)
        let codex = layouts.load(.codex)
        let appearance = PanelAppearanceStore(defaults: defaults)
        #expect(appearance.selection == .tileGrid)
        appearance.select(.legacy)
        #expect(PanelAppearanceStore(defaults: defaults).selection == .legacy)
        appearance.select(.tileGrid)
        #expect(PanelAppearanceStore(defaults: defaults).selection == .tileGrid)
        #expect(layouts.load(.desktop) == desktop && layouts.load(.codex) == codex)
        #expect(desktop.version == 1 && codex.version == 1)
    }
    @Test func sharedTokensCoverBothThemesAndAcceptedGeometry() throws {
        let tokens = PanelDesignTokens.shared
        #expect(PanelAppearance.tileGrid.panelWidth == 560 && PanelAppearance.legacy.panelWidth == 520)
        #expect(tokens.metrics["collapsedHeight"] == 160)
        #expect(tokens.metrics["inset"] == 16 && tokens.metrics["gap"] == 12)
        #expect(tokens.palettes["light"]?.keys.sorted() == tokens.palettes["dark"]?.keys.sorted())
        for palette in tokens.palettes.values {
            for value in palette.values { #expect(value.wholeMatch(of: /#[0-9a-fA-F]{6}/) != nil) }
            #expect(palette["terminal"] != palette["surface"])
            #expect(palette["warning"] != palette["usagePurple"])
        }
    }
}
