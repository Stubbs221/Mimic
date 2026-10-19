//
//  NativeRetroWindows.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import Observation
import SwiftUI
import MimicCore

// MARK: - Retained window decoration

@MainActor private protocol NativeRetroHostSizing {
    func suspendWindowSizing() -> () -> Void
}
extension NSHostingView: NativeRetroHostSizing {
    fileprivate func suspendWindowSizing() -> () -> Void {
        let original = sizingOptions; sizingOptions = []
        return { [weak self] in self?.sizingOptions = original }
    }
}

extension View {
    func mimicWindowChrome() -> some View { background(NativeRetroWindowMarker()) }
    func mimicRetroScrollbars() -> some View { background(NativeRetroScrollMarker()) }
    func mimicRetroHeading() -> some View { modifier(NativeRetroHeading()) }
    /// Explicit system fonts keep their original choice outside R1.
    func mimicRetrofittedFont(_ original: Font, role: MimicFontRole = .body, bold: Bool = false) -> some View {
        modifier(NativeRetroFont(original: original, role: role, bold: bold))
    }
}

private struct NativeRetroHeading: ViewModifier {
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var scale
    func body(content: Content) -> some View {
        if theme.retro {
            content.foregroundStyle(Color.white).frame(minHeight: NativeRetro.titleHeight(theme.appearance) * scale)
                .background(NativeRetroArtwork(appearance: theme.appearance, kind: .title))
        } else { content }
    }
}

private struct NativeRetroScrollMarker: NSViewRepresentable {
    @Environment(\.mimicPanelAppearance) private var choice
    func makeNSView(context: Context) -> NativeRetroScrollDecoration { NativeRetroScrollDecoration() }
    func updateNSView(_ view: NativeRetroScrollDecoration, context: Context) { view.choice = choice; view.apply(); DispatchQueue.main.async { [weak view] in view?.apply() } }
    static func dismantleNSView(_ view: NativeRetroScrollDecoration, coordinator: ()) { view.restore() }
}

@MainActor private final class NativeRetroScrollDecoration: NSView {
    var choice = PanelAppearance.legacy
    private var rails: [NativeRetroScrollbar] = []
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); apply() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    func restore() { rails.forEach { $0.removeFromSuperview() }; rails = [] }
    func apply() {
        guard choice.isRetro else { restore(); return }
        guard let root = window?.contentView, !bounds.isEmpty else { return }
        let area = convert(bounds, to: root)
        func discover(_ view: NSView) {
            if let scroll = view as? NSScrollView, area.insetBy(dx: -1, dy: -1).contains(scroll.convert(scroll.bounds, to: root)), !scroll.subviews.contains(where: { $0 is NativeRetroScrollbar }), !rails.contains(where: { $0.scroll === scroll }) {
                let rail = NativeRetroScrollbar(scroll: scroll); scroll.addSubview(rail); rails.append(rail)
            }
            for child in view.subviews where !(child is NativeRetroScrollbar) { discover(child) }
        }
        discover(root)
        rails.forEach { $0.appearanceChoice = choice; $0.refresh() }
    }
}

private struct NativeRetroFont: ViewModifier {
    let original: Font
    let role: MimicFontRole
    let bold: Bool
    @Environment(\.mimicPanelAppearance) private var choice
    @Environment(\.mimicTextScale) private var scale
    func body(content: Content) -> some View {
        content.font(choice.isRetro ? Font(NativeRetro.font(choice, role: role, bold: bold, scale: scale)) : original)
    }
}

private struct NativeRetroWindowMarker: NSViewRepresentable {
    @Environment(\.mimicPanelAppearance) private var choice
    @Environment(\.mimicTextScale) private var scale
    func makeNSView(context: Context) -> NativeRetroWindowAnchor { NativeRetroWindowAnchor() }
    func updateNSView(_ view: NativeRetroWindowAnchor, context: Context) { view.choice = choice; view.scale = scale; view.synchronize() }
    static func dismantleNSView(_ view: NativeRetroWindowAnchor, coordinator: ()) { }
}

@MainActor private final class NativeRetroWindowAnchor: NSView {
    var choice = PanelAppearance.legacy
    var scale: CGFloat = 1
    var adapter: NativeRetroWindowAdapter?
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronize() }
    func synchronize() {
        guard adapter?.updating != true, let window else { return }
        if adapter?.window !== window { adapter = NativeRetroWindowAdapter.retained(for: window) }
        adapter?.apply(choice: choice, scale: scale)
    }
}

