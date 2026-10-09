// Created by Василий Маслов on 08.10.2026.
import AppKit
import SwiftTerm
import SwiftUI
import MimicCore

/// Presentation only: examples never enter the task's replay or terminal buffer.
enum BootstrapTerminalPlaceholderState {
    case idle, queued, running, unavailable

    static func resolve(status: TaskStatus?, hasOutput: Bool) -> Self? {
        guard !hasOutput else { return nil }
        switch status {
        case nil: return .idle
        case .queued: return .queued
        case .running: return .running
        default: return .unavailable
        }
    }

    var message: String? {
        switch self {
        case .idle: return nil
        case .queued: return text("bootstrap.terminal.queued")
        case .running: return text("bootstrap.terminal.waiting")
        case .unavailable: return text("bootstrap.terminal.unavailable")
        }
    }
    var showsExample: Bool { self == .idle || self == .unavailable }
}

struct BootstrapTerminalPlaceholder: View {
    let state: BootstrapTerminalPlaceholderState
    let platform: BootstrapPlatform
    @Environment(\.mimicTextScale) private var textScale
    @Environment(\.colorSchemeContrast) private var contrast
    private var theme = MimicTheme()

    var body: some View {
        ViewThatFits(in: .vertical) {
            self.content(rows: 3, header: true)
            self.content(rows: 1, header: true)
            self.content(rows: 0, header: true)
            self.content(rows: 0, header: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .foregroundStyle(theme.tiled ? theme.color("terminalText") : Color(nsColor: BootstrapTerminalTheme.foreground))
        .background(theme.tiled ? theme.color("terminal") : Color(nsColor: BootstrapTerminalTheme.background))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([state.showsExample ? text("bootstrap.terminal.example") : nil, state.message].compactMap { $0 }.joined(separator: ". "))
        .accessibilityIdentifier("bootstrap.terminal.placeholder")
    }

    private func content(rows: Int, header: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8 * textScale) {
            if state.showsExample, header {
                Text("BOOTSTRAP / TERMINAL · " + text("bootstrap.terminal.example"))
                    .font(.system(size: 10 * textScale, weight: .semibold)).lineSpacing(2 * textScale)
                    .opacity(contrast == .increased ? 1 : 0.8)
            }
            if state.showsExample, rows > 0 {
                Text((rows == 3 ? ["$ mimic bootstrap " + platform.rawValue, "✓ Dependencies ready", "› Waiting for launch"] : ["$ mimic bootstrap " + platform.rawValue]).joined(separator: "\n"))
                    .font(.system(size: 11 * textScale, design: .monospaced)).lineSpacing(4 * textScale)
                    .opacity(contrast == .increased ? 1 : 0.7).accessibilityHidden(true)
            }
            if let message = state.message {
                Text(message).font(.system(size: 10 * textScale)).lineSpacing(2 * textScale)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// Observe the first byte directly, even when the coordinator's task metadata does not change.
struct BootstrapTaskTerminal: View {
    let model: TaskCoordinator
    let record: TaskRecord
    let visible: Bool
    let fontSize: CGFloat
    @ObservedObject var session: BootstrapTerminalSession

    var body: some View {
        let placeholder = BootstrapTerminalPlaceholderState.resolve(status: record.status, hasOutput: session.hasOutput)
        ZStack {
            BootstrapTerminalContainer(model: model, record: record, visible: visible, fontSize: fontSize, session: session)
                .accessibilityHidden(placeholder != nil)
            if let placeholder {
                BootstrapTerminalPlaceholder(state: placeholder, platform: record.options.platform)
            }
        }.modifier(BootstrapTerminalSelection(session: session, visible: visible))
            .transaction { $0.animation = nil }
    }
}

// MARK: - Explicit terminal selection

/// Selection gates wheel and keyboard ownership without replacing the task's terminal screen.
struct BootstrapTerminalSelection: ViewModifier {
    var session: BootstrapTerminalSession? = nil
    var visible = true
    @State private var selected = false
    private var theme = MimicTheme()
    func body(content: Content) -> some View {
        content
            .background(BootstrapTerminalActivation(selected: $selected, visible: visible, terminal: session?.view(), selectionChanged: { session?.setSelected($0) }))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color("accent"), lineWidth: selected ? 2 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .background { if visible { PanelControlRegion() } }
    }
}

/// Inactive terminals pass wheel events to the enclosing panel; explicit clicks claim the screen.
struct BootstrapTerminalActivation: NSViewRepresentable {
    @Binding var selected: Bool
    let visible: Bool
    let terminal: TerminalView?
    let selectionChanged: (Bool) -> Void
    func makeNSView(context: Context) -> EventView { EventView() }
    func updateNSView(_ view: EventView, context: Context) {
        view.terminal = terminal
        view.selectionChanged = { selected = $0; selectionChanged($0) }
        view.enabled = visible
        if !visible { view.select(false) }
    }
    static func dismantleNSView(_ view: EventView, coordinator: ()) { view.stop() }

    @MainActor final class EventView: NSView {
        private static weak var active: EventView?
        weak var terminal: TerminalView?
        var enabled = true
        private(set) var selected = false
        var selectionChanged: (Bool) -> Void = { _ in }
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var windowObserver: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel]) { [weak self] event in guard let self else { return event }; return self.receive(event) }
            resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.select(false) }
            }
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
            guard let window else { select(false); return }
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.select(false) }
            }
        }
        static func clearSelection(outside event: NSEvent) {
            guard let active, event.window !== active.window || !active.contains(event) else { return }
            active.select(false)
        }
        private func contains(_ event: NSEvent) -> Bool {
            enabled && !isHiddenOrHasHiddenAncestor && bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil))
        }
        func select(_ selected: Bool) {
            guard self.selected != selected else { return }
            if selected { Self.active?.select(false); Self.active = self }
            else if Self.active === self { Self.active = nil }
            self.selected = selected; selectionChanged(selected)
            if selected { window?.makeFirstResponder(terminal ?? self) }
            else if window?.firstResponder === terminal || window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        func receive(_ event: NSEvent) -> NSEvent? {
            if event.type == .leftMouseDown { Self.clearSelection(outside: event) }
            guard let window, event.window === window, contains(event) else { return event }
            if event.type == .leftMouseDown { select(true) }
            else if event.type == .scrollWheel, !selected {
                enclosingScrollView?.scrollWheel(with: event)
                return nil
            }
            return event
        }
        func stop() {
            select(false)
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        }
    }
}
