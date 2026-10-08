// Created by Василий Маслов on 08.10.2026.
import AppKit
import SwiftUI

/// B uses the same NSMenu command model as legacy; only its window and navigation differ.
@MainActor final class ExpressMenuController {
    private var window: ExpressMenuPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private weak var previousWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    func owns(_ candidate: NSWindow?) -> Bool { candidate != nil && candidate === window }
    func show(menu: NSMenu, model: TaskCoordinator, anchor: NSRect, screen: NSRect) {
        close()
        previousWindow = NSApp.keyWindow; previousResponder = previousWindow?.firstResponder
        let panel = ExpressMenuPanel(contentRect: .init(x: 0, y: 0, width: 320, height: 380), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .popUpMenu
        panel.dismiss = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: ExpressMenuView(menu: menu, invoke: { [weak self] item in
            self?.close()
            if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        }, dismiss: { [weak self] in self?.close() }).modifier(MimicAppearanceRoot(store: model.appearance)))
        let height = min(screen.height, ceil(panel.contentView?.fittingSize.height ?? 380))
        panel.setContentSize(.init(width: 320, height: height))
        panel.setFrameOrigin(.init(x: min(max(anchor.midX - 160, screen.minX), screen.maxX - 320), y: max(screen.minY, anchor.minY - height)))
        window = panel
        panel.makeKeyAndOrderFront(nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            if event.window !== panel { self?.close(returnFocus: false) }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close(returnFocus: false) }
        }
    }
    func close(returnFocus: Bool = true) {
        let restore = returnFocus && NSApp.keyWindow === window
        window?.orderOut(nil); window = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if restore, let previousWindow, previousWindow.isVisible {
            previousWindow.makeKey()
            if let previousResponder { previousWindow.makeFirstResponder(previousResponder) }
        }
        previousWindow = nil; previousResponder = nil
    }
}

private final class ExpressMenuPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

struct ExpressMenuView: View {
    let menu: NSMenu
    let invoke: (NSMenuItem) -> Void
    let dismiss: () -> Void
    @FocusState private var focused: Int?
    private var theme = MimicTheme()
    private var enabled: [Int] { menu.items.indices.filter { !menu.items[$0].isSeparatorItem && menu.items[$0].isEnabled } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(text("app.name"), systemImage: "sparkles").mimicFont(.heading)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(menu.items.enumerated()), id: \.offset) { index, item in
                    if item.isSeparatorItem { Divider().padding(.vertical, 2) }
                    else {
                        Button { invoke(item) } label: { Text(item.title).frame(maxWidth: .infinity, alignment: .leading) }
                            .buttonStyle(TileGridButtonStyle()).disabled(!item.isEnabled).focused($focused, equals: index)
                    }
                }
            }.padding(8).background(theme.color("surface"), in: RoundedRectangle(cornerRadius: theme.cardRadius))
        }.padding(20).frame(width: 320).background(theme.color("paper"), in: RoundedRectangle(cornerRadius: theme.panelRadius))
            .onAppear { focused = enabled.first }
            .onMoveCommand { direction in
                guard !enabled.isEmpty else { return }
                let current = enabled.firstIndex(of: focused ?? -1) ?? 0
                if direction == .down { focused = enabled[(current + 1) % enabled.count] }
                if direction == .up { focused = enabled[(current + enabled.count - 1) % enabled.count] }
            }.onExitCommand(perform: dismiss)
            .onKeyPress(.return) {
                guard let focused, enabled.contains(focused) else { return .ignored }
                invoke(menu.items[focused]); return .handled
            }
            .accessibilityIdentifier("express.menu")
    }
}
