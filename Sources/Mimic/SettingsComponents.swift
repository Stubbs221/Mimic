//
//  SettingsComponents.swift
//  Mimic
//
//  Created by Василий Маслов on 08.10.2026.
import SwiftUI

// MARK: - Shared settings vocabulary

/// Settings use the same B surfaces in both panel appearances.
struct SettingsCard<Content: View>: View {
    private var theme = MimicTheme()
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(theme.color("surface"), in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Text keeps its natural height; an action moves below it when the pair cannot fit.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control
    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).mimicFont(.body).fixedSize(horizontal: false, vertical: true)
            if let detail { Text(detail).mimicFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) { label; control().fixedSize() }
            VStack(alignment: .leading, spacing: 8) { label; control() }
        }
    }
}

struct SettingsSwitch: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var identifier: String
    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - Category navigation

/// One grouped, left-aligned navigation surface replaces unrelated tabs and accordions.
struct SettingsCategoryNavigation: View {
    @ObservedObject var model: TaskCoordinator
    var compact = false
    private var theme = MimicTheme()
    var body: some View {
        Group {
            if compact {
                Picker(text("settings.category"), selection: Binding(
                    get: { model.settingsGroup ?? .application },
                    set: { model.openSettings(group: $0) }
                )) {
                    ForEach(SettingsGroup.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).mimicFont(.body)
                    .accessibilityIdentifier("settings.categories.compact")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SettingsGroup.allCases) { group in
                        Button { model.openSettings(group: group) } label: {
                            Text(group.title).mimicFont(.body)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(theme.color(model.settingsGroup == group ? "paper" : "ink"))
                                .background(model.settingsGroup == group ? theme.color("ink") : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier(group.scrollID + ".tab")
                            .accessibilityAddTraits(model.settingsGroup == group ? .isSelected : [])
                    }
                }.padding(8).frame(width: 132)
                    .background(theme.color("surface"), in: RoundedRectangle(cornerRadius: 18))
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("settings.categories")
    }
}
