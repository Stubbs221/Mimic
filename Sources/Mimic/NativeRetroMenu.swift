//
//  NativeRetroMenu.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import QuartzCore
import MimicCore

/// Explicit command data avoids reflection of SwiftUI Menu content and keeps validation at activation.
@MainActor struct NativeRetroMenuEntry {
    let id: String
    let title: String
    var enabled: () -> Bool = { true }
    var checked = false
    var separator = false
    var children: [Self] = []
    var action: () -> Void = {}
    init(_ title: String, id: String? = nil, enabled: @escaping () -> Bool = { true }, checked: Bool = false, children: [Self] = [], action: @escaping () -> Void = {}) {
        self.id = id ?? title; self.title = title; self.enabled = enabled; self.checked = checked; self.children = children; self.action = action
    }
    init(_ title: String, id: String? = nil, checked: Bool = false, action: @escaping () -> Void) {
        self.init(title, id: id, enabled: { true }, checked: checked, children: [], action: action)
    }
    static func divider(_ id: String) -> Self { var item = Self("", id: id); item.separator = true; return item }
    static func items(_ menu: NSMenu) -> [Self] {
        menu.items.enumerated().map { index, item in
            if item.isSeparatorItem { return .divider("separator-\(index)") }
            return Self(item.title, id: "item-\(index)", enabled: { item.isEnabled }, checked: item.state == .on,
                        children: item.submenu.map(Self.items) ?? []) {
                if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            }
        }
    }
}

extension View {
    func mimicMenu(_ title: String, items: [NativeRetroMenuEntry]) -> some View { modifier(NativeRetroMenuModifier(title: title, items: items)) }
}

private struct NativeRetroMenuModifier: ViewModifier {
    let title: String
    let items: [NativeRetroMenuEntry]
    @Environment(\.mimicPanelAppearance) private var appearance
    @Environment(\.mimicTextScale) private var scale
    @Environment(\.mimicMotionSettings) private var motion
    func body(content: Content) -> some View {
        ZStack {
            content.opacity(appearance.isRetro ? 0 : 1).allowsHitTesting(!appearance.isRetro).disabled(appearance.isRetro).accessibilityHidden(appearance.isRetro)
            if appearance.isRetro { NativeRetroMenuButton(title: title, items: items, appearance: appearance, scale: scale, reducedMotion: motion?.nativeReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).mimicNativeControlHelp(title) }
        }.frame(minHeight: appearance.isRetro ? 23 * scale : nil).accessibilityElement(children: .contain)
    }
}

private struct NativeRetroMenuButton: NSViewRepresentable {
    let title: String
    let items: [NativeRetroMenuEntry]
    let appearance: PanelAppearance
    let scale: CGFloat
    let reducedMotion: Bool
    func makeNSView(context: Context) -> NativeRetroMenuControl { NativeRetroMenuControl() }
    func updateNSView(_ view: NativeRetroMenuControl, context: Context) {
        if view.appearanceChoice != appearance || view.items.map(\.id) != items.map(\.id) { view.presenter.close() }
        view.title = title; view.items = items; view.scale = scale; view.reducedMotion = reducedMotion
        view.appearanceChoice = appearance; view.isEnabled = context.environment.isEnabled
        if !view.isEnabled { view.presenter.close() }
        view.setAccessibilityLabel(title); view.needsDisplay = true
    }
    static func dismantleNSView(_ view: NativeRetroMenuControl, coordinator: ()) { view.presenter.close(returnFocus: false) }
}

