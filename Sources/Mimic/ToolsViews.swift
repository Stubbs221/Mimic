// Created by Василий Маслов on 07.10.2026.
import SwiftUI
import MimicCore

// MARK: - Favorites and catalog

struct ToolsCompactView: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var preferences: ToolsPreferencesModel
    let full: Bool
    private var theme = MimicTheme()
    @FocusState private var focusedTool: ProjectTool?

    var body: some View {
        ToolsCompactLayout {
            ForEach(self.preferences.value.favorites, id: \.self) { tool in
                Button { self.model.openProjectTool(tool) } label: {
                    HStack(spacing: 8) {
                        ToolCompactIcon(tool: tool)
                        Text(text(tool.titleKey)).mimicFont(.body).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        Spacer(minLength: 2)
                        if self.full {
                            if let record = self.model.toolRecord(tool) {
                                ToolStatusText(record: record, compact: true).fixedSize(horizontal: true, vertical: false)
                            } else {
                                Text(text(tool.descriptionKey)).foregroundStyle(theme.color("muted"))
                                    .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                            }
                        }
                        Group {
                            if let record = self.model.toolRecord(tool) { ToolStatusIcon(status: record.status, compact: true) }
                            else { Color.clear.accessibilityHidden(true) }
                        }.frame(width: 14, height: 14).fixedSize()
                    }.mimicFont(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(ToolsFavoriteButtonStyle(focused: self.focusedTool == tool))
                    .focusable().focusEffectDisabled().focused($focusedTool, equals: tool)
                    .onKeyPress(.space) { self.model.openProjectTool(tool, source: .keyboard); return .handled }
                    .onKeyPress(.return) { self.model.openProjectTool(tool, source: .keyboard); return .handled }
                    .background(PanelControlRegion())
                    .help(self.toolHelp(tool)).accessibilityIdentifier("tools.favorite." + tool.rawValue)
                    .accessibilityLabel(text(tool.titleKey)).accessibilityValue(self.toolHelp(tool))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // Isolate favorite labels, hints and identifiers from the enclosing draggable grid.
            .accessibilityElement(children: .contain)
            .transaction { $0.animation = nil }
    }

    private func toolHelp(_ tool: ProjectTool) -> String {
        var parts = [text(tool.titleKey), text(tool.descriptionKey)]
        if let record = self.model.toolRecord(tool) {
            parts.append(text("status." + record.status.rawValue))
            if let duration = record.duration { parts.append(ciElapsed(duration)) }
        }
        return parts.joined(separator: "\n")
    }
}

/// Explicit row proposals keep task annotations from influencing how the available height is shared.
struct ToolsCompactLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 214, height: 112))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let spacing: CGFloat = 8
        let height = max(0, (bounds.height - CGFloat(subviews.count - 1) * spacing) / CGFloat(subviews.count))
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + CGFloat(index) * (height + spacing)),
                          anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
        }
    }
}

/// T4 keeps a neutral row and puts the accent behind its tool symbol.
private struct ToolCompactIcon: View {
    let tool: ProjectTool
    private var theme = MimicTheme()
    // Preserve the approved Figma vectors; other tools retain their existing system symbols.
    private static let images: [ProjectTool: NSImage] = Dictionary(uniqueKeysWithValues:
        [ProjectTool.generation, .localization, .format].map { tool in
            (tool, NSImage(contentsOf: Bundle.module.url(forResource: "tool-" + tool.rawValue, withExtension: "svg")!)!)
        })
    var body: some View {
        Group {
            if let image = Self.images[tool] { Image(nsImage: image).renderingMode(.template).resizable().frame(width: 16, height: 16) }
            else { Image(systemName: ActionPresentation.symbol(tool.action)) }
        }.foregroundStyle(theme.color("muted"))
            .frame(width: 24, height: 20)
            .background(theme.color("accentSoft"), in: RoundedRectangle(cornerRadius: 6))
            .fixedSize().accessibilityHidden(true)
    }
}