/// Reparents the same content view rather than rebuilding a form, editor or web authentication session.
/// The anchor owns the adapter; weak window/content references avoid a cycle through the retained graph.
@MainActor final class NativeRetroWindowAdapter {
    /// Window ownership survives replacement of a setup session's hosting root.
    private static let adapters = NSMapTable<NSWindow, NativeRetroWindowAdapter>.weakToStrongObjects()
    static func retained(for window: NSWindow) -> NativeRetroWindowAdapter {
        if let adapter = adapters.object(forKey: window) { return adapter }
        let adapter = NativeRetroWindowAdapter(window: window); adapters.setObject(adapter, forKey: window); return adapter
    }
    private struct Original {
        let mask: NSWindow.StyleMask
        let titleVisibility: NSWindow.TitleVisibility
        let transparent: Bool
        let background: NSColor
        let opaque: Bool
        let translates: Bool
        let autoresizing: NSView.AutoresizingMask
        let buttons: [(NSButton, Bool)]
        let restoreSizing: (() -> Void)?
    }
    weak var window: NSWindow?
    private weak var originalContent: NSView?
    private weak var chrome: NativeRetroWindowChrome?
    private var original: Original?
    private var observations: [NSObjectProtocol] = []
    private var composition: Timer?
    private var pending: (PanelAppearance, CGFloat)?
    private var store: PanelAppearanceStore?
    private(set) var updating = false
    init(window: NSWindow, store: PanelAppearanceStore? = nil) {
        self.window = window; self.store = store
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didResizeNotification, NSWindow.didDeminiaturizeNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.chrome?.refresh() }
            })
        }
        if store != nil { observe() }
    }
    isolated deinit { composition?.invalidate(); observations.forEach(NotificationCenter.default.removeObserver) }
    private func observe() {
        guard let store else { return }
        let choice = withObservationTracking { store.selection } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
        apply(choice: choice, scale: 1)
    }
    func apply(choice: PanelAppearance, scale: CGFloat) {
        guard !updating, let window else { return }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() {
            pending = (choice, scale)
            if composition == nil {
                composition = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak editor] _ in
                    MainActor.assumeIsolated {
                        guard let self, editor?.hasMarkedText() != true else { return }
                        self.composition?.invalidate(); self.composition = nil
                        if let pending = self.pending { self.pending = nil; self.apply(choice: pending.0, scale: pending.1) }
                    }
                }
            }
            return
        }
        guard choice.isRetro else { restore(); return }
        if let chrome, window.contentView === chrome, chrome.choice == choice, chrome.scale == scale { return }
        updating = true; defer { updating = false }
        let responder = window.firstResponder
        if (chrome == nil || window.contentView !== chrome), let content = window.contentView {
            let retainedFrame = window.frame
            let previous = original
            previous?.restoreSizing?()
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }.map { ($0, $0.isHidden) }
            original = Original(mask: previous?.mask ?? window.styleMask, titleVisibility: previous?.titleVisibility ?? window.titleVisibility, transparent: previous?.transparent ?? window.titlebarAppearsTransparent,
                                background: previous?.background ?? window.backgroundColor, opaque: previous?.opaque ?? window.isOpaque, translates: content.translatesAutoresizingMaskIntoConstraints,
                                autoresizing: content.autoresizingMask, buttons: previous?.buttons ?? buttons, restoreSizing: (content as? NativeRetroHostSizing)?.suspendWindowSizing())
            originalContent = content
            let root = NativeRetroWindowChrome(content: content)
            root.owner = window
            root.autoresizingMask = [.width, .height]
            window.styleMask.insert(.fullSizeContentView); window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.contentView = root; chrome = root
            window.setFrame(retainedFrame, display: false)
            root.frame = CGRect(origin: .zero, size: retainedFrame.size)
            buttons.forEach { $0.0.isHidden = true }
            window.backgroundColor = NativeRetro.color("surface", appearance: choice); window.isOpaque = true
        }
        chrome?.choice = choice; chrome?.scale = scale; chrome?.refresh()
        if let responder, window.firstResponder !== responder { window.makeFirstResponder(responder) }
    }
    func restore() {
        guard !updating, let window, let original else { return }
        updating = true; defer { updating = false }
        let responder = window.firstResponder
        if let content = originalContent, let chrome, window.contentView === chrome {
            window.contentView = content
            content.translatesAutoresizingMaskIntoConstraints = original.translates; content.autoresizingMask = original.autoresizing
        }
        window.styleMask = original.mask; window.titleVisibility = original.titleVisibility; window.titlebarAppearsTransparent = original.transparent
        window.backgroundColor = original.background; window.isOpaque = original.opaque
        original.buttons.forEach { $0.0.isHidden = $0.1 }
        original.restoreSizing?()
        self.original = nil; chrome = nil
        if let responder, window.firstResponder !== responder { window.makeFirstResponder(responder) }
    }
}

