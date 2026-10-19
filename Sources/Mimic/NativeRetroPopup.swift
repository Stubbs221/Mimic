//
//  NativeRetroPopup.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Main-panel dismissal recognizes owned native popups rather than treating their clicks as outside.
@MainActor enum NativeRetroPopupRegistry {
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    static func register(_ window: NSWindow) { windows.add(window) }
    static func owns(_ window: NSWindow?) -> Bool { window.map { windows.contains($0) } ?? false }
}

@MainActor final class NativeRetroPopupPanel: NSPanel {
    var cancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { cancel() }
}

extension View {
    /// The original SwiftUI presentation remains the path for Tile Grid/legacy.
    func mimicPopover<Content: View>(isPresented: Binding<Bool>, width: CGFloat = 400, @ViewBuilder content: () -> Content) -> some View {
        modifier(NativeRetroPopoverModifier(presented: isPresented, width: width, popup: content()))
    }
}

private struct NativeRetroPopoverModifier<Popup: View>: ViewModifier {
    @Binding var presented: Bool
    let width: CGFloat
    let popup: Popup
    @Environment(\.mimicPanelAppearance) private var appearance
    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { presented && !appearance.isRetro }, set: { if !appearance.isRetro { presented = $0 } }), arrowEdge: .bottom) { popup }
            .background(NativeRetroPopoverAnchor(presented: $presented, width: width, popup: popup))
            .onChange(of: appearance) { _, _ in presented = false }
    }
}

private struct NativeRetroPopoverAnchor<Popup: View>: NSViewRepresentable {
    @Binding var presented: Bool
    let width: CGFloat
    let popup: Popup
    @Environment(\.mimicPanelAppearance) private var appearance
    @Environment(\.mimicTextScale) private var scale
    @Environment(\.mimicMotionSettings) private var motion
    func makeCoordinator() -> NativeRetroPopoverController<Popup> { NativeRetroPopoverController() }
    func makeNSView(context: Context) -> NativeRetroPopupAnchorView { NativeRetroPopupAnchorView() }
    func updateNSView(_ view: NativeRetroPopupAnchorView, context: Context) {
        let controller = context.coordinator
        controller.dismissed = { presented = false }
        let body = popup.environment(\.mimicPanelAppearance, appearance).environment(\.mimicTextScale, scale)
            .environment(\.mimicMotionSettings, motion).environment(\.mimicPresentationVisible, true)
            .preferredColorScheme(.light).mimicFont(.body).buttonStyle(MimicAuxiliaryButtonStyle())
            .progressViewStyle(MimicActivityProgressStyle())
        let content = AnyView(body)
        view.attached = { [weak view, weak controller] in
            guard let view, let controller else { return }
            controller.update(content: content, appearance: appearance, width: width, anchor: view, presented: presented)
        }
        view.attached?()
    }
    static func dismantleNSView(_ view: NativeRetroPopupAnchorView, coordinator: NativeRetroPopoverController<Popup>) { coordinator.close(notify: false) }
}

@MainActor final class NativeRetroPopupAnchorView: NSView {
    var attached: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { attached?() } }
    override func layout() { super.layout(); attached?() }
}

// MARK: - Retained popup transaction

