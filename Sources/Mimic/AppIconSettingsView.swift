//
//  AppIconSettingsView.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import SwiftUI

/// Three equal, keyboard-accessible choices stay inside the existing settings surface.
struct AppIconSettingsView: View {
    @ObservedObject var settings: AppIconSettings
    var framed = true
    @FocusState private var focusedStyle: AppIconStyle?

    var body: some View {
        SettingsFormContainer(framed: self.framed) {
            VStack(alignment: .leading, spacing: 8) {
                Label(text("app.icon.title"), systemImage: "square.dashed").font(MimicMetrics.heading)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(AppIconStyle.allCases) { style in
                        self.choice(style)
                    }
                }
                Text(text("app.icon.detail")).font(MimicMetrics.secondary).foregroundStyle(.secondary)
                if let error = self.settings.error {
                    Text(error).font(MimicMetrics.secondary).foregroundStyle(.orange)
                        .accessibilityIdentifier("app.icon.error")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("app.icon.settings")
    }

    private func choice(_ style: AppIconStyle) -> some View {
        let selected = self.settings.style == style
        return Button {
            self.focusedStyle = style
            self.settings.select(style)
        } label: {
            VStack(spacing: 4) {
                if let image = self.settings.preview(style) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(width: 64, height: 64).accessibilityHidden(true)
                } else {
                    Image(systemName: "photo").frame(width: 64, height: 64).accessibilityHidden(true)
                }
                Text(text(style.localizationKey)).font(MimicMetrics.secondary)
                    .multilineTextAlignment(.center).lineLimit(2).frame(minHeight: 28)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused(self.$focusedStyle, equals: style)
        .onKeyPress(.leftArrow) { self.move(from: style, offset: -1); return .handled }
        .onKeyPress(.rightArrow) { self.move(from: style, offset: 1); return .handled }
        .onKeyPress(.space) { self.settings.select(style); return .handled }
        .accessibilityLabel(text(style.localizationKey))
        .accessibilityValue(text(selected ? "app.icon.selected" : "app.icon.unselected"))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("app.icon." + style.rawValue)
    }

    /// Arrow keys follow radio-group behavior while focus remains inside the icon choices.
    private func move(from style: AppIconStyle, offset: Int) {
        let styles = AppIconStyle.allCases
        guard let index = styles.firstIndex(of: style) else { return }
        let next = styles[(index + offset + styles.count) % styles.count]
        self.focusedStyle = next
        self.settings.select(next)
    }
}