/// Hover, press and keyboard focus respond immediately without changing row geometry.
private struct ToolsFavoriteButtonStyle: ButtonStyle {
    private var theme = MimicTheme()
    private var accessibility = MimicAccessibility()
    @Environment(\.isEnabled) private var enabled
    let focused: Bool
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(self.theme.color(self.enabled && (self.hovered || configuration.isPressed) ? "accentSoft" : "paper"), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(self.theme.color(self.focused ? "accent" : "ink").opacity(self.focused ? 1 : self.accessibility.increasedContrast ? 0.5 : 0), lineWidth: self.focused ? 2 : 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { self.hovered = $0 }
    }
}

struct ToolsDetailView: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        if let tool = model.selectedProjectTool {
            VStack(alignment: .leading, spacing: 12) {
                Button { model.selectedProjectTool = nil } label: { Label(text("tools.back"), systemImage: "chevron.left") }
                    .buttonStyle(BootstrapControlStyle()).accessibilityIdentifier("tools.back")
                Label(text(tool.titleKey), systemImage: ActionPresentation.symbol(tool.action)).mimicFont(.heading)
                ToolContent(model: model, action: tool.action)
            }
        } else { ToolsCatalogView(model: model, preferences: model.toolsPreferences) }
    }
}

struct ToolsCatalogView: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var preferences: ToolsPreferencesModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ProjectTool.allCases.filter { !$0.isCleanup }, id: \.self) { row($0) }
            Divider().padding(.vertical, 4)
            ForEach(ProjectTool.allCases.filter(\.isCleanup), id: \.self) { row($0) }
            if !preferences.message.isEmpty { Text(preferences.message).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.accessibilityIdentifier("tools.catalog")
    }
    private func row(_ tool: ProjectTool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Button { model.openProjectTool(tool) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ActionPresentation.symbol(tool.action)).foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(text(tool.titleKey)).mimicFont(.body, weight: .medium)
                        Text(text(tool.descriptionKey)).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(RowButtonStyle()).accessibilityIdentifier("tools.catalog." + tool.rawValue)
            if let index = preferences.value.favorites.firstIndex(of: tool) {
                control("arrow.up", text("tools.move.up"), disabled: index == 0) { preferences.move(tool, by: -1) }
                control("arrow.down", text("tools.move.down"), disabled: index == preferences.value.favorites.count - 1) { preferences.move(tool, by: 1) }
            }
            control(preferences.value.favorites.contains(tool) ? "star.fill" : "star", text(preferences.value.favorites.contains(tool) ? "tools.unpin" : "tools.pin"), disabled: !preferences.value.favorites.contains(tool) && preferences.value.favorites.count == 3) { preferences.toggle(tool) }
                .accessibilityIdentifier("tools.pin." + tool.rawValue)
        }
    }
    private func control(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 26) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label).disabled(disabled)
    }
}

// MARK: - Exact task state

struct ToolStatusIcon: View {
    let status: TaskStatus
    var compact = false
    private var theme = MimicTheme()
    var body: some View {
        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
            .help(text("status." + status.rawValue)).accessibilityLabel(text("status." + status.rawValue))
    }
    private var symbol: String {
        switch status {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .interrupted: "pause.circle"
        }
    }
    private var color: Color {
        if compact {
            return theme.color(status == .failed || status == .interrupted ? "warning" : status == .succeeded ? "success" : status == .running ? "accent" : "muted")
        }
        return status == .failed || status == .interrupted ? .orange : status == .succeeded ? .green : .secondary
    }
}

struct ToolStatusText: View {
    let record: TaskRecord
    var compact = false
    private var theme = MimicTheme()
    var body: some View {
        MimicActivityClock(running: record.status == .running && record.startedAt != nil) { now in
            HStack(spacing: 4) {
                Text(text("status." + record.status.rawValue)).lineLimit(1)
                if let start = record.startedAt {
                    if compact { Text("·").accessibilityHidden(true) }
                    Text(ciElapsed((record.finishedAt ?? now).timeIntervalSince(start))).monospacedDigit().fixedSize()
                }
            }.mimicFont(.caption).foregroundStyle(compact ? theme.color("muted") : .secondary)
        }.mimicImmediate()
    }
}

struct ToolTaskView: View {
    @ObservedObject var model: TaskCoordinator
    let tool: ProjectTool
    var body: some View {
        if let record = model.toolRecord(tool) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { ToolStatusIcon(status: record.status); ToolStatusText(record: record); Spacer(minLength: 0) }
                if [.queued, .running].contains(record.status) {
                    if record.status == .queued { Text(text("tools.queue.explanation")).mimicFont(.caption).foregroundStyle(.secondary) }
                    Button(text("cancel")) { model.cancel(id: record.id) }.buttonStyle(BootstrapControlStyle())
                }
                Button(text("tools.task.open")) { model.showHistory(id: record.id) }.buttonStyle(BootstrapControlStyle())
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("tools.task." + tool.rawValue)
        }
    }
}
