// Created by Василий Маслов on 08.10.2026.
import Foundation
import Observation

/// Presentation only: both styles use the same execution state and surface layouts.
public enum PanelAppearance: String, Codable, CaseIterable, Sendable {
    case tileGrid, legacy
    public var panelWidth: Double { PanelDesignTokens.shared.metrics[self == .tileGrid ? "panelWidth" : "legacyPanelWidth"]! }
}

/// The same approved design values are bundled in native and in the generated Web resource.
public struct PanelDesignTokens: Decodable, Sendable {
    public let palettes: [String: [String: String]]
    public let metrics: [String: Double]
    public static let shared: Self = {
        guard let url = Bundle.module.url(forResource: "panel-design-tokens", withExtension: "json"),
              let data = try? Data(contentsOf: url), let tokens = try? JSONDecoder().decode(Self.self, from: data) else {
            preconditionFailure("Missing bundled panel design tokens")
        }
        return tokens
    }()
}

/// One Mac-wide preference. Layouts and per-chat drafts are deliberately stored elsewhere.
@MainActor @Observable public final class PanelAppearanceStore {
    public private(set) var selection: PanelAppearance
    @ObservationIgnored private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selection = defaults.string(forKey: "panelAppearance").map { PanelAppearance(rawValue: $0) ?? .legacy } ?? .tileGrid
    }
    public func select(_ appearance: PanelAppearance) {
        guard selection != appearance else { return }
        defaults.set(appearance.rawValue, forKey: "panelAppearance")
        selection = appearance
    }
}
