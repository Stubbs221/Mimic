// Created by Василий Маслов on 08.10.2026.
import Foundation
import Observation

/// Presentation only: native and Codex share the selection, never their surface layouts.
public enum PanelAppearance: String, Codable, CaseIterable, Sendable {
    case tileGrid, legacy, windows95, windowsXP
    public var isRetro: Bool { self == .windows95 || self == .windowsXP }
    /// The existing Tile Grid content graph also hosts retro, retaining forms and renderers.
    public var usesTileGrid: Bool { self != .legacy }
    public var compatibleAppearance: Self { isRetro ? .tileGrid : self }
    public var panelWidth: Double { PanelDesignTokens.shared.metrics[self == .tileGrid ? "panelWidth" : "legacyPanelWidth"]! }
}

/// The same approved design values are bundled in native and in the generated Web resource.
public struct PanelDesignTokens: Decodable, Sendable {
    public let palettes: [String: [String: String]]
    public let metrics: [String: Double]
    public static let shared: Self = {
        guard let url = MimicCoreResources.bundle.url(forResource: "panel-design-tokens", withExtension: "json"),
              let data = try? Data(contentsOf: url), let tokens = try? JSONDecoder().decode(Self.self, from: data) else {
            preconditionFailure("Missing bundled panel design tokens")
        }
        return tokens
    }()
}

/// Standalone stores retain UserDefaults compatibility; the app connects to its atomic shared owner.
@MainActor @Observable public final class PanelAppearanceStore {
    private var localSelection: PanelAppearance
    private var shared: CodexPanelAppearanceStore?
    private var deferredPresentation: PanelAppearance?
    public private(set) var saveFailed = false
    public var selection: PanelAppearance {
        deferredPresentation ?? shared.flatMap { PanelAppearance(rawValue: $0.value.selection.rawValue) } ?? localSelection
    }
    public var revision: Int? { shared?.value.revision }
    public var persistenceFailed: Bool { shared?.persistenceFailed ?? false }
    @ObservationIgnored private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.localSelection = defaults.string(forKey: "panelAppearance").map { PanelAppearance(rawValue: $0) ?? .legacy } ?? .tileGrid
    }
    /// The JSON's confirmed selection takes precedence. Connecting never writes or migrates layouts.
    public func connect(to store: CodexPanelAppearanceStore) {
        self.shared = store
        self.saveFailed = false
    }
    /// Hold only native presentation while a field editor owns marked text; shared selection is already saved.
    public func deferPresentation() { deferredPresentation = selection }
    public func resumePresentation() { deferredPresentation = nil }
    public func select(_ appearance: PanelAppearance) {
        if let shared {
            do {
                guard let choice = CodexPanelAppearance(rawValue: appearance.rawValue) else { return }
                try shared.select(choice, expectedRevision: shared.value.revision)
                saveFailed = false
            } catch { saveFailed = true }
            return
        }
        guard selection != appearance else { return }
        defaults.set(appearance.rawValue, forKey: "panelAppearance")
        localSelection = appearance
    }
}
