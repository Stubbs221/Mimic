//
//  NativeRetroHelp.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import MimicCore

// MARK: - Common help presentation

extension View {
    /// Preserves system help outside R1 and exposes the message to accessibility in every theme.
    func mimicHelp(_ message: String) -> some View { modifier(NativeRetroHelp(message: message)) }
    /// AppKit owns native control help; a SwiftUI AX hint would duplicate the represented element.
    func mimicNativeControlHelp(_ message: String) -> some View { modifier(NativeRetroControlHelp(message: message)) }
}
private struct NativeRetroControlHelp: ViewModifier {
    let message: String
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var scale
    func body(content: Content) -> some View {
        content.overlay(NativeRetroHelpMarker(message: message, appearance: theme.appearance, scale: scale))
    }
}
private struct NativeRetroHelp: ViewModifier {
    let message: String
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var scale
    func body(content: Content) -> some View {
        content.help(theme.retro ? "" : message).accessibilityHint(message)
            .overlay(NativeRetroHelpMarker(message: message, appearance: theme.appearance, scale: scale))
    }
}
private struct NativeRetroHelpMarker: NSViewRepresentable {
    let message: String
    let appearance: PanelAppearance
    let scale: CGFloat
    func makeNSView(context: Context) -> NativeRetroHelpAnchor { NativeRetroHelpAnchor() }
    func updateNSView(_ view: NativeRetroHelpAnchor, context: Context) {
        if view.message != message || view.choice != appearance || view.scale != scale { NativeRetroHelpCoordinator.shared.cancel(anchor: view) }
        view.message = message; view.choice = appearance; view.scale = scale
    }
    static func dismantleNSView(_ view: NativeRetroHelpAnchor, coordinator: ()) { NativeRetroHelpCoordinator.shared.cancel(anchor: view) }
}

/// Transparent anchors leave hit testing and responder ownership with the existing control.
@MainActor final class NativeRetroHelpAnchor: NSView {
    var message = ""
    var choice = PanelAppearance.legacy
    var scale: CGFloat = 1
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false); NativeRetroHelpCoordinator.shared.register(self) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); NativeRetroHelpCoordinator.shared.cancel(anchor: self) }
    override func viewDidHide() { super.viewDidHide(); NativeRetroHelpCoordinator.shared.cancel(anchor: self) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { NativeRetroHelpCoordinator.shared.pointerEntered(self) }
    override func mouseExited(with event: NSEvent) { NativeRetroHelpCoordinator.shared.cancel(anchor: self) }
}

// MARK: - Disposable tooltip transaction

