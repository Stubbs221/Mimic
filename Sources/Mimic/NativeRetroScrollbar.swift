//
//  NativeRetroScrollbar.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import MimicCore

/// R1 decorates the existing NSScrollView. Its real clip/document metrics remain the only scroll state.
@MainActor final class NativeRetroScrollbar: NSView {
    weak var scroll: NSScrollView?
    /// A nonactivating selection popup tracks against its key owner without taking keyboard focus.
    weak var interactionWindow: NSWindow?
    var appearanceChoice = PanelAppearance.windows95 { didSet { needsDisplay = true } }
    private var observations: [NSObjectProtocol] = []
    private var pressedPart = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var thumb: CGRect {
        guard let scroll, let document = scroll.documentView else { return .zero }
        let travel = max(0, bounds.height - 34)
        let height = min(travel, max(17, travel * scroll.contentView.bounds.height / max(1, document.bounds.height)))
        let maximum = max(1, document.bounds.height - scroll.contentView.bounds.height)
        return CGRect(x: 0, y: 17 + (travel - height) * scroll.contentView.bounds.minY / maximum, width: 17, height: height)
    }
    init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        autoresizingMask = [.minXMargin, .height]
        setAccessibilityElement(true); setAccessibilityRole(.scrollBar); setAccessibilityLabel(text("retro.scrollbar"))
        scroll.contentView.postsBoundsChangedNotifications = true
        observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        if let document = scroll.documentView {
            document.postsFrameChangedNotifications = true
            observations.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    func refresh() {
        guard let scroll else { return }
        let nextFrame = CGRect(x: max(0, scroll.bounds.width - 17), y: 0, width: 17, height: scroll.bounds.height)
        if frame != nextFrame { frame = nextFrame }
        let hidden = (scroll.documentView?.bounds.height ?? 0) <= scroll.contentView.bounds.height + 1
        if isHidden != hidden { isHidden = hidden }
        needsDisplay = true
    }
    private func move(to y: CGFloat) {
        guard let scroll, let document = scroll.documentView else { return }
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: min(max(0, y), max(0, document.bounds.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView); refresh()
    }
    private func step(_ delta: CGFloat) { if let scroll { move(to: scroll.contentView.bounds.minY + delta) } }
    override func accessibilityValue() -> Any? {
        guard let scroll, let document = scroll.documentView else { return 0 }
        return scroll.contentView.bounds.minY / max(1, document.bounds.height - scroll.contentView.bounds.height)
    }
    override func accessibilityPerformIncrement() -> Bool { step(14); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-14); return true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: step(-14)
        case 125: step(14)
        case 116: step(-(scroll?.contentView.bounds.height ?? 0))
        case 121: step(scroll?.contentView.bounds.height ?? 0)
        case 115: move(to: 0)
        case 119: move(to: .greatestFiniteMagnitude)
        default: super.keyDown(with: event)
        }
    }
    private func bevel(_ rect: CGRect, pressed: Bool = false) {
        for (offset, light, dark) in [(CGFloat(0), pressed ? 0x808080 : 0xffffff, pressed ? 0xffffff : 0x000000),
                                    (CGFloat(1), pressed ? 0x000000 : 0xdfdfdf, pressed ? 0xdfdfdf : 0x808080)] {
            let r = rect.insetBy(dx: offset, dy: offset)
            NativeRetro.rgb(light).setFill()
            CGRect(x: r.minX, y: r.minY, width: r.width, height: 1).fill(); CGRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill()
            NativeRetro.rgb(dark).setFill()
            CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill(); CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let xp = appearanceChoice == .windowsXP
        if xp { NSGradient(starting: NativeRetro.rgb(0xf3f1ec), ending: NativeRetro.rgb(0xe8e6df))!.draw(in: bounds, angle: 0) }
        else {
            NSColor.white.setFill(); bounds.fill(); NativeRetro.rgb(0xc0c0c0).setFill()
            for y in stride(from: 0, to: Int(bounds.height), by: 1) { for x in stride(from: y % 2, to: 17, by: 2) { CGRect(x: x, y: y, width: 1, height: 1).fill() } }
        }
        for (part, rect, direction) in [(1, CGRect(x: 0, y: 0, width: 17, height: 17), CGFloat(-1)),
                                         (2, CGRect(x: 0, y: bounds.height - 17, width: 17, height: 17), CGFloat(1))] {
            if xp {
                NSGradient(starting: .white, ending: NativeRetro.rgb(pressedPart == part ? 0xa9c5f5 : 0xd5e2fa))!.draw(in: rect, angle: 0)
                NativeRetro.rgb(0x91b5f0).setStroke(); NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            } else { NativeRetro.rgb(0xc0c0c0).setFill(); rect.fill(); bevel(rect, pressed: pressedPart == part) }
            let offset: CGFloat = pressedPart == part && !xp ? 1 : 0
            let triangle = NSBezierPath(); triangle.move(to: CGPoint(x: 8 + offset, y: rect.midY + direction * 2 + offset))
            triangle.line(to: CGPoint(x: 5 + offset, y: rect.midY - direction * 2 + offset))
            triangle.line(to: CGPoint(x: 11 + offset, y: rect.midY - direction * 2 + offset)); triangle.close()
            NativeRetro.rgb(xp ? 0x4d6185 : 0).setFill(); triangle.fill()
        }
        let thumb = thumb
        if xp {
            NSGradient(starting: NativeRetro.rgb(0xc7dcff), ending: NativeRetro.rgb(0xa9c5f5))!.draw(in: thumb, angle: 0)
            NativeRetro.rgb(0x91b5f0).setStroke(); NSBezierPath(roundedRect: thumb.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            for dy in [-3, 0, 3] {
                NSColor.white.setFill(); CGRect(x: 4, y: thumb.midY + CGFloat(dy), width: 9, height: 1).fill()
                NativeRetro.rgb(0x91b5f0).setFill(); CGRect(x: 4, y: thumb.midY + CGFloat(dy) + 1, width: 9, height: 1).fill()
            }
        } else { NativeRetro.rgb(0xc0c0c0).setFill(); thumb.fill(); bevel(thumb) }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window, let scroll, let document = scroll.documentView else { return }
        let start = convert(event.locationInWindow, from: nil), original = thumb
        let dragging = original.contains(start), offset = start.y - original.minY
        let part = start.y < 17 ? 1 : start.y > bounds.height - 17 ? 2 : 0
        pressedPart = part; needsDisplay = true
        defer { pressedPart = 0; needsDisplay = true }
        let direction: CGFloat = part == 1 || part == 0 && start.y < original.minY ? -1 : 1
        let amount = part == 0 ? scroll.contentView.bounds.height : 14
        if !dragging { step(direction * amount) }
        var nextRepeat = ProcessInfo.processInfo.systemUptime + 0.4
        var pointer = start
        let initialTheme = appearanceChoice
        while true {
            if let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .keyDown], until: Date(timeIntervalSinceNow: 0.016), inMode: .eventTracking, dequeue: true) {
                if next.type == .leftMouseUp || next.type == .keyDown { break }
                pointer = convert(next.locationInWindow, from: nil)
                if dragging {
                    let travel = max(1, bounds.height - 34 - thumb.height)
                    move(to: min(1, max(0, (pointer.y - offset - 17) / travel)) * max(0, document.bounds.height - scroll.contentView.bounds.height))
                }
            }
            if !window.isVisible || !(window.isKeyWindow || interactionWindow?.isKeyWindow == true) || self.window !== window || appearanceChoice != initialTheme { break }
            if !dragging, ProcessInfo.processInfo.systemUptime >= nextRepeat {
                let armed = bounds.contains(pointer) && (part == 1 ? pointer.y < 17 : part == 2 ? pointer.y > bounds.height - 17 : !thumb.contains(pointer))
                pressedPart = armed ? part : 0; needsDisplay = true
                if armed { step(direction * amount) }
                nextRepeat += 0.05
            }
        }
    }
}