@MainActor final class NativeRetroMenuControl: NativeRetroControl {
    var title = ""
    var items: [NativeRetroMenuEntry] = []
    var scale: CGFloat = 1
    var reducedMotion = false
    let presenter = NativeRetroMenuPresenter()
    override init(frame: NSRect) {
        super.init(frame: frame); setAccessibilityRole(.menuButton)
        actionBlock = { [weak self] in
            self?.open(keyboard: NSApp.currentEvent?.type == .keyDown || NSApp.currentEvent?.type == .keyUp)
        }
    }
    required init?(coder: NSCoder) { nil }
    private func open(keyboard: Bool) {
        guard isEnabled, let window else { return }
        presenter.show(items: items, appearance: appearanceChoice, scale: scale, anchor: window.convertToScreen(convert(bounds, to: nil)), owner: window, reducedMotion: reducedMotion, keyboard: keyboard)
    }
    override func accessibilityPerformPress() -> Bool { guard isEnabled, window != nil else { return false }; open(keyboard: true); return true }
    override func draw(_ dirtyRect: NSRect) {
        let art = NativeRetroArtwork.ArtworkView(frame: bounds); art.kind = .button; art.appearanceChoice = appearanceChoice; art.pressed = pressed; art.enabled = isEnabled; art.draw(dirtyRect)
        NativeRetroMenuRow.drawTitle(title, in: bounds.insetBy(dx: 7, dy: 3), appearance: appearanceChoice, scale: scale, color: isEnabled ? .black : NativeRetro.color("muted", appearance: appearanceChoice))
        super.draw(dirtyRect)
    }
}

// MARK: - Menu session and nested levels

