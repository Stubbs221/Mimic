//
//  AIUsageTrendPopover.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// The transparent anchor stays confined to the sparkline, so the native arrow targets its center.
struct AIUsageTrendPopoverAnchor: NSViewRepresentable {
    @Environment(\.mimicPanelAppearance) private var appearance
    let provider: AIProvider
    let state: AIUsageTrendPopoverState
    func makeCoordinator() -> AIUsageTrendPopoverController { AIUsageTrendPopoverController(provider: self.provider, state: self.state) }
    func makeNSView(context: Context) -> NSView {
        let view = AIUsageTrendAnchorView(); context.coordinator.attach(view); return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.appearance(appearance); context.coordinator.synchronize() }
    static func dismantleNSView(_ nsView: NSView, coordinator: AIUsageTrendPopoverController) { coordinator.detach() }
}

/// The anchor supplies geometry without intercepting the SwiftUI button's mouse events.
final class AIUsageTrendAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Registers native detail windows with the menu's existing click/Escape lifecycle.
/// Weak ownership prevents a retained menu view tree from orphaning a popover after orderOut.
@MainActor
final class AIUsageTrendPopoverController: NSObject, NSPopoverDelegate {
    private static let live = NSHashTable<AIUsageTrendPopoverController>.weakObjects()
    let provider: AIProvider
    let state: AIUsageTrendPopoverState
    private let popover = NSPopover()
    private let hosting: NSHostingView<AIUsageTrendDetail>
    private weak var anchor: NSView?
    private var presenting = false

    init(provider: AIProvider, state: AIUsageTrendPopoverState) {
        self.provider = provider; self.state = state
        self.hosting = NSHostingView(rootView: AIUsageTrendDetail(provider: provider, state: state))
        super.init()
        let content = NSViewController(); content.view = self.hosting
        self.popover.contentViewController = content; self.popover.behavior = .applicationDefined
        self.popover.animates = false; self.popover.delegate = self
        self.state.presentationChanged = { [weak self] in self?.synchronize() }
        self.state.contentChanged = { [weak self] in self?.resize() }
        Self.live.add(self)
    }
    func appearance(_ value: PanelAppearance) {
        hosting.rootView = AIUsageTrendDetail(appearance: value, provider: provider, state: state)
    }
    var detailWindow: NSWindow? { self.popover.isShown ? self.hosting.window : nil }
    func attach(_ view: NSView) { self.anchor = view }
    func dismiss() { self.state.dismiss() }
    func detach() {
        self.state.detach(); self.popover.delegate = nil
        if self.popover.isShown { self.popover.close() }
        self.anchor = nil
    }
    func synchronize() {
        guard !self.presenting else { return }
        if !self.state.isPresented {
            if self.popover.isShown { self.popover.close() }
            return
        }
        guard let anchor = self.anchor, let window = anchor.window, window.isVisible, !anchor.bounds.isEmpty else {
            self.state.dismiss(); return
        }
        if !self.popover.isShown {
            for other in Self.live.allObjects where other !== self { other.dismiss() }
            self.presenting = true; self.resize()
            self.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            self.presenting = false
        }
        if self.state.isPinned { self.hosting.window?.makeKey() }
    }
    private func resize() {
        let size = self.hosting.fittingSize
        self.popover.contentSize = NSSize(width: 340, height: max(1, ceil(size.height)))
    }
    func popoverDidClose(_ notification: Notification) { self.state.dismiss() }

    // MARK: - Main menu integration

    static func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return Self.live.allObjects.contains { $0.detailWindow === window }
    }
    static func dismissAll() { for controller in Self.live.allObjects { controller.dismiss() } }
    static func dismiss(for provider: AIProvider) { for controller in Self.live.allObjects where controller.provider == provider { controller.dismiss() } }
    /// Escape takes precedence over closing the menu; arrows belong to explicit detail interaction.
    static func handleKey(_ event: NSEvent) -> Bool {
        guard let controller = Self.live.allObjects.first(where: { $0.detailWindow != nil }) else { return false }
        if event.keyCode == 53 { controller.dismiss(); return true }
        guard controller.state.isPinned || self.owns(event.window) else { return false }
        if event.keyCode == 123 { controller.state.moveSelection(-1); return true }
        if event.keyCode == 124 { controller.state.moveSelection(1); return true }
        return false
    }
}
