//
//  PanelDrag.swift
//  Mimic
//
//  Created by Василий Маслов on 06.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Layout reports logical frames before applying the dragged card's presentation position.
struct PanelFrameSink: LayoutValueKey {
    static let defaultValue: (@Sendable (CGRect) -> Void)? = nil
}

/// Marks hosted controls whose accessibility hit test can return only the hosting container.
/// The transparent marker never receives mouse events itself.
struct PanelControlRegion: NSViewRepresentable {
    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        static func contains(_ point: NSPoint, in view: NSView) -> Bool {
            guard !view.isHidden else { return false }
            if view is MarkerView, view.bounds.intersection(view.visibleRect).contains(view.convert(point, from: nil)) { return true }
            return view.subviews.contains { contains(point, in: $0) }
        }
    }

    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ nsView: MarkerView, context: Context) {}
}

/// Input-only state: pressure and the hold timer share one activation path and one mouse-up owner.
struct PanelDragGesture {
    enum Phase: Equatable { case idle, waiting, dragging, cancelled }
    private(set) var phase: Phase = .idle
    private(set) var origin = CGPoint.zero
    private(set) var point = CGPoint.zero
    private var deadline: TimeInterval = 0
    var ownsPress: Bool { phase != .idle }
    mutating func press(at point: CGPoint, time: TimeInterval, eligible: Bool) {
        guard eligible, phase == .idle else { return }
        origin = point; self.point = point; deadline = time + 0.350; phase = .waiting
    }
    @discardableResult mutating func move(to point: CGPoint) -> Bool {
        self.point = point
        if phase == .waiting && hypot(point.x - origin.x, point.y - origin.y) > 8 { phase = .cancelled }
        return phase == .dragging
    }
    @discardableResult mutating func activate(time: TimeInterval, pressureStage: Int = 0) -> Bool {
        guard phase == .waiting, pressureStage >= 2 || time >= deadline else { return false }
        phase = .dragging; return true
    }
    /// Only a short, stationary press remains a click. A lifted card never opens on release.
    mutating func release() -> (drop: Bool, click: Bool) {
        let result = (phase == .dragging, phase == .waiting)
        self = Self(); return result
    }
    mutating func cancel() { if ownsPress { phase = .cancelled } }
}

// MARK: - Deliberate size changes

/// A size change requires one continuous, stationary second in a different zone.
/// Pointer coordinates belong to the window, so document autoscroll cannot reset the dwell.
struct PanelDragResize {
    enum Zone: Equatable {
        case left, center, right
        var size: PanelBlockSize { self == .center ? .full : .mini }
        var slot: Int { self == .right ? 1 : 0 }
        static func resolve(x: CGFloat, width: CGFloat) -> Self? {
            guard width > 0, x >= 0, x <= width else { return nil }
            return x <= width * 0.2 ? .left : x >= width * 0.8 ? .right : .center
        }
    }
    private(set) var size: PanelBlockSize
    private var lastPointer: CGPoint
    private var moved = false
    private var pending: Zone?
    private var anchor = CGPoint.zero
    private var started: TimeInterval = 0
    init(size: PanelBlockSize, pointer: CGPoint) { self.size = size; lastPointer = pointer }
    @discardableResult mutating func update(zone: Zone?, pointer: CGPoint, time: TimeInterval) -> Bool {
        if pointer != lastPointer { moved = true }
        lastPointer = pointer
        guard moved, let zone, zone.size != size else { pending = nil; return false }
        if pending != zone || hypot(pointer.x - anchor.x, pointer.y - anchor.y) > 8 {
            pending = zone; anchor = pointer; started = time; return false
        }
        guard time - started >= 1 else { return false }
        size = zone.size; pending = nil; return true
    }
}

/// FLIP size correction runs independently of direct pointer placement and can be retargeted.
struct PanelDragMorph {
    let from: CGSize
    let to: CGSize
    let started: TimeInterval
    let duration: TimeInterval
    func scale(at time: TimeInterval) -> CGSize {
        let progress = duration > 0 ? MimicMotionPolicy.fraction((time - started) / duration, geometry: true) : 1
        return CGSize(width: (from.width + (to.width - from.width) * progress) / max(1, to.width),
                      height: (from.height + (to.height - from.height) * progress) / max(1, to.height))
    }
}

// MARK: - Logical targets