/// Only a live anchor and the current generation may display help after the pointer delay.
@MainActor final class NativeRetroHelpCoordinator {
    static let shared = NativeRetroHelpCoordinator()
    private final class WeakAnchor { weak var value: NativeRetroHelpAnchor?; init(_ value: NativeRetroHelpAnchor) { self.value = value } }
    private var anchors: [WeakAnchor] = []
    private(set) weak var target: NativeRetroHelpAnchor?
    private(set) var panel: NSPanel?
    private var timer: Timer?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private(set) var generation = 0
    var reducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }; return self.handleEvent(event)
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { if let self, let window, self.target?.window === window { self.hide() } }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } })
    }
    isolated deinit {
        timer?.invalidate(); if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func register(_ anchor: NativeRetroHelpAnchor) { anchors.removeAll { $0.value == nil }; anchors.append(WeakAnchor(anchor)) }
    /// Only help commands are consumed; editing, Tab and normal control activation keep their responder.
    func handleEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.keyCode == 44 || event.charactersIgnoringModifiers == "/",
           let window = event.window, let anchor = keyboardAnchor(window: window) { schedule(anchor, keyboard: true); return nil }
        if event.type == .keyDown, event.keyCode == 53 {
            let consumes = panel != nil && (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true
            hide(); return consumes ? nil : event
        }
        hide(); return event
    }
    private func eligible(_ anchor: NativeRetroHelpAnchor) -> Bool {
        anchor.choice.isRetro && !anchor.message.isEmpty && anchor.window?.isVisible == true && !anchor.isHiddenOrHasHiddenAncestor && anchor.bounds.width > 0 && anchor.bounds.height > 0
    }
    private func smallest(_ values: [NativeRetroHelpAnchor]) -> NativeRetroHelpAnchor? { values.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height } }
    func pointerEntered(_ anchor: NativeRetroHelpAnchor) {
        guard let window = anchor.window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        if let winner = smallest(anchors.compactMap(\.value).filter { eligible($0) && $0.window === window && $0.bounds.contains($0.convert(point, from: nil)) }) { schedule(winner, keyboard: false) }
    }
    func keyboardAnchor(window: NSWindow) -> NativeRetroHelpAnchor? {
        guard let responder = window.firstResponder as? NSView else { return nil }
        let rect = responder.convert(responder.bounds, to: nil)
        return smallest(anchors.compactMap(\.value).filter { eligible($0) && $0.window === window && $0.convert($0.bounds, to: nil).contains(CGPoint(x: rect.midX, y: rect.midY)) })
    }
    func schedule(_ anchor: NativeRetroHelpAnchor, keyboard: Bool) {
        guard eligible(anchor) else { return }
        if target === anchor, panel != nil { return }
        hide(); target = anchor
        let revision = generation
        if keyboard { show(generation: revision, keyboard: true) }
        else {
            let next = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.show(generation: revision, keyboard: false) } }
            timer = next; RunLoop.main.add(next, forMode: .common)
        }
    }
    func cancel(anchor: NativeRetroHelpAnchor) { if target === anchor { hide() } }
    func hide() {
        generation &+= 1; timer?.invalidate(); timer = nil
        if let panel { target?.window?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
        panel = nil; target = nil
    }
    func show(generation revision: Int, keyboard: Bool) {
        guard generation == revision, let anchor = target, eligible(anchor), let window = anchor.window else { return }
        timer?.invalidate(); timer = nil
        let available = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let maximumWidth = min(360 * anchor.scale, max(40, available.width - 8))
        let content = NativeRetroTooltipText(frame: .zero); content.message = anchor.message; content.font = NativeRetro.font(anchor.choice, scale: anchor.scale)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let size = (anchor.message as NSString).boundingRect(with: CGSize(width: maximumWidth - 10, height: available.height - 16), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: content.font, .paragraphStyle: paragraph]).size
        let width = min(maximumWidth, max(24, ceil(size.width) + 10)), height = min(available.height - 8, ceil(size.height) + 8)
        let position = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var frame = CGRect(x: min(max(position.minX, available.minX + 4), available.maxX - width - 4), y: position.minY - height - 4, width: width, height: height)
        if frame.minY < available.minY + 4 { frame.origin.y = min(position.maxY + 4, available.maxY - height - 4) }
        frame.origin.y = min(max(frame.minY, available.minY + 4), available.maxY - height - 4)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hasShadow = false
        panel.backgroundColor = NativeRetro.rgb(0xffffe1); content.frame = CGRect(origin: .zero, size: frame.size)
        content.setAccessibilityElement(true); content.setAccessibilityRole(.helpTag); content.setAccessibilityLabel(anchor.message)
        panel.contentView = content; self.panel = panel
        window.addChildWindow(panel, ordered: .above); panel.orderFront(nil)
        if anchor.choice == .windowsXP, !keyboard, !reducedMotion() {
            panel.alphaValue = 0; NSAnimationContext.runAnimationGroup { context in context.duration = 0.15; context.timingFunction = CAMediaTimingFunction(name: .linear); panel.animator().alphaValue = 1 }
        }
    }
}
private final class NativeRetroTooltipText: NSView {
    var message = ""
    var font = NSFont.systemFont(ofSize: 11)
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NativeRetro.rgb(0xffffe1).setFill(); bounds.fill()
        NSColor.black.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        (message as NSString).draw(in: bounds.insetBy(dx: 5, dy: 4), withAttributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
    }
}