/// One hosting/document identity is updated while the popup is open; only presentation owns its lifetime.
@MainActor final class NativeRetroPopoverController<Popup: View> {
    private(set) var panel: NativeRetroPopupPanel?
    private var hosting: NSHostingView<AnyView>?
    private var scroll: NSScrollView?
    private var rail: NativeRetroScrollbar?
    private weak var owner: NSWindow?
    private weak var responder: NSResponder?
    private weak var anchor: NSView?
    private var appearance = PanelAppearance.legacy
    private var monitor: Any?
    private var global: Any?
    private var observers: [NSObjectProtocol] = []
    var dismissed: () -> Void = {}
    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }; if let global { NSEvent.removeMonitor(global) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    func update(content: AnyView, appearance: PanelAppearance, width: CGFloat, anchor: NSView, presented: Bool) {
        guard appearance.isRetro, presented else { close(notify: false); return }
        if panel != nil, self.appearance != appearance { close(); return }
        guard let owner = anchor.window, owner.isVisible, !anchor.isHiddenOrHasHiddenAncestor, !anchor.bounds.isEmpty else { close(returnFocus: false); return }
        self.anchor = anchor; self.appearance = appearance
        if let hosting { hosting.rootView = content; resize(width: width); return }
        self.owner = owner; responder = owner.firstResponder
        let hosting = NSHostingView(rootView: content); self.hosting = hosting
        let available = (owner.screen ?? NSScreen.main)?.visibleFrame ?? owner.frame
        let panelWidth = min(width + 17, max(40, available.width - 8))
        hosting.frame = CGRect(x: 0, y: 0, width: max(1, panelWidth - 17), height: 1)
        hosting.layoutSubtreeIfNeeded()
        let height = min(max(80, ceil(hosting.fittingSize.height)), max(80, available.height - 16))
        let root = NSView(frame: CGRect(x: 0, y: 0, width: panelWidth, height: height))
        let background = NativeRetroArtwork.ArtworkView(frame: root.bounds); background.kind = .frame; background.appearanceChoice = appearance; root.addSubview(background)
        let scroll = NSScrollView(frame: root.bounds.insetBy(dx: 3, dy: 3)); scroll.hasVerticalScroller = false; scroll.drawsBackground = false
        self.scroll = scroll; background.autoresizingMask = [.width, .height]
        hosting.frame.size = CGSize(width: max(1, scroll.bounds.width - 17), height: max(height - 6, ceil(hosting.fittingSize.height)))
        scroll.documentView = hosting; root.addSubview(scroll)
        let rail = NativeRetroScrollbar(scroll: scroll); rail.appearanceChoice = appearance; scroll.addSubview(rail); rail.refresh()
        self.rail = rail
        let panel = NativeRetroPopupPanel(contentRect: root.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .popUpMenu; panel.contentView = root; panel.cancel = { [weak self] in self?.close() }
        panel.backgroundColor = NativeRetro.color("surface", appearance: appearance); panel.hasShadow = true
        let rect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.setFrameOrigin(Self.origin(anchor: rect, size: root.bounds.size, available: available))
        self.panel = panel; NativeRetroPopupRegistry.register(panel); owner.addChildWindow(panel, ordered: .above); panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak panel] event in
            guard let self else { return event }
            if event.type == .keyDown, event.window === panel, event.keyCode == 53, (panel?.firstResponder as? NSTextView)?.hasMarkedText() != true { self.close(); return nil }
            if event.type != .keyDown, event.window !== panel, !NativeRetroPopupRegistry.owns(event.window) { self.close(returnFocus: false) }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.close(returnFocus: false) } }
        for name in [NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(returnFocus: false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { if !NativeRetroPopupRegistry.owns(NSApp.keyWindow) { self?.close(returnFocus: false) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.close(returnFocus: false) } })
    }
    static func origin(anchor: CGRect, size: CGSize, available: CGRect) -> CGPoint {
        let below = anchor.minY - size.height
        let y = below >= available.minY ? below : min(anchor.maxY, available.maxY - size.height)
        return CGPoint(x: min(max(anchor.midX - size.width / 2, available.minX + 4), available.maxX - size.width - 4), y: max(available.minY + 4, y))
    }
    private func resize(width: CGFloat) {
        guard let panel, let hosting, let scroll, let owner, let anchor, let root = panel.contentView else { return }
        let available = (owner.screen ?? NSScreen.main)?.visibleFrame ?? owner.frame
        hosting.layoutSubtreeIfNeeded()
        let size = CGSize(width: min(width + 17, available.width - 8), height: min(max(80, ceil(hosting.fittingSize.height)), max(80, available.height - 16)))
        if root.bounds.size != size { panel.setContentSize(size) }
        scroll.frame = root.bounds.insetBy(dx: 3, dy: 3)
        let documentSize = CGSize(width: max(1, scroll.bounds.width - 17), height: max(scroll.bounds.height, ceil(hosting.fittingSize.height)))
        if hosting.frame.size != documentSize { hosting.frame.size = documentSize }
        rail?.refresh()
        let point = Self.origin(anchor: owner.convertToScreen(anchor.convert(anchor.bounds, to: nil)), size: size, available: available)
        if panel.frame.origin != point { panel.setFrameOrigin(point) }
    }
    func close(notify: Bool = true, returnFocus: Bool = true) {
        guard let panel else { return }
        let restore = returnFocus && NSApp.keyWindow === panel
        self.panel = nil; owner?.removeChildWindow(panel); panel.orderOut(nil); panel.close(); hosting = nil; scroll = nil; rail = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; if let global { NSEvent.removeMonitor(global); self.global = nil }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if restore, let owner, owner.isVisible { owner.makeKey(); if let responder { owner.makeFirstResponder(responder) } }
        self.owner = nil; responder = nil; anchor = nil
        if notify { dismissed() }
    }
}
