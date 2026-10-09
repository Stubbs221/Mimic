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
    @Environment(\.mimicPanelAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    let model: TaskCoordinator
    let id: UUID
    func makeCoordinator() -> TerminalDelegate { TerminalDelegate(model: self.model, id: self.id) }
    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        configure(terminal)
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

    func updateNSView(_ view: TerminalView, context: Context) { configure(view); self.focusIfRequested(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalDelegate) {
        view.terminalDelegate = nil
        coordinator.model.detachTerminal(owner: coordinator.subscriptionID)
    }

    private func configure(_ view: TerminalView) {
        let tiled = appearance == .tileGrid
        BootstrapTerminalTheme.apply(to: view, dark: tiled || colorScheme == .dark, increasedContrast: false)
        view.nativeBackgroundColor = tiled ? MimicTheme.native("terminal", dark: colorScheme == .dark) : .textBackgroundColor
        view.nativeForegroundColor = tiled ? MimicTheme.native("terminalText", dark: colorScheme == .dark) : .textColor
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

/// Bootstrap-only colors keep retained screens and empty states on the same surface.
enum BootstrapTerminalTheme {
    static var background: NSColor { NSColor(name: nil) { appearance in
        Self.color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0x202833 : 0xF0F3F7)
    } }
    static var foreground: NSColor { NSColor(name: nil) { appearance in
        Self.color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0xDCE3ED : 0x263445)
    } }
    static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    @MainActor static func apply(to view: TerminalView, dark: Bool, increasedContrast: Bool) {
        view.nativeBackgroundColor = Self.color(dark ? 0x202833 : 0xF0F3F7)
        view.nativeForegroundColor = increasedContrast ? (dark ? .white : .black) : Self.color(dark ? 0xDCE3ED : 0x263445)
        view.caretColor = view.nativeForegroundColor
        view.selectedTextBackgroundColor = Self.color(dark ? 0x3D4C63 : 0xCCD8E8)
        view.selectedTextForegroundColor = view.nativeForegroundColor
        view.backgroundOpacity = 1
        let palette = dark
            ? [0x202833, 0xF08D91, 0x9EC89B, 0xE3C182, 0x91B5E0, 0xC9A4DA, 0x8ECACE, 0xDCE3ED,
               0xA6B3C5, 0xFFADB0, 0xB8DCAF, 0xF3D6A0, 0xB1CEF2, 0xDABCE8, 0xB1E1E3, 0xFFFFFF]
            : [0x263445, 0xA42D36, 0x386B3C, 0x795717, 0x355F96, 0x79438D, 0x286970, 0x546274,
               0x5C6879, 0xB2343F, 0x356C39, 0x7A5610, 0x315F9B, 0x814593, 0x216B72, 0x263445]
        view.installColors(palette.map { SwiftTerm.Color(red8: UInt16(($0 >> 16) & 255), green8: UInt16(($0 >> 8) & 255), blue8: UInt16($0 & 255)) })
    }
}

/// A bounded, task-owned screen survives hidden mini cards and completion. Never serialized.
@MainActor final class BootstrapTerminalSession: ObservableObject {
    private weak var model: TaskCoordinator?
    let id: UUID
    private let owner = UUID()
    private(set) var snapshot: Data
    @Published private(set) var hasOutput: Bool
    private var screen: TerminalView?
    private var delegate: TerminalDelegate?
    private var presentation: String?
    private var inputEnabled = false
    private var selected = false
    init(model: TaskCoordinator, record: TaskRecord, replay: Data? = nil) {
        self.model = model; self.id = record.id
        self.snapshot = Data((replay ?? model.replay(id: record.id)).suffix(128 * 1024)); self.hasOutput = !self.snapshot.isEmpty
        model.attachTerminal(owner: self.owner) { [weak self] task, bytes in
            guard let self, task == self.id else { return }
            if !self.hasOutput, !bytes.isEmpty { self.hasOutput = true }
            if self.model?.records.first(where: { $0.id == self.id })?.hasPrivateInput == true {
                self.snapshot = Data()
                if self.screen == nil { self.hasOutput = false }
            } else {
                self.snapshot.append(bytes); self.snapshot = Data(self.snapshot.suffix(128 * 1024))
            }
            self.screen?.feed(byteArray: Array(bytes)[...])
        }
    }
    isolated deinit { self.model?.detachTerminal(owner: self.owner) }

    func view() -> TerminalView {
        if let screen { return screen }
        let view = TerminalView(frame: .zero)
        BootstrapTerminalTheme.apply(to: view, dark: false, increasedContrast: false)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.getTerminal().changeScrollback(1500)
        view.setAccessibilityLabel(text("terminal"))
        if let model {
            let delegate = TerminalDelegate(model: model, id: self.id)
            self.delegate = delegate
        }
        view.feed(byteArray: Array(self.snapshot)[...]); self.screen = view
        return view
    }
    /// Updating the existing renderer never clears task output or its replay snapshot.
    func configure(fontSize: CGFloat, dark: Bool, increasedContrast: Bool, appearance: PanelAppearance = .legacy) {
        let view = self.view(), signature = "\(fontSize)-\(dark)-\(increasedContrast)-\(appearance)"
        guard self.presentation != signature else { return }
        self.presentation = signature
        if view.font.pointSize != fontSize { view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        BootstrapTerminalTheme.apply(to: view, dark: dark || appearance == .tileGrid, increasedContrast: increasedContrast)
        if appearance == .tileGrid {
            view.nativeBackgroundColor = MimicTheme.native("terminal", dark: dark)
            view.nativeForegroundColor = MimicTheme.native("terminalText", dark: dark)
            view.caretColor = view.nativeForegroundColor
        }
    }
    /// A mounted screen may keep its scrollback, but echoed input cannot become replay data.
    func discardReplayAfterPrivateInput() { self.snapshot = Data(); if self.screen == nil { self.hasOutput = false } }
    func setInputEnabled(_ enabled: Bool) {
        self.inputEnabled = enabled
        self.screen?.terminalDelegate = enabled && self.selected ? self.delegate : nil
    }
    func setSelected(_ selected: Bool) { self.selected = selected; self.setInputEnabled(self.inputEnabled) }
    func stop() {
        self.model?.detachTerminal(owner: self.owner)
        self.screen?.terminalDelegate = nil; self.delegate = nil
        self.screen = nil; self.presentation = nil; self.snapshot = Data(); self.hasOutput = false
    }
}

/// Only the host is disposable; the original terminal screen belongs to its Bootstrap task.
struct BootstrapTerminalContainer: NSViewRepresentable {
    let model: TaskCoordinator
    let record: TaskRecord
    var visible = true
    var fontSize: CGFloat = 12
    var session: BootstrapTerminalSession? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.mimicPanelAppearance) private var appearance
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ host: NSView, context: Context) {
        let session = self.session ?? self.model.bootstrapTerminal(for: self.record)
        let terminal = session.view()
        let previousRow = terminal.getTerminal().buffer.yDisp
        let followingOutput = !terminal.canScroll || terminal.scrollPosition >= 1
        if terminal.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            terminal.removeFromSuperview(); host.addSubview(terminal)
            terminal.autoresizingMask = [.width, .height]
        }
        session.configure(fontSize: self.fontSize, dark: self.colorScheme == .dark, increasedContrast: self.contrast == .increased, appearance: self.appearance)
        session.setInputEnabled(false)
        if self.visible { terminal.frame = host.bounds }
        terminal.isHidden = !self.visible
        if followingOutput { terminal.scrollTo(row: Int.max, notifyAccessibility: false) }
        else { terminal.scrollTo(row: previousRow, notifyAccessibility: false) }
        session.setInputEnabled(self.visible && self.record.status == .running)
        if self.visible, self.record.status == .running, host.bounds.width > 0, host.bounds.height > 0 {
            self.model.resize(id: self.record.id, columns: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
        }
        if !self.visible, host.window?.firstResponder === terminal { host.window?.makeFirstResponder(nil) }
    }
}