@MainActor final class NativeRetroMenuPresenter {
    private struct Level { let entries: [NativeRetroMenuEntry]; let panel: NativeRetroPopupPanel; let scroll: NSScrollView; let rows: [NativeRetroMenuRow] }
    private var levels: [Level] = []
    private(set) var highlighted: Int?
    private var selections: [Int?] = []
    private weak var owner: NSWindow?
    private weak var responder: NSResponder?
    private var appearance = PanelAppearance.windows95
    private var scale: CGFloat = 1
    private var monitor: Any?
    private var global: Any?
    private var observers: [NSObjectProtocol] = []
    private var query = ""
    private var queryTime: TimeInterval = 0
    private var spaceArmed = false
    var isPresented: Bool { !levels.isEmpty }
    var windows: [NSWindow] { levels.map(\.panel) }
    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }; if let global { NSEvent.removeMonitor(global) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    func show(items: [NativeRetroMenuEntry], appearance: PanelAppearance, scale: CGFloat, anchor: CGRect, owner: NSWindow?, reducedMotion: Bool, keyboard: Bool) {
        close(); guard appearance.isRetro, !items.isEmpty else { return }
        NativeRetroHelpCoordinator.shared.hide()
        self.owner = owner; responder = owner?.firstResponder; self.appearance = appearance; self.scale = scale
        append(items, anchor: anchor, submenu: false)
        if keyboard { select(firstEnabled(), at: 0) }
        if appearance == .windowsXP, !reducedMotion, !keyboard, let panel = levels.first?.panel {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.15; context.timingFunction = CAMediaTimingFunction(name: .linear); panel.animator().alphaValue = 1 }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown || event.type == .keyUp { return self.handle(event) ? nil : event }
            if !self.levels.contains(where: { $0.panel === event.window }) { self.close(returnFocus: false) }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.close(returnFocus: false) } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.close(returnFocus: false) } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPresented else { return }
                if !self.levels.contains(where: { $0.panel === NSApp.keyWindow }) { self.close(returnFocus: false) }
            }
        })
        if let owner {
            for name in [NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.close(returnFocus: false) } })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: owner, queue: .main) { [weak self, weak owner] _ in
                MainActor.assumeIsolated { if owner?.isVisible != true { self?.close(returnFocus: false) } }
            })
        }
    }
    private func append(_ entries: [NativeRetroMenuEntry], anchor: CGRect, submenu: Bool) {
        let available = (owner?.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let naturalWidth = entries.map { ($0.title as NSString).size(withAttributes: [.font: NativeRetro.font(appearance, scale: scale)]).width + 54 }.max() ?? 200
        let width = min(max(220 * scale, naturalWidth), min(480 * scale, available.width - 8))
        let document = NativeRetroMenuDocument(frame: CGRect(x: 0, y: 0, width: width - 6, height: 0)); document.choice = appearance
        var rows: [NativeRetroMenuRow] = []; var y: CGFloat = 2
        let depth = levels.count
        for (index, entry) in entries.enumerated() {
            let row = NativeRetroMenuRow(frame: CGRect(x: 2, y: y, width: width - 10, height: entry.separator ? 7 : 23 * scale))
            row.entry = entry; row.appearanceChoice = appearance; row.scale = scale; row.isEnabled = !entry.separator && entry.enabled()
            row.setAccessibilityRole(entry.separator ? .splitter : .menuItem); row.setAccessibilityLabel(entry.title); row.setAccessibilityValue(entry.checked ? 1 : 0)
            row.actionBlock = { [weak self] in self?.activate(index, at: depth) }
            row.entered = { [weak self] in self?.select(index, at: depth, pointer: true) }
            rows.append(row); document.addSubview(row); y += row.frame.height
        }
        document.frame.size.height = y + 2
        let height = min(y + 8, available.height - 12)
        let root = NativeRetroMenuDocument(frame: CGRect(x: 0, y: 0, width: width, height: height)); root.choice = appearance
        let scroll = NSScrollView(frame: root.bounds.insetBy(dx: 3, dy: 3)); scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.documentView = document; root.addSubview(scroll)
        if y > height - 6 { let rail = NativeRetroScrollbar(scroll: scroll); rail.appearanceChoice = appearance; scroll.addSubview(rail); rail.refresh() }
        let panel = NativeRetroPopupPanel(contentRect: root.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hasShadow = true; panel.level = .popUpMenu; panel.contentView = root; panel.cancel = { [weak self] in self?.close() }
        var origin = NativeRetroPopoverController<EmptyView>.origin(anchor: anchor, size: root.bounds.size, available: available)
        if submenu { origin.x = anchor.maxX + width <= available.maxX ? anchor.maxX : max(available.minX, anchor.minX - width); origin.y = min(max(available.minY, anchor.maxY - height), available.maxY - height) }
        panel.setFrameOrigin(origin); NativeRetroPopupRegistry.register(panel); owner?.addChildWindow(panel, ordered: .above)
        levels.append(Level(entries: entries, panel: panel, scroll: scroll, rows: rows)); selections.append(nil); highlighted = nil
        panel.makeKeyAndOrderFront(nil)
    }
    private func firstEnabled() -> Int? { levels.last?.entries.indices.first { levels.last!.entries[$0].enabled() && !levels.last!.entries[$0].separator } }
    private func select(_ index: Int?, at depth: Int, pointer: Bool = false) {
        guard levels.indices.contains(depth) else { return }
        if levels.count > depth + 1 { removeLevels(after: depth) }
        let level = levels[depth]
        guard let index, level.entries.indices.contains(index), !level.entries[index].separator, level.entries[index].enabled() else { return }
        selections[depth] = index; highlighted = index
        for (i, row) in level.rows.enumerated() { row.selected = i == index; row.needsDisplay = true }
        level.rows[index].scrollToVisible(level.rows[index].bounds)
        if pointer, !level.entries[index].children.isEmpty { openSubmenu(index, at: depth) }
    }
    private func openSubmenu(_ index: Int, at depth: Int) {
        guard levels.indices.contains(depth), levels[depth].entries.indices.contains(index) else { return }
        let item = levels[depth].entries[index]; guard item.enabled(), !item.children.isEmpty else { return }
        removeLevels(after: depth)
        let row = levels[depth].rows[index]; let anchor = levels[depth].panel.convertToScreen(row.convert(row.bounds, to: nil))
        append(item.children, anchor: anchor, submenu: true); select(firstEnabled(), at: depth + 1)
    }
    func activate(_ index: Int, at depth: Int) {
        guard levels.indices.contains(depth), levels[depth].entries.indices.contains(index) else { return }
        let item = levels[depth].entries[index]; guard item.enabled(), !item.separator else { return }
        if !item.children.isEmpty { openSubmenu(index, at: depth); return }
        close(); item.action()
    }
    func handle(_ event: NSEvent) -> Bool {
        guard let level = levels.last else { return false }
        if event.type == .keyUp { if event.keyCode == 49, spaceArmed, let selected = selections.last ?? nil { spaceArmed = false; activate(selected, at: levels.count - 1); return true }; return false }
        let enabled = level.entries.indices.filter { !level.entries[$0].separator && level.entries[$0].enabled() }
        let depth = levels.count - 1; let selected = selections.last ?? nil
        switch event.keyCode {
        case 53, 48: close(); return event.keyCode == 53
        case 125, 126:
            guard !enabled.isEmpty else { return true }
            let current = selected.flatMap { enabled.firstIndex(of: $0) } ?? (event.keyCode == 125 ? -1 : 0)
            select(enabled[(current + (event.keyCode == 125 ? 1 : enabled.count - 1)) % enabled.count], at: depth); return true
        case 115: select(enabled.first, at: depth); return true
        case 119: select(enabled.last, at: depth); return true
        case 124: if let selected { openSubmenu(selected, at: depth) }; return true
        case 123: if depth > 0 { removeLevels(after: depth - 1); levels.last?.panel.makeKey(); highlighted = selections.last ?? nil }; return true
        case 36, 76: if let selected { activate(selected, at: depth) }; return true
        case 49: if !event.isARepeat { spaceArmed = true }; return true
        default:
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            let now = ProcessInfo.processInfo.systemUptime; if now - queryTime > 1 { query = "" }; queryTime = now; query += chars.lowercased()
            if let match = enabled.first(where: { level.entries[$0].title.lowercased().hasPrefix(query) }) { select(match, at: depth) }
            return true
        }
    }
    private func removeLevels(after depth: Int) {
        while levels.count > depth + 1 { let old = levels.removeLast(); selections.removeLast(); owner?.removeChildWindow(old.panel); old.panel.orderOut(nil); old.panel.close() }
    }
    func close(returnFocus: Bool = true) {
        let restore = returnFocus && levels.contains { $0.panel === NSApp.keyWindow }
        removeLevels(after: -1); highlighted = nil; query = ""; spaceArmed = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; if let global { NSEvent.removeMonitor(global); self.global = nil }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if restore, let owner, owner.isVisible { owner.makeKey(); if let responder { owner.makeFirstResponder(responder) } }
        owner = nil; responder = nil
    }
}

@MainActor private final class NativeRetroMenuDocument: NSView {
    var choice = PanelAppearance.windows95
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { (choice == .windowsXP ? NSColor.white : NativeRetro.color("surface", appearance: choice)).setFill(); bounds.fill(); NativeRetro.color("line", appearance: choice).setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke() }
}

@MainActor private final class NativeRetroMenuRow: NativeRetroControl {
    var entry = NativeRetroMenuEntry("")
    var scale: CGFloat = 1
    var entered: () -> Void = {}
    private let help = NativeRetroHelpAnchor()
    override init(frame: NSRect) { super.init(frame: frame); addSubview(help) }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); help.frame = bounds; help.choice = appearanceChoice; help.scale = scale; help.message = entry.title }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); entered() }
    override func draw(_ dirtyRect: NSRect) {
        if entry.separator { NativeRetro.color("line", appearance: appearanceChoice).setFill(); CGRect(x: 3, y: 3, width: bounds.width - 6, height: 1).fill(); return }
        if selected { NativeRetro.rgb(appearanceChoice == .windowsXP ? 0x316ac5 : 0x000080).setFill(); bounds.fill() }
        let color: NSColor = !isEnabled ? NativeRetro.color("muted", appearance: appearanceChoice) : selected ? .white : .black
        Self.drawTitle(entry.title, in: CGRect(x: 23, y: 4, width: bounds.width - 46, height: bounds.height - 6), appearance: appearanceChoice, scale: scale, color: color)
        if entry.checked { Self.drawTitle("✓", in: CGRect(x: 4, y: 4, width: 18, height: bounds.height - 6), appearance: appearanceChoice, scale: scale, color: color) }
        if !entry.children.isEmpty { Self.drawTitle("▶", in: CGRect(x: bounds.width - 18, y: 4, width: 16, height: bounds.height - 6), appearance: appearanceChoice, scale: scale, color: color) }
    }
    static func drawTitle(_ title: String, in rect: CGRect, appearance: PanelAppearance, scale: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: rect, withAttributes: [.font: NativeRetro.font(appearance, scale: scale), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
