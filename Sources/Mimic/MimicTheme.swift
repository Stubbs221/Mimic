// Created by Василий Маслов on 08.10.2026.
import AppKit
import SwiftUI
import MimicCore

private struct PanelAppearanceKey: EnvironmentKey {
    static let defaultValue = PanelAppearance.legacy
}
private struct MimicTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}
extension EnvironmentValues {
    var mimicPanelAppearance: PanelAppearance {
        get { self[PanelAppearanceKey.self] }
        set { self[PanelAppearanceKey.self] = newValue }
    }
    var mimicTextScale: CGFloat {
        get { self[MimicTextScaleKey.self] }
        set { self[MimicTextScaleKey.self] = newValue }
    }
}

/// macOS does not scale ScaledMetric through Dynamic Type. AppKit owns its preferred font.
/// A shared factor lets text and grid geometry grow together; previews can inject 200%.
struct MimicTextSizingRoot: ViewModifier {
    @Environment(\.mimicTextScale) private var inherited
    @State private var preferred = Self.preferredScale
    private static var preferredScale: CGFloat { max(1, NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize / 13) }
    func body(content: Content) -> some View {
        content.environment(\.mimicTextScale, max(inherited, preferred))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in preferred = Self.preferredScale }
    }
}

/// Semantic B colors share their source with Web; legacy keeps AppKit's adaptive materials.
struct MimicTheme: DynamicProperty {
    @Environment(\.mimicPanelAppearance) var appearance
    @Environment(\.colorScheme) private var scheme
    var tiled: Bool { appearance == .tileGrid }
    var cardRadius: CGFloat { tiled ? Self.metric("cardRadius") : 14 }
    var panelRadius: CGFloat { tiled ? Self.metric("panelRadius") : 12 }
    static func metric(_ key: String) -> CGFloat { PanelDesignTokens.shared.metrics[key]! }
    func color(_ key: String) -> Color { Color(nsColor: Self.native(key, dark: scheme == .dark)) }
    /// Healthy providers retain distinct colors; warnings, stale and unknown stay semantic.
    func usageColor(_ state: AIUsagePace.State, provider: AIProvider) -> Color {
        switch state.severity {
        case .normal: color(provider == .codex ? "usagePurple" : "usageRose")
        case .warning: color("warning")
        case .critical: color("error")
        case nil: color("muted")
        }
    }
    static func native(_ key: String, dark: Bool) -> NSColor {
        let value = PanelDesignTokens.shared.palettes[dark ? "dark" : "light"]![key]!
        let hex = Int(value.dropFirst(), radix: 16)!
        return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static func adaptive(_ key: String) -> NSColor {
        NSColor(name: nil) { appearance in native(key, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) }
    }
}

/// Applying a preference updates the existing hierarchy, never its execution-owned children.
struct MimicAppearanceRoot: ViewModifier {
    let store: PanelAppearanceStore
    func body(content: Content) -> some View {
        content.environment(\.mimicPanelAppearance, store.selection)
            .modifier(MimicTextSizingRoot())
            .foregroundStyle(Color(nsColor: store.selection == .tileGrid ? MimicTheme.adaptive("ink") : .labelColor))
            .tint(Color(nsColor: store.selection == .tileGrid ? MimicTheme.adaptive("accent") : .systemIndigo))
    }
}

struct TileGridButtonStyle: ButtonStyle {
    var primary = false
    var selected = false
    var height: CGFloat = 32
    private var theme = MimicTheme()
    private var accessibility = MimicAccessibility()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false
    @Environment(\.mimicTextScale) private var textScale
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: MimicTheme.metric("body") * textScale, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: height)
            .foregroundStyle(theme.color(primary || selected ? "paper" : "ink"))
            .background(theme.color(primary || selected ? "ink" : hovered ? "accentSoft" : "paper"), in: RoundedRectangle(cornerRadius: MimicTheme.metric("controlRadius")))
            .overlay(RoundedRectangle(cornerRadius: MimicTheme.metric("controlRadius")).strokeBorder(theme.color("ink").opacity(focused ? 1 : accessibility.increasedContrast ? 0.5 : 0), lineWidth: focused ? 2 : 1))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: MimicTheme.metric("controlRadius"))).onHover { hovered = $0 }
    }
}

/// Auxiliary windows keep their native legacy controls and adopt B without replacing content.
struct MimicAuxiliaryButtonStyle: PrimitiveButtonStyle {
    private var theme = MimicTheme()
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if theme.tiled { Button(configuration).buttonStyle(TileGridButtonStyle()) }
        else { Button(configuration).buttonStyle(.automatic) }
    }
}

enum MimicFontRole { case body, caption, heading }
private struct MimicFont: ViewModifier {
    let role: MimicFontRole
    let weight: Font.Weight?
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var textScale
    func body(content: Content) -> some View {
        let size = role == .caption ? MimicTheme.metric("caption") : role == .heading ? MimicTheme.metric("heading") : theme.tiled ? MimicTheme.metric("body") : 12
        content.font(.system(size: size * (theme.tiled ? textScale : 1), weight: weight ?? (role == .heading ? .semibold : .regular)))
    }
}
extension View {
    /// Fixed legacy sizes and scalable B typography share one semantic vocabulary.
    func mimicFont(_ role: MimicFontRole, weight: Font.Weight? = nil) -> some View {
        modifier(MimicFont(role: role, weight: weight))
    }
}