struct PanelDragGeometry {
    struct Cell { let row: UUID; let slot: Int; let frame: CGRect; let full: Bool }
    /// Measured collapsed row heights keep logical targets aligned with tall summaries and Bootstrap.
    static func compactCells(layout: PanelLayout, width: CGFloat, rowHeights: [UUID: CGFloat] = [:]) -> [Cell] {
        var cells: [Cell] = [], y: CGFloat = 0
        for row in layout.rows {
            let height: CGFloat = max(row.slots == [.bootstrap] ? 136 : 112, rowHeights[row.id] ?? 0)
            for slot in row.slots.indices {
                let itemWidth = row.size == .full ? width : (width - 12) / 2
                cells.append(Cell(row: row.id, slot: slot, frame: CGRect(x: CGFloat(slot) * (itemWidth + 12), y: y, width: itemWidth, height: height), full: row.size == .full))
            }
            y += height + 12
        }
        return cells
    }
    static func target(point: CGPoint, block: PanelBlockKind, layout: PanelLayout, cells: [Cell], size: PanelBlockSize? = nil) -> PanelInsertionTarget? {
        guard let last = cells.last, point.x >= 0, point.x <= cells.map(\.frame.maxX).max() ?? 0,
              point.y >= 0, point.y <= last.frame.maxY + 32 else { return nil }
        if point.y > last.frame.maxY { return .boundary(before: nil) }
        guard let cell = cells.first(where: { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }) else { return nil }
        if (size ?? layout.size(of: block)) == .mini && (!cell.full || layout.rows.first(where: { $0.id == cell.row })?.blocks == [block]) {
            return .slot(row: cell.row, slot: cell.full ? (point.x < cell.frame.midX ? 0 : 1) : cell.slot)
        }
        let rows = cells.reduce(into: [UUID]()) { if !$0.contains($1.row) { $0.append($1.row) } }
        let index = rows.firstIndex(of: cell.row)!
        return .boundary(before: point.y < cell.frame.midY ? cell.row : rows.indices.contains(index + 1) ? rows[index + 1] : nil)
    }
    static func scrollSpeed(y: CGFloat, height: CGFloat) -> CGFloat {
        if y < 48 { return -400 * min(1, max(0, (48 - y) / 48)) }
        if y > height - 48 { return 400 * min(1, max(0, (y - height + 48) / 48)) }
        return 0
    }
}

// MARK: - Native event ownership