@MainActor private final class NativeRetroWindowChrome: NSView {
    let content: NSView
    weak var owner: NSWindow?
    var choice = PanelAppearance.windows95
    var scale: CGFloat = 1
    private let artwork = NativeRetroArtwork.ArtworkView()
    private let title = NativeRetroWindowTitle()
    init(content: NSView) {
        self.content = content; super.init(frame: content.frame)
        artwork.kind = .frame; addSubview(artwork); addSubview(content); addSubview(title)
        content.translatesAutoresizingMaskIntoConstraints = true; content.autoresizingMask = []
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        artwork.appearanceChoice = choice; artwork.needsDisplay = true
        title.choice = choice; title.scale = scale; title.owner = owner; title.refresh()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let h = NativeRetro.titleHeight(choice) * scale
        let contentFrame = CGRect(x: 3, y: 3, width: max(0, bounds.width - 6), height: max(0, bounds.height - h - 6))
        if content.frame != contentFrame { content.frame = contentFrame }
        artwork.frame = bounds; title.frame = CGRect(x: 3, y: bounds.height - h - 3, width: max(0, bounds.width - 6), height: h)
    }
}

@MainActor private final class NativeRetroWindowTitle: NSView {
    weak var owner: NSWindow?
    var choice = PanelAppearance.windows95
    var scale: CGFloat = 1
    private let artwork = NativeRetroArtwork.ArtworkView()
    private let label = NSTextField(labelWithString: "")
    private var captions: [NativeRetroWindowCaption] = []
    override init(frame: NSRect) {
        super.init(frame: frame); artwork.kind = .title; addSubview(artwork)
        label.lineBreakMode = .byTruncatingTail; label.setAccessibilityElement(false); addSubview(label)
        for operation in [NSWindow.ButtonType.miniaturizeButton, .zoomButton, .closeButton] {
            let caption = NativeRetroWindowCaption(); caption.operation = operation
            caption.actionBlock = { [weak self] in
                guard let window = self?.owner, window.isVisible, window.standardWindowButton(operation)?.isEnabled == true else { return }
                switch operation { case .closeButton: window.performClose(nil); case .miniaturizeButton: window.performMiniaturize(nil); case .zoomButton: window.performZoom(nil); default: break }
            }
            captions.append(caption); addSubview(caption)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) { owner?.performDrag(with: event) }
    func refresh() {
        artwork.appearanceChoice = choice; artwork.alphaValue = owner?.isKeyWindow == true ? 1 : 0.6; artwork.needsDisplay = true
        label.stringValue = owner?.title ?? ""; label.font = NativeRetro.font(choice, role: .heading, bold: true, scale: scale); label.textColor = .white
        for caption in captions {
            let native = owner?.standardWindowButton(caption.operation)
            let mask = owner?.styleMask ?? []
            let supported = caption.operation == .closeButton ? mask.contains(.closable) : caption.operation == .miniaturizeButton ? mask.contains(.miniaturizable) : mask.contains(.resizable)
            caption.isHidden = !supported || native == nil; caption.isEnabled = native?.isEnabled == true; caption.appearanceChoice = choice
            caption.zoomed = owner?.isZoomed == true
            // AX semantics must exist before the first paint, including after zoom/restore.
            caption.setAccessibilityLabel(caption.operation == .closeButton ? text("panel.chrome.close") : caption.operation == .zoomButton ? text(caption.zoomed ? "window.restore" : "window.maximize") : text("window.minimize"))
        }
        needsLayout = true
    }
    override func layout() {
        super.layout(); artwork.frame = bounds
        let size = CGSize(width: choice == .windowsXP ? 21 : 16, height: choice == .windowsXP ? 21 : 14)
        var right = bounds.width - 3
        for caption in captions.reversed() where !caption.isHidden { right -= size.width; caption.frame = CGRect(x: right, y: (bounds.height - size.height) / 2, width: size.width, height: size.height); right -= 2 }
        label.frame = CGRect(x: 5, y: (bounds.height - 18 * scale) / 2, width: max(0, right - 9), height: 18 * scale)
    }
}

@MainActor private final class NativeRetroWindowCaption: NativeRetroControl {
    var operation = NSWindow.ButtonType.closeButton
    var zoomed = false
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && event.isARepeat { return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        let art = NativeRetroArtwork.ArtworkView(frame: bounds); art.appearanceChoice = appearanceChoice
        art.kind = .caption(operation == .closeButton ? "close" : operation == .zoomButton ? (zoomed ? "restore" : "maximize") : "minimize")
        art.pressed = pressed; art.enabled = isEnabled; art.draw(dirtyRect)
        if operation == .miniaturizeButton {
            (isEnabled ? NSColor.black : NativeRetro.color("muted", appearance: appearanceChoice)).setFill()
            CGRect(x: 4, y: bounds.height - 5, width: max(0, bounds.width - 8), height: 2).fill()
        }
        super.draw(dirtyRect)
    }
}
