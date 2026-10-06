//
//  Design.swift
//  Mimic
//
//  Created by Василий Маслов on 01.10.2026.
import AppKit
import SwiftUI
import Observation
import MimicCore

/// One expanded area in the menu panel; execution state is owned separately.
enum PanelSection: Equatable {
    case tool(MimicAction)
    case branches
    case simulators
    case tasks
    case builds
    case ci
    case usage

    var scrollID: String {
        switch self {
        case let .tool(action): "section." + action.rawValue
        case .branches: "section.branches"
        case .simulators: "section.simulators"
        case .builds: "section.builds"
        case .tasks: "section.tasks"
        case .ci: "section.ci"
        case .usage: "section.usage"
        }
    }
}

/// Page selection is independent of the expanded working section and execution state.
enum PanelPage: Equatable { case home, settings }

enum SettingsGroup: String, CaseIterable, Identifiable {
    case application, aiIntegrations, ci, environment
    var id: String { self.rawValue }
    var title: String { text("settings.group." + self.rawValue) }
    var scrollID: String { "settings.group." + self.rawValue }
}

enum TaskHistoryFilter: String, CaseIterable {
    case all
    case active
    case failed
}

enum ActionPresentation {
    static func symbol(_ action: MimicAction) -> String {
        switch action {
        case .bootstrap: "shippingbox"
        case .generation: "square.stack.3d.up"
        case .localization: "character.bubble"
        case .proto: "arrow.triangle.branch"
        case .format: "text.alignleft"
        case .fullCleanup, .derivedDataCleanup: "trash"
        case .simulatorBoot,
             .simulatorShutdown: "iphone"
        }
    }

    static func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .succeeded: .green
        case .failed: .red
        case .running,
             .queued: .indigo
        case .cancelled,
             .interrupted: .secondary
        }
    }

    static func statusSymbol(_ status: TaskStatus) -> String {
        switch status {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .running: "circle.dotted"
        case .queued: "clock"
        case .cancelled,
             .interrupted: "stop.circle"
        }
    }
}

/// Shared geometry keeps the two panel widths and readable content in one visual system.
enum MimicMetrics {
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
    static let large: CGFloat = 12
    static let documentInset: CGFloat = 16
    static let panelWidth: CGFloat = 520
    static let cardWidth: CGFloat = 320
    /// Width is configurable; every collapsed grid card shares one vertical rhythm.
    static let collapsedCardHeight: CGFloat = 170
    static let surfaceRadius: CGFloat = 10
    static let footerRow: CGFloat = 28
    static let footerHeight: CGFloat = 76
    static let body = Font.system(size: 12)
    static let secondary = Font.system(size: 11)
    static let heading = Font.system(size: 13, weight: .semibold)
}

/// Content remains opaque; the same visible boundary is shared by document cards and the pinned card.
struct MimicCardBackground: ViewModifier {
    private var accessibility = MimicAccessibility()
    func body(content: Content) -> some View {
        content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: MimicMetrics.surfaceRadius))
            .overlay(RoundedRectangle(cornerRadius: MimicMetrics.surfaceRadius)
                .strokeBorder(.primary.opacity(self.accessibility.increasedContrast ? 0.45 : 0.12), lineWidth: 1))
    }
}

private struct InsideSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Nested content groups become separators, rather than another framed card.
    var mimicInsideSurface: Bool {
        get { self[InsideSurfaceKey.self] }
        set { self[InsideSurfaceKey.self] = newValue }
    }
}

/// A topic owns one surface; existing subgroups retain their content without nested frames.
struct Surface<Content: View>: View {
    @Environment(\.mimicInsideSurface) private var nested
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        Group {
            if self.nested {
                VStack(alignment: .leading, spacing: MimicMetrics.large) {
                    Divider()
                    self.content
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                self.content.padding(MimicMetrics.large).frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(MimicCardBackground())
            }
        }.environment(\.mimicInsideSurface, true)
    }
}

/// Semantic press/focus state is immediate; pointer feedback has a short visual transition.
struct RowButtonStyle: ButtonStyle {
    private let contentInsets: EdgeInsets
    private var accessibility = MimicAccessibility()
    private var motion = MimicMotion()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State
    private var hovered = false

