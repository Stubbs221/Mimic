//
//  MimicMotion.swift
//  Mimic
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import Observation
import SwiftUI

/// Input origin belongs to a navigation request, not to execution state or saved preferences.
enum MimicMotionSource: Equatable, Sendable {
    case pointer, keyboard, automatic

    @MainActor static var current: Self {
        switch NSApp?.currentEvent?.type {
        case .keyDown, .keyUp, .flagsChanged: .keyboard
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved, .mouseEntered, .mouseExited: .pointer
        default: .automatic
        }
    }
}

@MainActor @Observable
final class MimicMotionSettings {
    #if DEBUG
    var speed: Double = 1
    var reduceMotionOverride: Bool?
    var reduceTransparencyOverride: Bool?
    var contrastOverride: Bool?
    var darkOverride: Bool?
    #endif
    var multiplier: Double {
        #if DEBUG
        self.speed == 5 ? 5 : 1
        #else
        1
        #endif
    }
    var previewColorScheme: ColorScheme? {
        #if DEBUG
        self.darkOverride.map { $0 ? .dark : .light }
        #else
        nil
        #endif
    }
    var nativeReduceMotion: Bool {
        #if DEBUG
        if let override = self.reduceMotionOverride { return override }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// All durations are seconds. Keyboard paths have no animation in either accessibility mode.
struct MimicMotionPolicy: Equatable {
    enum Kind { case disclosure, status, enter, exit, geometry, progress, feedback }
    let source: MimicMotionSource
    let reduceMotion: Bool
    var multiplier: Double = 1

    func duration(_ kind: Kind) -> Double {
        guard self.source != .keyboard else { return 0 }
        if self.reduceMotion { return kind == .geometry || kind == .progress ? 0 : 0.125 * self.multiplier }
        let duration: Double = switch kind {
        case .disclosure, .geometry, .progress: 0.2
        case .status, .enter: 0.15
        case .exit, .feedback: 0.125
        }
        return duration * self.multiplier
    }

    func animation(_ kind: Kind) -> Animation? {
        let duration = self.duration(kind)
        guard duration > 0 else { return nil }
        if kind == .progress { return .linear(duration: duration) }
        if kind == .geometry { return .timingCurve(0.77, 0, 0.175, 1, duration: duration) }
        return .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    var moves: Bool { !self.reduceMotion && self.source != .keyboard }

    /// The AppKit driver evaluates the same cubic Bézier used by SwiftUI.
    static func fraction(_ elapsed: Double, geometry: Bool = false) -> Double {
        let x = min(1, max(0, elapsed))
        if x == 0 || x == 1 { return x }
        let x1 = geometry ? 0.77 : 0.23, x2 = geometry ? 0.175 : 0.32
        let y1 = geometry ? 0.0 : 1.0
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let t = (low + high) / 2
            if cubic(t, x1, x2) < x { low = t } else { high = t }
        }
        return cubic((low + high) / 2, y1, 1)
    }
}

private struct MotionSettingsKey: EnvironmentKey {
    static let defaultValue: MimicMotionSettings? = nil
}
extension EnvironmentValues {
    var mimicMotionSettings: MimicMotionSettings? {
        get { self[MotionSettingsKey.self] }
        set { self[MotionSettingsKey.self] = newValue }
    }
}

struct MimicMotion: DynamicProperty {
    private var accessibility = MimicAccessibility()
    @Environment(\.mimicMotionSettings) private var settings
    @MainActor func policy(_ source: MimicMotionSource = .automatic) -> MimicMotionPolicy {
        MimicMotionPolicy(source: source, reduceMotion: self.accessibility.reduceMotion, multiplier: self.settings?.multiplier ?? 1)
    }
}

private struct MimicStatusChange<Value: Equatable>: ViewModifier {
    let value: Value
    let source: MimicMotionSource
    private var motion = MimicMotion()
    init(value: Value, source: MimicMotionSource) { self.value = value; self.source = source }
    func body(content: Content) -> some View {
        content.contentTransition(.opacity).animation(self.motion.policy(self.source).animation(.status), value: self.value)
    }
}
extension View {
    /// Apply only to status labels/symbols; timers and editors must stay outside this scope.
    func mimicStatus<Value: Equatable>(_ value: Value, source: MimicMotionSource = .automatic) -> some View {
        self.modifier(MimicStatusChange(value: value, source: source))
    }
    func mimicImmediate() -> some View {
        self.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

private struct CollapseHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Retains the original subtree through its exit, then removes it. Reopening cancels that removal.
/// Only the outside height is interpolated, so an embedded terminal never shrinks its PTY.
struct MimicCollapse<Content: View>: View {
    let expanded: Bool
    var source: MimicMotionSource = .automatic
    var retainsContent = false
    let content: Content
    private var motion = MimicMotion()
    @State private var mounted: Bool
    @State private var revealed: Bool
    @State private var naturalHeight: CGFloat = 0
    @State private var revision = UUID()
    @State private var removal: Task<Void, Never>?

    init(expanded: Bool, source: MimicMotionSource = .automatic, retainsContent: Bool = false, @ViewBuilder content: () -> Content) {
        self.expanded = expanded; self.source = source; self.retainsContent = retainsContent; self.content = content()
        self._mounted = State(initialValue: expanded || retainsContent); self._revealed = State(initialValue: expanded)
    }

    var body: some View {
        Group {
            if self.mounted {
                self.content.fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in Color.clear.preference(key: CollapseHeightKey.self, value: proxy.size.height) })
                    .frame(height: self.displayedHeight, alignment: .top)
                    .animation(self.motion.policy(self.source).moves ? self.motion.policy(self.source).animation(.disclosure) : nil, value: self.revealed)
                    .clipped().opacity(self.revealed ? 1 : 0)
                    .animation(self.motion.policy(self.source).animation(.disclosure), value: self.revealed)
                    .allowsHitTesting(self.expanded).disabled(!self.expanded).accessibilityHidden(!self.expanded)
                    .onPreferenceChange(CollapseHeightKey.self) { height in
                        guard height > 0, abs(height - self.naturalHeight) > 0.5 else { return }
                        self.naturalHeight = height
                        if self.expanded, !self.revealed { self.reveal(true) }
                    }
            }
        }.onChange(of: self.expanded) { _, expanded in
            self.revision = UUID(); self.removal?.cancel()
            if expanded {
                if self.mounted { self.reveal(true) }
                else { self.mounted = true; if self.naturalHeight > 0 || self.source == .keyboard { self.reveal(true) } }
            } else {
                self.reveal(false)
                let delay = self.motion.policy(self.source).duration(.disclosure), revision = self.revision
                if self.retainsContent { return }
                if delay == 0 { self.mounted = false }
                else { self.removal = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, self.revision == revision, !self.expanded else { return }
                    self.mounted = false
                } }
            }
        }.onDisappear { self.removal?.cancel() }
    }

    private var displayedHeight: CGFloat? {
        let visible = self.motion.policy(self.source).moves ? self.revealed : self.expanded
        if self.naturalHeight > 0 { return visible ? self.naturalHeight : 0 }
        return visible ? nil : 0
    }

    private func reveal(_ value: Bool) {
        self.revealed = value
    }
}

/// Native buttons retain keyboard/VoiceOver semantics while nested content uses our clipping transition.
struct MimicDisclosure<Label: View, Content: View>: View {
    @Binding private var expanded: Bool
    @State private var localExpanded = false
    @State private var source = MimicMotionSource.automatic
    private let usesLocal: Bool
    let label: Label
    let content: Content
    init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self._expanded = isExpanded; self.usesLocal = false; self.content = content(); self.label = label()
    }
    init(_ title: String, isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) where Label == Text {
        self._expanded = isExpanded ?? .constant(false); self.usesLocal = isExpanded == nil
        self.label = Text(title); self.content = content()
    }
    private var isExpanded: Bool { self.usesLocal ? self.localExpanded : self.expanded }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                self.source = .current
                if self.usesLocal { self.localExpanded.toggle() } else { self.expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: self.isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).accessibilityHidden(true)
                    self.label
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(RowButtonStyle()).accessibilityValue(disclosureValue(self.isExpanded))
            MimicCollapse(expanded: self.isExpanded, source: self.source) { self.content.padding(.top, 8) }
        }
    }
}

