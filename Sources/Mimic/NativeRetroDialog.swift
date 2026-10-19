//
//  NativeRetroDialog.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import Observation
import SwiftUI
import MimicCore

/// The caller still consumes the existing modal response and owns clearing successful secure input.
/// Cancellation clears secure fields before returning; no input is serialized into presentation state.
@MainActor enum NativeRetroDialog {
    static func run(_ alert: NSAlert, store: PanelAppearanceStore?, cancel: Int = 1, defaultButton: Int = 0) -> NSApplication.ModalResponse {
        guard let store, store.selection.isRetro else { return alert.runModal() }
        return NativeRetroDialogSession(alert: alert, store: store, cancel: cancel, defaultButton: defaultButton).run()
    }
}

extension View {
    func mimicConfirmationDialog(_ title: String, isPresented: Binding<Bool>, message: String, confirmation: String, store: PanelAppearanceStore, action: @escaping () -> Void) -> some View {
        modifier(NativeRetroConfirmation(title: title, presented: isPresented, message: message, confirmation: confirmation, store: store, action: action))
    }
}

private struct NativeRetroConfirmation: ViewModifier {
    let title: String
    @Binding var presented: Bool
    let message: String
    let confirmation: String
    let store: PanelAppearanceStore
    let action: () -> Void
    @State private var nativePresented = false
    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(get: { presented && !store.selection.isRetro && !nativePresented }, set: { if !store.selection.isRetro && !nativePresented { presented = $0 } })) {
            Button(confirmation, role: .destructive, action: action)
        } message: { Text(message) }
        .onChange(of: presented) { _, value in
            guard value, store.selection.isRetro, !nativePresented else { return }
            nativePresented = true
            DispatchQueue.main.async {
                guard presented else { nativePresented = false; return }
                let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
                alert.addButton(withTitle: text("cancel")); alert.addButton(withTitle: confirmation)
                let response = NativeRetroDialog.run(alert, store: store, cancel: 0, defaultButton: 0)
                presented = false
                nativePresented = false
                if response == .alertSecondButtonReturn { action() }
            }
        }
    }
}

@MainActor final class NativeRetroDialogSession: NSObject, NSWindowDelegate {
    let alert: NSAlert
    let store: PanelAppearanceStore
    let cancelIndex: Int
    let defaultIndex: Int
    let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let stack = NSStackView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var footer: NSHostingView<AnyView>?
    private var chrome: NativeRetroWindowAdapter?
    private(set) var result: NSApplication.ModalResponse?
    private var monitor: Any?
    private var decorations: [(NSSecureTextField, NativeRetroEditorDecoration, NativeRetroArtwork.ArtworkView)] = []
    init(alert: NSAlert, store: PanelAppearanceStore, cancel: Int, defaultButton: Int) {
        self.alert = alert; self.store = store; cancelIndex = cancel; defaultIndex = defaultButton
        super.init()
        panel.isReleasedWhenClosed = false; panel.delegate = self; panel.title = alert.messageText
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        title.stringValue = alert.messageText; detail.stringValue = alert.informativeText
        stack.addArrangedSubview(title)
        if !alert.informativeText.isEmpty { stack.addArrangedSubview(detail) }
        if let accessory = alert.accessoryView { stack.addArrangedSubview(accessory) }
        let footer = NSHostingView(rootView: AnyView(EmptyView())); self.footer = footer; stack.addArrangedSubview(footer)
        for view in stack.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        panel.contentView = stack
        for field in secureFields(stack) {
            let decoration = NativeRetroEditorDecoration(frame: field.bounds); decoration.autoresizingMask = [.width, .height]
            let artwork = NativeRetroArtwork.ArtworkView(frame: field.bounds); artwork.kind = .inputBorder; artwork.autoresizingMask = [.width, .height]
            field.addSubview(decoration); field.addSubview(artwork); decorations.append((field, decoration, artwork))
        }
        style(); stack.layoutSubtreeIfNeeded(); panel.setContentSize(CGSize(width: 440, height: max(150, stack.fittingSize.height)))
        chrome = NativeRetroWindowAdapter(window: panel, store: store); NativeRetroPopupRegistry.register(panel)
        observe()
    }
    private func observe() {
        _ = withObservationTracking { store.selection } onChange: { [weak self] in DispatchQueue.main.async { self?.style(); self?.observe() } }
    }
    private func style() {
        let appearance = store.selection
        title.font = appearance.isRetro ? NativeRetro.font(appearance, role: .heading) : .boldSystemFont(ofSize: 13)
        detail.font = appearance.isRetro ? NativeRetro.font(appearance) : .systemFont(ofSize: 13)
        title.textColor = appearance.isRetro ? NativeRetro.color("ink", appearance: appearance) : .labelColor; detail.textColor = title.textColor
        let buttons = alert.buttons.map(\.title)
        let content = HStack {
            Spacer(minLength: 0)
            ForEach(buttons.indices, id: \.self) { index in Button(buttons[index]) { [weak self] in self?.finish(index) } }
        }.buttonStyle(MimicAuxiliaryButtonStyle()).modifier(MimicAppearanceRoot(store: store))
        footer?.rootView = AnyView(content)
        for (_, decoration, artwork) in decorations {
            decoration.choice = appearance; decoration.apply(); artwork.isHidden = !appearance.isRetro
            artwork.appearanceChoice = appearance; artwork.needsDisplay = true
        }
    }
    private func secureFields(_ view: NSView) -> [NSSecureTextField] { (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap(secureFields) }
    func run() -> NSApplication.ModalResponse {
        let previousWindow = NSApp.keyWindow, previousResponder = previousWindow?.firstResponder
        panel.center(); panel.makeKeyAndOrderFront(nil)
        if let field = secureFields(stack).first { panel.makeFirstResponder(field) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        _ = NSApp.runModal(for: panel)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panel.delegate = nil; panel.orderOut(nil); panel.close()
        if let previousWindow, previousWindow.isVisible { previousWindow.makeKey(); if let previousResponder { previousWindow.makeFirstResponder(previousResponder) } }
        return result ?? .init(rawValue: 1000 + cancelIndex)
    }
    private func finish(_ index: Int) {
        guard result == nil else { return }
        result = .init(rawValue: 1000 + index)
        if index == cancelIndex { secureFields(stack).forEach { $0.stringValue = "" } }
        if NSApp.modalWindow === panel { NSApp.stopModal(withCode: result!) }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel, (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        if event.keyCode == 53 { finish(cancelIndex); return true }
        if event.keyCode == 36 || event.keyCode == 76 { finish(defaultIndex); return true }
        return false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(cancelIndex); return false }
}
