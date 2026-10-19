//
//  NativeRetroControl.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Existing plain caption actions acquire artwork only in R1.
struct MimicCaptionButtonStyle: PrimitiveButtonStyle {
    let caption: String
    private var theme = MimicTheme()
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if theme.retro {
            let width: CGFloat = theme.appearance == .windowsXP ? 21 : 16
            let height: CGFloat = theme.appearance == .windowsXP ? 21 : 14
            if caption == "close" {
                Button(action: configuration.trigger) { Color.clear.frame(width: width, height: height) }
                    .buttonStyle(NativeRetroPrimitiveButtonStyle(height: height, caption: caption))
            } else { Button(configuration).buttonStyle(NativeRetroPrimitiveButtonStyle(height: height, caption: caption)) }
        } else { Button(configuration).buttonStyle(.plain) }
    }
}

/// AppKit owns the R1 press transaction, while the original SwiftUI label and command remain intact.
struct NativeRetroPrimitiveButtonStyle: PrimitiveButtonStyle {
    var height: CGFloat = 23
    var selected = false
    var caption: String? = nil
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var textScale
    func makeBody(configuration: Configuration) -> some View {
        NativeRetroActionBody(label: configuration.label, appearance: theme.appearance, height: height, scale: textScale,
                              selected: selected, caption: caption, invoke: configuration.trigger)
    }
}

/// Keep the SwiftUI label in its original graph. Hosting a configuration label in a second
/// NSHostingView feeds its preferences back into the owning button and can loop native layout.
private struct NativeRetroActionBody<Label: View>: View {
    let label: Label
    let appearance: PanelAppearance
    let height: CGFloat
    let scale: CGFloat
    let selected: Bool
    let caption: String?
    let invoke: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var pressed = false
    @State private var hovered = false
    var body: some View {
        label.font(Font(NativeRetro.font(appearance, scale: scale)))
            .foregroundStyle(Color(nsColor: NativeRetro.color(enabled ? "ink" : "muted", appearance: appearance)))
            .padding(.horizontal, caption == nil ? 8 : 0)
            .frame(minHeight: height * (caption == nil ? scale : 1))
            .offset(x: pressed && appearance == .windows95 && caption == nil ? 1 : 0,
                    y: pressed && appearance == .windows95 && caption == nil ? 1 : 0)
            .background(NativeRetroArtwork(appearance: appearance, kind: caption.map { .caption($0) } ?? .button,
                                           pressed: pressed, hovered: hovered, enabled: enabled))
            .overlay(NativeRetroActionView(appearance: appearance, selected: selected, invoke: invoke,
                                           changed: { pressed = $0; hovered = $1 }))
            .transaction { $0.animation = nil }
    }
}

private struct NativeRetroActionView: NSViewRepresentable {
    let appearance: PanelAppearance
    let selected: Bool
    let invoke: () -> Void
    let changed: (Bool, Bool) -> Void
    func makeNSView(context: Context) -> NativeRetroControl { NativeRetroControl() }
    func updateNSView(_ view: NativeRetroControl, context: Context) {
        view.actionBlock = invoke
        if view.isEnabled != context.environment.isEnabled { view.isEnabled = context.environment.isEnabled }
        view.stateChanged = changed
        if view.appearanceChoice != appearance { view.appearanceChoice = appearance }
        if view.selected != selected { view.selected = selected; view.refresh() }
    }
}

/// Space fires on release; Escape, blur, disable and release outside cancel. Enter fires immediately.
/// Tracking continues outside so returning with the pointer re-arms the same retained control.
@MainActor class NativeRetroControl: NSControl {
    var appearanceChoice = PanelAppearance.windows95 { didSet { if oldValue != appearanceChoice { cancelPress() } } }
    var selected = false
    var actionBlock: () -> Void = {}
    var stateChanged: (Bool, Bool) -> Void = { _, _ in }
    private(set) var armed = false
    private(set) var pressed = false
    private var keyboardArmed = false
    private var hovered = false
    private var blurObserver: NSObjectProtocol?
    private var pressRevision = 0
    private var publishedState = (pressed: false, hovered: false)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isEnabled: Bool { didSet { if !isEnabled { cancelPress() }; refresh() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { if let blurObserver { NotificationCenter.default.removeObserver(blurObserver) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let blurObserver { NotificationCenter.default.removeObserver(blurObserver); self.blurObserver = nil }
        if let window {
            blurObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPress() }
            }
        } else { cancelPress() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || !bounds.contains(convert(point, from: superview)) ? nil : self }
    override func draw(_ dirtyRect: NSRect) {
        if selected || window?.firstResponder === self {
            NSColor.black.setStroke(); let path = NSBezierPath(rect: bounds.insetBy(dx: 4.5, dy: 4.5))
            path.setLineDash([1, 1], count: 2, phase: 0); path.lineWidth = 1; path.stroke()
        }
    }
    func refresh() {
        if publishedState.pressed != pressed || publishedState.hovered != hovered {
            publishedState = (pressed, hovered); stateChanged(pressed, hovered)
        }
        needsDisplay = true
    }
    func beginPress() { guard isEnabled else { return }; armed = true; pressed = true; refresh() }
    func movePress(inside: Bool) { armed = inside && isEnabled; pressed = armed; refresh() }
    func releasePress(inside: Bool) { let activate = armed && inside && isEnabled; cancelPress(); if activate { invoke() } }
    func cancelPress() { pressRevision &+= 1; armed = false; pressed = false; keyboardArmed = false; refresh() }
    private func invoke() { if isEnabled { actionBlock() } }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; invoke(); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        window.makeFirstResponder(self); beginPress()
        let revision = pressRevision
        defer { cancelPress() }
        while true {
            if pressRevision != revision { break }
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .keyDown], until: Date(timeIntervalSinceNow: 0.016), inMode: .eventTracking, dequeue: true) else {
                if !window.isKeyWindow || !window.isVisible || !isEnabled { cancelPress(); break }
                continue
            }
            if next.type == .keyDown { cancelPress(); break }
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { releasePress(inside: inside); break }
            movePress(inside: inside)
        }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancelPress()
        case 49: if !event.isARepeat { keyboardArmed = true; beginPress() }
        case 36, 76: invoke()
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, keyboardArmed { releasePress(inside: true) }
        else { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool { cancelPress(); return super.resignFirstResponder() }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); refresh(); return accepted }
}