/// A scoped event bridge consumes only eligible card presses. Controls keep AppKit/SwiftUI tracking;
/// short surface clicks invoke the existing disclosure, while a captured drag follows window events.
struct PanelDragBridge: NSViewRepresentable {
    struct Candidate { let block: PanelBlockKind; let header: Bool }
    let cancellationID: Int
    let enabled: Bool
    let candidate: (CGPoint) -> Candidate?
    let click: (PanelBlockKind) -> Void
    let lift: (PanelBlockKind, CGPoint, CGPoint, TimeInterval) -> Void
    let move: (CGPoint, CGPoint, TimeInterval, Bool) -> Void
    let end: (CGPoint, CGPoint, TimeInterval) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView(callbacks: self) }
    func updateNSView(_ view: TrackingView, context: Context) {
        if !enabled || view.callbacks.cancellationID != cancellationID { view.abort() }
        view.callbacks = self
    }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.stop() }

    @MainActor final class TrackingView: NSView {
        var callbacks: PanelDragBridge
        private var gesture = PanelDragGesture()
        private var selected: Candidate?
        private var monitor: Any?
        private var timer: Timer?
        private var resignObserver: NSObjectProtocol?
        private weak var configuredView: NSView?
        private var originalPressure: NSPressureConfiguration?
        private var windowPoint = CGPoint.zero
        private var lastTick: TimeInterval = 0
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        init(callbacks: PanelDragBridge) {
            self.callbacks = callbacks; super.init(frame: .zero)
            pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .pressure, .keyDown]) { [weak self] event in
                guard let self else { return event }; return self.receive(event)
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.abort() }
            }
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if configuredView !== window?.contentView {
                configuredView?.pressureConfiguration = originalPressure
                configuredView = window?.contentView; originalPressure = configuredView?.pressureConfiguration
                configuredView?.pressureConfiguration = pressureConfiguration
            }
            if window == nil { abort() }
        }
        func stop() {
            abort()
            configuredView?.pressureConfiguration = originalPressure; configuredView = nil
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        }
        func receive(_ event: NSEvent) -> NSEvent? {
            guard callbacks.enabled, let window, event.window === window else { return event }
            let now = ProcessInfo.processInfo.systemUptime
            if event.type == .keyDown {
                if event.keyCode == 53 && gesture.ownsPress { abort(); return nil }
                return event
            }
            windowPoint = event.locationInWindow
            let point = convert(windowPoint, from: nil)
            switch event.type {
            case .leftMouseDown:
                guard !gesture.ownsPress, isVisible(point), let item = callbacks.candidate(point),
                      item.header || !isControl(at: event.locationInWindow) else { return event }
                selected = item; gesture.press(at: point, time: now, eligible: true)
                lastTick = now
                timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            case .leftMouseDragged:
                guard gesture.ownsPress else { return event }
                if gesture.move(to: point) { callbacks.move(point, windowPoint, now, isVisible(point)) }
            case .pressure:
                guard gesture.ownsPress else { return event }
                if gesture.activate(time: now, pressureStage: event.stage), let selected { callbacks.lift(selected.block, point, windowPoint, now) }
            case .leftMouseUp:
                guard gesture.ownsPress else { return event }
                let result = gesture.release(); timer?.invalidate(); timer = nil
                if result.drop { if isVisible(point) { callbacks.end(point, windowPoint, now) } else { callbacks.cancel() } }
                else if result.click, isVisible(point), let selected { callbacks.click(selected.block) }
                selected = nil
            default: return event
            }
            return nil
        }
        private func tick() {
            guard callbacks.enabled, let window, window.isVisible, NSEvent.pressedMouseButtons & 1 != 0 else { abort(); return }
            let now = ProcessInfo.processInfo.systemUptime, elapsed = min(0.05, now - lastTick); lastTick = now
            var point = convert(windowPoint, from: nil)
            if gesture.activate(time: now), let selected { callbacks.lift(selected.block, point, windowPoint, now) }
            guard gesture.phase == .dragging else { return }
            if let scroll = enclosingScrollView, let document = scroll.documentView {
                let clip = scroll.contentView, pointer = clip.convert(windowPoint, from: nil), visible = clip.bounds
                let y = document.isFlipped ? pointer.y - visible.minY : visible.maxY - pointer.y
                let speed = PanelDragGeometry.scrollSpeed(y: y, height: visible.height)
                let direction: CGFloat = document.isFlipped ? 1 : -1
                let offset = min(max(0, document.bounds.height - visible.height), max(0, visible.minY + speed * elapsed * direction))
                if offset != visible.minY { clip.scroll(to: CGPoint(x: visible.minX, y: offset)); scroll.reflectScrolledClipView(clip) }
                point = convert(windowPoint, from: nil)
            }
            callbacks.move(point, windowPoint, now, isVisible(point))
        }
        private func isVisible(_ point: CGPoint) -> Bool {
            guard bounds.insetBy(dx: 0, dy: -32).contains(point) else { return false }
            if let clip = enclosingScrollView?.contentView { return clip.bounds.contains(clip.convert(point, from: self)) }
            return visibleRect.insetBy(dx: 0, dy: -32).contains(point)
        }
        private func isControl(at point: CGPoint) -> Bool {
            guard let window else { return true }
            if let root = window.contentView, PanelControlRegion.MarkerView.contains(point, in: root) { return true }
            let screen = window.convertPoint(toScreen: point)
            var item = window.contentView?.accessibilityHitTest(screen) as? NSAccessibilityProtocol
            let blocked: Set<NSAccessibility.Role> = [.button, .menuButton, .popUpButton, .comboBox, .textField, .textArea, .checkBox, .radioButton, .slider, .link, .table, .outline]
            for _ in 0..<16 {
                guard let current = item else { break }
                if let role = current.accessibilityRole(), blocked.contains(role) { return true }
                item = current.accessibilityParent() as? NSAccessibilityProtocol
            }
            // Native controls are also excluded when a hosted accessibility tree is unavailable.
            var view = window.contentView?.hitTest(window.contentView?.convert(point, from: nil) ?? point)
            while let current = view { if current is NSControl || current is NSTextView { return true }; view = current.superview }
            return false
        }
        func abort() {
            if gesture.ownsPress { callbacks.cancel() }
            gesture = PanelDragGesture(); selected = nil; timer?.invalidate(); timer = nil
        }
    }
}

// MARK: - Category surfaces

struct PanelCardPalette {
    static func native(_ block: PanelBlockKind) -> NSColor {
        let hex: Int = switch block {
        case .bootstrap: 0x4F7CAC
        case .builds: 0x7166A5
        case .ci, .uiTests, .qualityGates, .beta: 0x768D60
        case .simulators: 0x4F8D9E
        case .ai: 0x9675A3
        default: 0x438B82
        }
        return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static func color(_ block: PanelBlockKind) -> Color { Color(nsColor: native(block)) }
}

struct PanelCardBackground: ViewModifier {
    let block: PanelBlockKind
    @Environment(\.colorScheme) private var scheme
    private var accessibility = MimicAccessibility()
    private var resolvedFill: NSColor {
        var fill = NSColor.controlBackgroundColor
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            fill = NSColor.controlBackgroundColor.blended(withFraction: scheme == .dark ? 0.10 : 0.06, of: PanelCardPalette.native(block)) ?? .controlBackgroundColor
        }
        return fill
    }
    func body(content: Content) -> some View {
        let fill = resolvedFill
        content.background(Color(nsColor: fill), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(accessibility.increasedContrast ? 0.45 : 0.12), lineWidth: 1))
    }
}
