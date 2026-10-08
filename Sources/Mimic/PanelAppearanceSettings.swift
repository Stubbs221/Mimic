// Created by Василий Маслов on 08.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Icon and interface choices remain independent inside one appearance section.
struct AppearanceSettingsContent: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard { AppIconSettingsView(settings: model.appIconSettings, framed: false) }
            SettingsCard { PanelAppearanceSettings(model: model, showsPreviews: false) }
        }.accessibilityIdentifier("settings.appearance")
    }
}

/// Compact radio cards use inert previews, never a live coordinator or simulator connection.
struct PanelAppearanceSettings: View {
    @ObservedObject var model: TaskCoordinator
    var showsPreviews = true
    @State private var previewsExpanded = false
    @Environment(\.mimicTextScale) private var textScale
    @FocusState private var focused: PanelAppearance?
    private var theme = MimicTheme()
    private var accessibility = MimicAccessibility()
    private var accent: Color { theme.tiled ? theme.color("accent") : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("appearance.title")).mimicFont(.heading).accessibilityAddTraits(.isHeader)
            // Large text stacks the same controls instead of squeezing their labels.
            if showsPreviews {
                previewChoices
            } else {
                VStack(spacing: 8) {
                    ForEach(PanelAppearance.allCases, id: \.self) { value in choice(value, preview: false) }
                }.accessibilityIdentifier("appearance.selection")
                DisclosureGroup(text("settings.appearance.previews"), isExpanded: $previewsExpanded) {
                    previewChoices.padding(.top, 8)
                }.mimicFont(.caption)
            }
            Text(text("appearance.shared")).mimicFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.id("appearance.settings").accessibilityIdentifier("appearance.settings")
    }

    private var previewChoices: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: textScale > 1.2 ? 1 : 2), spacing: 12) {
            ForEach(PanelAppearance.allCases, id: \.self) { value in choice(value, preview: true) }
        }.accessibilityIdentifier("appearance.previews")
    }

    private func choice(_ value: PanelAppearance, preview: Bool) -> some View {
        let selected = model.appearance.selection == value
        return Button { select(value) } label: {
            VStack(alignment: .leading, spacing: 8) {
                if preview { PanelAppearanceMiniature(appearance: value) }
                HStack(alignment: .center, spacing: 8) {
                    Text(text("appearance." + value.rawValue)).mimicFont(.heading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? accent : Color.secondary)
                        .accessibilityHidden(true)
                }.frame(minHeight: 20 * textScale)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? (theme.tiled ? theme.color("accentSoft") : accent.opacity(0.08)) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? accent : Color.secondary.opacity(accessibility.increasedContrast ? 0.65 : 0.35), lineWidth: selected ? 2 : 1))
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(focused == value ? accent : Color.clear, lineWidth: 2).padding(-3))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).focusable().focused($focused, equals: value)
            .onKeyPress(.leftArrow) { move(from: value); return .handled }
            .onKeyPress(.rightArrow) { move(from: value); return .handled }
            .onKeyPress(.space) { select(value); return .handled }
            .accessibilityLabel(text("appearance." + value.rawValue))
            .accessibilityValue(text(selected ? "app.icon.selected" : "app.icon.unselected"))
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("appearance." + value.rawValue)
    }

    private func select(_ value: PanelAppearance) {
        focused = value
        model.panelLayout.cancelDrag()
        model.appearance.select(value)
    }

    private func move(from value: PanelAppearance) {
        let choices = PanelAppearance.allCases
        guard let index = choices.firstIndex(of: value) else { return }
        select(choices[(index + 1) % choices.count])
    }
}

// MARK: - Inert interface miniature

/// Fixed demo data scales as a whole so miniature typography never follows accessibility text sizing.
private struct PanelAppearanceMiniature: View {
    let appearance: PanelAppearance
    @Environment(\.colorScheme) private var scheme
    private let canvas = CGSize(width: 206, height: 188)
    private var tiled: Bool { appearance == .tileGrid }

    var body: some View {
        GeometryReader { proxy in
            content.frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                .scaleEffect(proxy.size.width / canvas.width, anchor: .topLeading)
        }.aspectRatio(canvas.width / canvas.height, contentMode: .fit)
            .accessibilityHidden(true).allowsHitTesting(false)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Mimic · DemoApp").font(.system(size: 13, weight: .semibold))
            Text("⑂ feature/new-idea").font(.system(size: 9)).foregroundStyle(color("muted"))
            tile("Подготовка проекта", detail: "DemoApp · iOS / tvOS", block: .bootstrap)
            HStack(spacing: 5) {
                tile("Инструменты", detail: "SwiftFormat", block: .utils)
                tile("Сборки и тесты", detail: "Debug · iPhone 18 Pro", block: .builds)
            }
            HStack(spacing: 5) {
                tile("CI · DemoApp", detail: "#2841 · В работе", block: .ci)
                tile("Симулятор", detail: "iPhone 18 Pro", block: .simulators)
            }
        }.padding(8).foregroundStyle(color("ink"))
            .background(color("paper"), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color("line"), lineWidth: 0.75))
    }

    private func tile(_ title: String, detail: String, block: PanelBlockKind) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
            Text(detail).font(.system(size: 7)).foregroundStyle(color("muted")).lineLimit(1)
        }.frame(maxWidth: .infinity, minHeight: 25, alignment: .leading).padding(6)
            .background(tileColor(block), in: RoundedRectangle(cornerRadius: tiled ? 9 : 6))
            .overlay(RoundedRectangle(cornerRadius: tiled ? 9 : 6).strokeBorder(tiled ? Color.clear : color("line"), lineWidth: 0.75))
    }

    private func tileColor(_ block: PanelBlockKind) -> Color {
        if tiled { return color("surface") }
        var fill = NSColor.controlBackgroundColor
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            fill = NSColor.controlBackgroundColor.blended(withFraction: scheme == .dark ? 0.10 : 0.06,
                                                         of: PanelCardPalette.native(block)) ?? .controlBackgroundColor
        }
        return Color(nsColor: fill)
    }

    private func color(_ key: String) -> Color {
        if tiled { return Color(nsColor: MimicTheme.native(key, dark: scheme == .dark)) }
        switch key {
        case "paper": return Color(nsColor: .windowBackgroundColor)
        case "surface": return Color(nsColor: .controlBackgroundColor)
        case "ink": return Color(nsColor: .labelColor)
        case "muted": return Color(nsColor: .secondaryLabelColor)
        default: return Color(nsColor: .separatorColor)
        }
    }
}
