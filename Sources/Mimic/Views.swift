//
//  Views.swift
//  Mimic
//
//  Created by Василий Маслов on 01.10.2026.
import AppKit
import SwiftTerm
import SwiftUI
import MimicCore

/// History owns an independent output subscription. PTY ownership remains in TaskCoordinator.
struct TerminalContainer: NSViewRepresentable {
    let model: TaskCoordinator
    let id: UUID
    func makeCoordinator() -> TerminalDelegate { TerminalDelegate(model: self.model, id: self.id) }
    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = .textBackgroundColor
        terminal.nativeForegroundColor = .textColor
        terminal.backgroundOpacity = 1
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.getTerminal().changeScrollback(10000)
        terminal.feed(byteArray: Array(self.model.replay(id: self.id))[...])
        self.model.attachTerminal(owner: context.coordinator.subscriptionID) { [weak terminal, id = self.id] task, data in
            if task == id { terminal?.feed(byteArray: Array(data)[...]) }
        }
        terminal.setAccessibilityLabel(text("terminal"))
        self.focusIfRequested(terminal, coordinator: context.coordinator)
        return terminal
    }

    func updateNSView(_ view: TerminalView, context: Context) { self.focusIfRequested(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalDelegate) {
        view.terminalDelegate = nil
        coordinator.model.detachTerminal(owner: coordinator.subscriptionID)
    }

    private func focusIfRequested(_ view: TerminalView, coordinator: TerminalDelegate) {
        guard self.model.terminalFocusTaskID == self.id, coordinator.lastFocusRequest != self.model.terminalFocusRequest else { return }
        let request = self.model.terminalFocusRequest
        coordinator.lastFocusRequest = request
        DispatchQueue.main.async { [weak view] in
            guard self.model.terminalFocusTaskID == self.id, self.model.terminalFocusRequest == request else { return }
            view?.window?.makeFirstResponder(view)
        }
    }
}

final class TerminalDelegate: NSObject, TerminalViewDelegate {
    unowned let model: TaskCoordinator
    let id: UUID
    let subscriptionID = UUID()
    var lastFocusRequest: UUID?
    init(model: TaskCoordinator, id: UUID) { self.model = model; self.id = id }
    func sizeChanged(source _: TerminalView, newCols: Int, newRows: Int) { Task { @MainActor [model, id] in model.resize(id: id, columns: newCols, rows: newRows) } }
    func setTerminalTitle(source _: TerminalView, title _: String) { }
    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) { }
    func send(source _: TerminalView, data: ArraySlice<UInt8>) { let bytes = Data(data); Task { @MainActor [model, id] in model.input(id: id, data: bytes) } }
    func scrolled(source _: TerminalView, position _: Double) { }
    func requestOpenLink(source _: TerminalView, link: String, params _: [String: String]) {
        if let url = URL(string: link), ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
    }

    func clipboardCopy(source _: TerminalView, content _: Data) { }
    func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) { }
}

// MARK: - Bootstrap terminal presentation

/// A bounded, task-owned screen survives hidden mini cards and completion. Never serialized.
@MainActor final class BootstrapTerminalSession {
    private weak var model: TaskCoordinator?
    let id: UUID
    private let owner = UUID()
    private(set) var snapshot: Data
    private(set) var hasOutput: Bool
    private var screen: TerminalView?
    private var delegate: TerminalDelegate?
    init(model: TaskCoordinator, record: TaskRecord) {
        self.model = model; self.id = record.id
        self.snapshot = Data(model.replay(id: record.id).suffix(128 * 1024)); self.hasOutput = !self.snapshot.isEmpty
        model.attachTerminal(owner: self.owner) { [weak self] task, bytes in
            guard let self, task == self.id else { return }
            self.hasOutput = self.hasOutput || !bytes.isEmpty
            if self.model?.records.first(where: { $0.id == self.id })?.hasPrivateInput == true {
                self.snapshot = Data()
                if self.screen == nil { self.hasOutput = false }
            } else {
                self.snapshot.append(bytes); self.snapshot = Data(self.snapshot.suffix(128 * 1024))
            }
            self.screen?.feed(byteArray: Array(bytes)[...])
        }
    }
    func view() -> TerminalView {
        if let screen { return screen }
        let view = TerminalView(frame: .zero)
        view.nativeBackgroundColor = .textBackgroundColor; view.nativeForegroundColor = .textColor
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.getTerminal().changeScrollback(1500)
        view.setAccessibilityLabel(text("terminal"))
        if let model {
            let delegate = TerminalDelegate(model: model, id: self.id)
            self.delegate = delegate; view.terminalDelegate = delegate
        }
        view.feed(byteArray: Array(self.snapshot)[...]); self.screen = view
        return view
    }
    /// A mounted screen may keep its scrollback, but echoed input cannot become replay data.
    func discardReplayAfterPrivateInput() { self.snapshot = Data(); if self.screen == nil { self.hasOutput = false } }
    func setInputEnabled(_ enabled: Bool) { self.screen?.terminalDelegate = enabled ? self.delegate : nil }
    func stop() {
        self.model?.detachTerminal(owner: self.owner)
        self.screen?.terminalDelegate = nil; self.delegate = nil
        self.screen = nil; self.snapshot = Data(); self.hasOutput = false
    }
}

/// Only the host is disposable; the original terminal screen belongs to its Bootstrap task.
struct BootstrapTerminalContainer: NSViewRepresentable {
    let model: TaskCoordinator
    let record: TaskRecord
    var visible = true
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ host: NSView, context: Context) {
        let terminal = self.model.bootstrapTerminal(for: self.record).view()
        if terminal.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            terminal.removeFromSuperview(); host.addSubview(terminal)
            terminal.autoresizingMask = [.width, .height]
        }
        let session = self.model.bootstrapTerminal(for: self.record)
        // Resolve dynamic AppKit colors after reparenting, including theme changes on a retained screen.
        terminal.effectiveAppearance.performAsCurrentDrawingAppearance { terminal.configureNativeColors() }
        session.setInputEnabled(false)
        terminal.frame = host.bounds; terminal.isHidden = !self.visible
        session.setInputEnabled(self.visible && self.record.status == .running)
        if self.visible, self.record.status == .running, host.bounds.width > 0, host.bounds.height > 0 {
            self.model.resize(id: self.record.id, columns: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
        }
        if !self.visible, host.window?.firstResponder === terminal { host.window?.makeFirstResponder(nil) }
    }
}
