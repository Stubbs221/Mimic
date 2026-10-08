// Created by Василий Маслов on 08.10.2026.
import SwiftUI
import AppKit
import MimicCore

/// Approved B2 chrome keeps project, branch and tile controls in one pinned row.
struct TileGridIdentity: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var layout: PanelLayoutController
    @Environment(\.mimicTextScale) private var textScale
    init(model: TaskCoordinator) { self.model = model; self.layout = model.panelLayout }
    private var projectName: String { model.project.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Mimic" }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(projectName).mimicFont(.heading).lineLimit(1).truncationMode(.middle)
                    .frame(width: min(120, ceil((projectName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13 * textScale, weight: .semibold)]).width) + 2), alignment: .leading)
                    .help(model.project?.path ?? "Mimic").accessibilityIdentifier("panel.project")
                Button {
                    layout.cancelPresentation()
                    model.toggleSection(.branches)
                    if model.expandedSection == .branches { model.loadBranches() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(model.project?.branch ?? text("project.no.branch")).lineLimit(1).truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down").font(.system(size: 9 * textScale))
                    }.frame(minHeight: max(32, 24 * textScale)).contentShape(Rectangle())
                }.buttonStyle(.plain).mimicFont(.caption).foregroundStyle(.secondary)
                    .frame(minWidth: 0, maxWidth: 288 * textScale, alignment: .leading).layoutPriority(-1)
                    .disabled(model.project == nil || model.switchingBranch)
                    .help(model.project?.branch ?? text("branch.choose"))
                    .accessibilityIdentifier("branch.toggle").accessibilityLabel(text("branch.choose"))
                    .accessibilityValue(model.project?.branch ?? "")
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    MimicChromeIconButton(symbol: "plus", label: text("panel.tiles.add"), identifier: "panel.tiles.add", selected: layout.catalogVisible) {
                        if model.expandedSection == .branches { model.expandedSection = nil }
                        layout.toggleCatalog()
                    }
                    MimicChromeIconButton(symbol: "minus", label: text("panel.tiles.remove"), identifier: "panel.tiles.remove", selected: layout.removing) {
                        if model.expandedSection == .branches { model.expandedSection = nil }
                        layout.toggleRemoval()
                    }.disabled(layout.saved.blocks.isEmpty)
                }.disabled(model.panelPage != .home || !model.hasCompatibleProfile || layout.editing || layout.dragging != nil)
                MimicChromeIconButton(symbol: "gearshape", label: text("settings"), identifier: "settings.toggle", selected: model.panelPage == .settings) {
                    layout.cancelPresentation(); model.toggleSettings()
                }
            }.frame(minHeight: max(32, 24 * textScale)).accessibilityIdentifier("panel.chrome.b2")
            if let project = model.project, let operation = model.branchSwitch.latest(path: project.path) {
                BranchSwitchStatus(model: model, operation: operation)
            }
        }
    }
}

// MARK: - Chrome controls

struct MimicChromeIconButton: View {
    let symbol: String
    let label: String
    let identifier: String
    var selected = false
    let action: () -> Void
    @Environment(\.mimicTextScale) private var textScale
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16 * textScale)) }
            .buttonStyle(MimicChromeButtonStyle(selected: selected, iconOnly: true))
            .help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
            .accessibilityValue(selected ? text("panel.expanded") : "")
    }
}

/// Frequent chrome interactions respond immediately, including keyboard activation.
struct MimicChromeButtonStyle: ButtonStyle {
    var selected = false
    var iconOnly = false
    private var theme = MimicTheme()
    private var accessibility = MimicAccessibility()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.mimicTextScale) private var textScale
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, iconOnly ? 0 : 8)
            .frame(width: iconOnly ? max(32, 20 * textScale + 12) : nil, height: max(32, 24 * textScale))
            .foregroundStyle(theme.color("ink"))
            .background(theme.color(configuration.isPressed ? "line" : "accentSoft").opacity(hovered || selected || configuration.isPressed ? 1 : 0), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color("accent").opacity(selected || focused || accessibility.increasedContrast ? 1 : 0), lineWidth: 1))
            .opacity(enabled ? 1 : 0.35).scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10)).onHover { hovered = $0 }
    }
}

// MARK: - Available tiles

/// Catalogue selections change only persisted placement, never the tool's draft or execution owner.
struct PanelTileCatalog: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var layout: PanelLayoutController
    @State private var search = ""
    private var blocks: [PanelBlockKind] { layout.availableBlocks.filter { search.isEmpty || text($0.titleKey).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("panel.tiles.add")).mimicFont(.heading).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                MimicChromeIconButton(symbol: "xmark", label: text("panel.chrome.close"), identifier: "panel.catalog.close") { layout.cancelPresentation() }
            }
            if layout.availableBlocks.isEmpty {
                Text(text("panel.tiles.all.added")).mimicFont(.body)
                Text(text("panel.tiles.all.added.help")).mimicFont(.caption).foregroundStyle(.secondary)
            } else {
                TextField(text("panel.tiles.search"), text: $search).textFieldStyle(.roundedBorder).mimicFont(.body)
                    .accessibilityIdentifier("panel.catalog.search")
                if blocks.isEmpty { Text(text("panel.tiles.no.results")).mimicFont(.body).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(blocks, id: \.self) { block in
                            Button {
                                if layout.add(block) { model.scrollPanel(to: block.scrollID) }
                            } label: {
                                HStack { Text(text(block.titleKey)); Spacer(minLength: 8); Image(systemName: "plus") }
                                    .mimicFont(.body).padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets()))
                                .accessibilityIdentifier("panel.catalog." + block.rawValue)
                        }
                    }
                }.frame(maxHeight: 280).scrollIndicators(.hidden)
            }
            if !layout.message.isEmpty { Text(layout.message).mimicFont(.caption).foregroundStyle(.orange) }
        }
        .accessibilityIdentifier("panel.catalog")
    }
}