/// Presentation-only requests never forward publications to the domain coordinator.
@MainActor final class MimicPanelScroll: ObservableObject {
    @Published private(set) var request = UUID()
    private(set) var target = ""
    private(set) var source = MimicMotionSource.automatic

    func begin(target: String, source: MimicMotionSource) {
        self.target = target; self.source = source; request = UUID()
    }
    func isActive(_ request: UUID) -> Bool { self.request == request && !target.isEmpty }
    func complete(_ request: UUID) { if isActive(request) { target = "" } }
    @discardableResult func cancel() -> Bool {
        guard !target.isEmpty else { return false }
        target = ""; request = UUID(); return true
    }
}

/// Wheel input invalidates the pending target before another run-loop scroll can apply it.
struct MimicScrollCancellation: NSViewRepresentable {
    let cancel: () -> Bool
    func makeNSView(context: Context) -> TrackingView { TrackingView(cancel: self.cancel) }
    func updateNSView(_ view: TrackingView, context: Context) { view.cancel = self.cancel }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.stop() }
    final class TrackingView: NSView {
        var cancel: () -> Bool
        private var monitor: Any?
        init(cancel: @escaping () -> Bool) {
            self.cancel = cancel; super.init(frame: .zero)
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window, self.cancel() {
                    self.interruptScroll(in: self.window?.contentView, event: event)
                }
                return event
            }
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private func interruptScroll(in view: NSView?, event: NSEvent) {
            guard let view, !view.isHidden else { return }
            if let scroll = view as? NSScrollView, scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) {
                let clip = scroll.contentView
                let current = clip.layer?.presentation()?.bounds.origin ?? clip.bounds.origin
                clip.layer?.removeAllAnimations()
                clip.scroll(to: current); scroll.reflectScrolledClipView(clip)
                return
            }
            for child in view.subviews { self.interruptScroll(in: child, event: event) }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; self.monitor = nil }
    }
}