    /// Pre-sized labels pass empty insets; other labels share padding in every interaction state.
    init(contentInsets: EdgeInsets = EdgeInsets(top: MimicMetrics.small, leading: MimicMetrics.medium, bottom: MimicMetrics.small, trailing: MimicMetrics.medium)) {
        self.contentInsets = contentInsets
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(self.contentInsets).foregroundStyle(Color.primary)
            .opacity(!self.enabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed && !self.accessibility.reduceMotion ? 0.99 : 1)
            .background(.primary.opacity(self.enabled && self.hovered ? self.accessibility.increasedContrast ? 0.12 : 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(self.focused ? 0.8 : 0), lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .animation(self.motion.policy(.current).animation(.feedback), value: configuration.isPressed)
            .animation(self.motion.policy(.pointer).animation(.feedback), value: self.hovered)
            .onHover { self.hovered = $0 }
    }
}

struct ActionIcon: View {
    let action: MimicAction
    var body: some View {
        Image(systemName: ActionPresentation.symbol(self.action))
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let status: TaskStatus
    var body: some View {
        Label(text("status." + self.status.rawValue), systemImage: ActionPresentation.statusSymbol(self.status))
            .font(MimicMetrics.secondary.weight(.medium)).foregroundStyle(ActionPresentation.statusColor(self.status)).mimicStatus(self.status)
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.title).font(.system(size: 21, weight: .semibold)).tracking(-0.35)
            Text(self.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: self.symbol).font(.system(size: 30)).foregroundStyle(.indigo).padding(16)
                .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            Text(self.title).font(.headline)
            Text(self.message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
        }.frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}

// MARK: - Materials and controls

/// Solid native primary controls retain their accent over readable content; glass belongs to chrome.
/// All controls preserve native keyboard semantics and immediate availability.
struct MimicButtonStyle: PrimitiveButtonStyle {
    var primary = false
    var selected = false
    var icon = false
    var height: CGFloat = MimicMetrics.footerRow

    init(primary: Bool = false, selected: Bool = false, icon: Bool = false, height: CGFloat = MimicMetrics.footerRow) {
        self.primary = primary
        self.selected = selected
        self.icon = icon
        self.height = height
    }

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if self.primary || self.selected {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label.font(MimicMetrics.body.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: true).frame(minHeight: max(20, self.height - 8))
                }.buttonStyle(.borderedProminent).tint(.indigo)
            } else {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label.font(MimicMetrics.body.weight(.medium))
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, self.icon ? 0 : MimicMetrics.medium)
                        .frame(width: self.icon ? 32 : nil, height: self.icon ? 32 : self.height)
                }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets()))
            }
        }.buttonBorderShape(self.icon ? .circle : .roundedRectangle(radius: 8))
            .controlSize(.regular)
    }
}

/// An edge-to-edge control band avoids nested floating capsules in the compact panels.
struct MimicChrome<Content: View>: View {
    @ViewBuilder var content: Content
    private var accessibility = MimicAccessibility()
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        Group {
            if #available(macOS 26.0, *), !self.accessibility.reduceTransparency, !self.accessibility.increasedContrast {
                self.content.glassEffect(.regular, in: Rectangle())
            } else {
                self.content.background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
}

/// Scroll edges separate the document from pinned controls, without more glass.
struct MimicScrollEdges: ViewModifier {
    private var accessibility = MimicAccessibility()
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .vertical)
                .scrollEdgeEffectHidden(self.accessibility.reduceTransparency || self.accessibility.increasedContrast, for: .vertical)
        } else { content }
    }
}

/// Structural separators are only needed when native scroll edge effects are absent.
struct MimicPanelSeparator: View {
    private var accessibility = MimicAccessibility()
    var body: some View {
        if #available(macOS 26.0, *), !self.accessibility.reduceTransparency, !self.accessibility.increasedContrast {
            EmptyView()
        } else { Divider() }
    }
}

/// System accessibility is shared by chrome and controls. DEBUG previews can inject
/// settings without changing the user's macOS preferences or recording new defaults.
struct MimicAccessibility: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var systemTransparency
    @Environment(\.accessibilityReduceMotion) private var systemMotion
    @Environment(\.colorSchemeContrast) private var systemContrast
    #if DEBUG
    @Environment(MimicAppearancePreview.self) private var preview: MimicAppearancePreview?
    @Environment(\.mimicMotionSettings) private var motionSettings
    #endif

    @MainActor var reduceTransparency: Bool {
        #if DEBUG
        if let preview { return preview.reduceTransparency }
        if let override = self.motionSettings?.reduceTransparencyOverride { return override }
        #endif
        return self.systemTransparency
    }
    @MainActor var reduceMotion: Bool {
        #if DEBUG
        if let preview { return preview.reduceMotion }
        if let override = self.motionSettings?.reduceMotionOverride { return override }
        #endif
        return self.systemMotion
    }
    @MainActor var increasedContrast: Bool {
        #if DEBUG
        if let preview { return preview.increasedContrast }
        if let override = self.motionSettings?.contrastOverride { return override }
        #endif
        return self.systemContrast == .increased
    }
}

#if DEBUG
/// Preview-only injection for read-only SwiftUI accessibility environment values.
@Observable
final class MimicAppearancePreview {
    let reduceTransparency: Bool
    let reduceMotion: Bool
    let increasedContrast: Bool
    init(reduceTransparency: Bool = false, reduceMotion: Bool = false, increasedContrast: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion
        self.increasedContrast = increasedContrast
    }
}
#endif
