//
//  NativeRetroForms.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import MimicCore

// MARK: - Retained native editors

extension View {
    /// Decorates the existing editor; bindings, delegates, undo and secure-entry behavior stay native.
    func mimicInput() -> some View { modifier(NativeRetroInput()) }
}

private struct NativeRetroInput: ViewModifier {
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var scale
    func body(content: Content) -> some View {
        content.padding(.horizontal, theme.retro ? 6 * scale : 0).padding(.vertical, theme.retro ? 3 * scale : 0)
            .frame(minHeight: theme.retro ? 23 * scale : nil)
            .background(theme.retro ? Color.white : Color.clear)
            .overlay(NativeRetroEditorMarker(appearance: theme.appearance, scale: scale))
            .overlay(NativeRetroArtwork(appearance: theme.appearance, kind: .inputBorder))
    }
}

/// A geometric marker finds only its own native editor, including SwiftUI's multiline NSTextView.
/// No private SwiftUI classes, replacement cell, delegate or second hosting graph are used.
private struct NativeRetroEditorMarker: NSViewRepresentable {
    let appearance: PanelAppearance
    let scale: CGFloat
    func makeNSView(context: Context) -> NativeRetroEditorDecoration { NativeRetroEditorDecoration() }
    func updateNSView(_ view: NativeRetroEditorDecoration, context: Context) {
        view.choice = appearance; view.scale = scale
        view.apply()
        DispatchQueue.main.async { [weak view] in view?.apply() }
    }
    static func dismantleNSView(_ view: NativeRetroEditorDecoration, coordinator: ()) { view.restore() }
}

@MainActor final class NativeRetroEditorDecoration: NSView {
    var choice = PanelAppearance.legacy
    var scale: CGFloat = 1
    private weak var editor: NSView?
    private var restoration: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    override func layout() { super.layout(); apply() }
    func restore() { restoration?(); restoration = nil; editor = nil }
    func apply() {
        guard choice.isRetro else { restore(); return }
        guard let root = window?.contentView, bounds.width > 0, bounds.height > 0 else { return }
        let area = convert(bounds, to: root)
        func candidates(_ view: NSView) -> [NSView] {
            if view !== self, !view.isHidden, (view is NSTextField && (view as? NSTextField)?.isEditable == true || view is NSTextView && (view as? NSTextView)?.isEditable == true && (view as? NSTextView)?.isFieldEditor == false) {
                let rect = view.convert(view.bounds, to: root)
                if area.contains(CGPoint(x: rect.midX, y: rect.midY)), rect.intersects(area) { return [view] }
            }
            return view.subviews.flatMap(candidates)
        }
        guard let target = candidates(root).min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return }
        if let field = target as? NSTextField, (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        if let text = target as? NSTextView, text.hasMarkedText() { return }
        if editor !== target {
            restore(); editor = target
            if let field = target as? NSTextField {
                let bezel = field.isBezeled, border = field.isBordered, background = field.drawsBackground
                let color = field.backgroundColor, ink = field.textColor, font = field.font, focus = field.focusRingType
                restoration = { [weak field] in
                    guard let field else { return }
                    field.isBezeled = bezel; field.isBordered = border; field.drawsBackground = background
                    field.backgroundColor = color; field.textColor = ink; field.font = font; field.focusRingType = focus
                }
            } else if let text = target as? NSTextView {
                let background = text.backgroundColor, ink = text.textColor, insertion = text.insertionPointColor, font = text.font
                restoration = { [weak text] in
                    guard let text else { return }
                    text.backgroundColor = background; text.textColor = ink; text.insertionPointColor = insertion; text.font = font
                }
            }
        }
        let font = NativeRetro.font(choice, scale: scale)
        if let field = target as? NSTextField {
            if field.isBezeled { field.isBezeled = false }
            if field.isBordered { field.isBordered = false }
            if field.backgroundColor != .white { field.backgroundColor = .white }
            if field.textColor != .black { field.textColor = .black }
            if field.font != font { field.font = font }
            if field.focusRingType != .none { field.focusRingType = .none }
        } else if let text = target as? NSTextView {
            if text.backgroundColor != .white { text.backgroundColor = .white }
            if text.textColor != .black { text.textColor = .black }
            if text.insertionPointColor != .black { text.insertionPointColor = .black }
            if text.font != font { text.font = font }
        }
    }
}

// MARK: - Checkbox activation

/// Non-retro controls retain their original style. R1 shares the proven native press transaction.
struct MimicCheckboxStyle: ToggleStyle {
    var originalSwitch = false
    var hidesLabel = false
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var scale
    @Environment(\.isEnabled) private var enabled
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if theme.retro {
            HStack(spacing: 5 * scale) {
                Color.clear.frame(width: 13 * scale, height: 20 * scale)
                if !hidesLabel {
                    configuration.label.font(Font(NativeRetro.font(theme.appearance, scale: scale)))
                        .foregroundStyle(Color(nsColor: NativeRetro.color(enabled ? "ink" : "muted", appearance: theme.appearance)))
                }
            }.overlay(NativeRetroCheckbox(value: configuration.$isOn, appearance: theme.appearance, scale: scale))
                .accessibilityElement(children: .combine)
        } else if originalSwitch { Toggle(configuration).toggleStyle(.switch) }
        else { Toggle(configuration).toggleStyle(.checkbox) }
    }
}

private struct NativeRetroCheckbox: NSViewRepresentable {
    @Binding var value: Bool
    let appearance: PanelAppearance
    let scale: CGFloat
    func makeNSView(context: Context) -> NativeRetroCheckboxControl { NativeRetroCheckboxControl() }
    func updateNSView(_ view: NativeRetroCheckboxControl, context: Context) {
        view.actionBlock = { value.toggle() }
        if view.appearanceChoice != appearance { view.appearanceChoice = appearance }
        if view.isEnabled != context.environment.isEnabled { view.isEnabled = context.environment.isEnabled }
        if view.checked != value { view.checked = value }
        view.scale = scale
    }
}

/// Accessibility exposes a check box and its value, rather than an unrelated push button.
@MainActor final class NativeRetroCheckboxControl: NativeRetroControl {
    var checked = false { didSet { setAccessibilityValue(checked ? 1 : 0); needsDisplay = true } }
    var scale: CGFloat = 1
    private let artwork = NativeRetroArtwork.ArtworkView()
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityRole(.checkBox); setAccessibilityValue(0) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let box = CGRect(x: 0, y: (bounds.height - 13 * scale) / 2, width: 13 * scale, height: 13 * scale)
        artwork.frame = box; artwork.appearanceChoice = appearanceChoice; artwork.kind = .checkbox(checked)
        artwork.pressed = pressed; artwork.enabled = isEnabled
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by: box.minX, yBy: box.minY); transform.concat()
        artwork.draw(artwork.bounds)
        NSGraphicsContext.restoreGraphicsState()
        super.draw(dirtyRect)
    }
    override func accessibilityValue() -> Any? { NSNumber(value: checked) }
}

// MARK: - Typed selection, without editable input

struct MimicSelectionOption<Value: Hashable> {
    let title: String
    let value: Value
    init(_ title: String, _ value: Value) { self.title = title; self.value = value }
}

/// Segments are explicit selections, with the original Picker retained for both older themes.
struct MimicSegments<Value: Hashable, Original: View>: View {
    @Binding var selection: Value
    let options: [MimicSelectionOption<Value>]
    let original: Original
    private var theme = MimicTheme()
    @FocusState private var focused: Value?
    init(selection: Binding<Value>, options: [MimicSelectionOption<Value>], @ViewBuilder original: () -> Original) {
        _selection = selection; self.options = options; self.original = original()
    }
    var body: some View {
        ZStack {
            original.opacity(theme.retro ? 0 : 1).allowsHitTesting(!theme.retro).disabled(theme.retro).accessibilityHidden(theme.retro)
            if theme.retro {
                HStack(spacing: 1) {
                    ForEach(options, id: \.value) { option in
                        Button(option.title) { if selection != option.value { selection = option.value } }
                            .buttonStyle(NativeRetroPrimitiveButtonStyle(selected: selection == option.value))
                            .focused($focused, equals: option.value)
                            .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                    }
                }.onMoveCommand { direction in
                    guard !options.isEmpty, direction == .left || direction == .right else { return }
                    let current = options.firstIndex { $0.value == selection } ?? 0
                    let index = (current + (direction == .right ? 1 : options.count - 1)) % options.count
                    selection = options[index].value; focused = selection
                }
            }
        }.accessibilityElement(children: .contain)
    }
}

extension View {
    func mimicSegments<Value: Hashable>(selection: Binding<Value>, options: [MimicSelectionOption<Value>]) -> some View {
        MimicSegments(selection: selection, options: options) { self }
    }
}

extension View {
    /// Explicit options keep the legacy Picker and its model tags intact beneath R1 presentation.
    func mimicSelection<Value: Hashable>(_ title: String, selection: Binding<Value>, options: [MimicSelectionOption<Value>], labelsHidden: Bool = false) -> some View {
        MimicSelection(title, selection: selection, options: options, labelsHidden: labelsHidden) { self }
    }
}

/// The original Picker stays mounted for Tile Grid/legacy. No reflection of SwiftUI tags is needed.
struct MimicSelection<Value: Hashable, Original: View>: View {
    let title: String
    @Binding var selection: Value
    let options: [MimicSelectionOption<Value>]
    let labelsHidden: Bool
    let original: Original
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var scale
    init(_ title: String, selection: Binding<Value>, options: [MimicSelectionOption<Value>], labelsHidden: Bool = false, @ViewBuilder original: () -> Original) {
        self.title = title; self._selection = selection; self.options = options; self.labelsHidden = labelsHidden; self.original = original()
    }
    var body: some View {
        ZStack {
            original.opacity(theme.retro ? 0 : 1).allowsHitTesting(!theme.retro).disabled(theme.retro)
                .background(NativeRetroOriginalPickerMarker(retro: theme.retro))
                .accessibilityHidden(theme.retro)
                if theme.retro {
                    HStack(spacing: 8) {
                        if !labelsHidden { Text(title).font(Font(NativeRetro.font(theme.appearance, scale: scale))) }
                        NativeRetroSelectionView(titles: options.map(\.title), identities: options.map { AnyHashable($0.value) }, selected: options.firstIndex { $0.value == selection },
                                                 appearance: theme.appearance, scale: scale, label: title,
                                                 commit: { index in guard options.indices.contains(index) else { return }; selection = options[index].value })
                            .mimicNativeControlHelp(options.first(where: { $0.value == selection })?.title ?? "")
                    }
                }
        }
        .frame(minHeight: theme.retro ? 23 * scale : nil)
        .accessibilityElement(children: .contain)
    }
}

/// Opacity keeps the Picker mounted but does not hide its AppKit accessibility element.
/// Hide only the original native control; restore its exact visibility when leaving R1.
private struct NativeRetroOriginalPickerMarker: NSViewRepresentable {
    let retro: Bool
    func makeNSView(context: Context) -> NativeRetroOriginalPickerVisibility { NativeRetroOriginalPickerVisibility() }
    func updateNSView(_ view: NativeRetroOriginalPickerVisibility, context: Context) {
        view.retro = retro; view.apply()
        DispatchQueue.main.async { [weak view] in view?.apply() }
    }
    static func dismantleNSView(_ view: NativeRetroOriginalPickerVisibility, coordinator: ()) { view.restore() }
}
@MainActor final class NativeRetroOriginalPickerVisibility: NSView {
    private final class Original { weak var control: NSControl?; let hidden: Bool; init(_ control: NSControl) { self.control = control; hidden = control.isHidden } }
    var retro = false
    private var originals: [Original] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    override func layout() { super.layout(); apply() }
    func restore() { for original in originals { if let control = original.control, control.isHidden != original.hidden { control.isHidden = original.hidden } }; originals = [] }
    func apply() {
        guard retro else { restore(); return }
        guard let root = window?.contentView, bounds.width > 0, bounds.height > 0 else { return }
        let area = convert(bounds, to: root)
        func discover(_ view: NSView) {
            if let control = view as? NSControl, !(control is NativeRetroControl), !control.isHiddenOrHasHiddenAncestor {
                let rect = control.convert(control.bounds, to: root)
                if area.contains(CGPoint(x: rect.midX, y: rect.midY)), rect.intersects(area), !originals.contains(where: { $0.control === control }) { originals.append(Original(control)) }
            }
            for child in view.subviews { discover(child) }
        }
        discover(root)
        for original in originals { if let control = original.control, !control.isHidden { control.isHidden = true } }
    }
}

private struct NativeRetroSelectionView: NSViewRepresentable {
    let titles: [String]
    let identities: [AnyHashable]
    let selected: Int?
    let appearance: PanelAppearance
    let scale: CGFloat
    let label: String
    let commit: (Int) -> Void
    func makeNSView(context: Context) -> NativeRetroSelectionControl { NativeRetroSelectionControl() }
    func updateNSView(_ view: NativeRetroSelectionControl, context: Context) {
        if view.titles != titles { view.closePopup(); view.titles = titles }
        view.optionIdentities = identities
        if view.appearanceChoice != appearance { view.closePopup(); view.appearanceChoice = appearance }
        if view.isEnabled != context.environment.isEnabled { view.isEnabled = context.environment.isEnabled; if !view.isEnabled { view.closePopup() } }
        if view.selectedIndex != selected || view.scale != scale { view.closePopup() }
        view.selectedIndex = selected; view.scale = scale; view.commit = commit
        view.setAccessibilityLabel(label); view.setAccessibilityValue(selected.flatMap { titles.indices.contains($0) ? titles[$0] : nil })
        view.setAccessibilityHelp(selected.flatMap { titles.indices.contains($0) ? titles[$0] : nil })
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: NativeRetroSelectionControl, coordinator: ()) { view.closePopup() }
}

/// Highlighting is provisional: arrows/typeahead never write the binding; only confirmation commits.
@MainActor final class NativeRetroSelectionControl: NativeRetroControl {
    var titles: [String] = []
    /// Equal display names may belong to different devices; identity changes invalidate the popup too.
    var optionIdentities: [AnyHashable] = [] { didSet { if optionIdentities != oldValue { closePopup() } } }
    var selectedIndex: Int?
    private(set) var highlightedIndex: Int?
    var scale: CGFloat = 1
    var commit: (Int) -> Void = { _ in }
    private(set) var popup: NSPanel?
    private var rows: [NativeRetroSelectionRow] = []
    private var scroll: NSScrollView?
    private var monitor: Any?
    private var blur: NSObjectProtocol?
    private var query = ""
    private var queryTime: TimeInterval = 0
    private var spaceConfirmation = false
    override init(frame: NSRect) {
        super.init(frame: frame); setAccessibilityRole(.popUpButton)
        actionBlock = { [weak self] in self?.openPopup(keyboard: false) }
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let blur { NotificationCenter.default.removeObserver(blur) }
    }
    override func viewDidMoveToWindow() { closePopup(); super.viewDidMoveToWindow() }
    override func viewDidHide() { closePopup(); super.viewDidHide() }
    override func resignFirstResponder() -> Bool { closePopup(); return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
        let artwork = NativeRetroArtwork.ArtworkView(frame: bounds)
        artwork.appearanceChoice = appearanceChoice; artwork.enabled = isEnabled; artwork.kind = .input; artwork.draw(bounds)
        let arrow = CGRect(x: max(0, bounds.width - 18 * scale), y: 1, width: 17 * scale, height: max(0, bounds.height - 2))
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by: arrow.minX, yBy: arrow.minY); transform.concat()
        artwork.frame = CGRect(origin: .zero, size: arrow.size); artwork.kind = .button; artwork.pressed = pressed || popup != nil; artwork.draw(artwork.bounds)
        (isEnabled ? NSColor.black : NativeRetro.rgb(0x6d6d6d)).setFill(); let triangle = NSBezierPath(); triangle.move(to: .init(x: arrow.width / 2 - 3, y: arrow.height / 2 - 1)); triangle.line(to: .init(x: arrow.width / 2 + 3, y: arrow.height / 2 - 1)); triangle.line(to: .init(x: arrow.width / 2, y: arrow.height / 2 + 3)); triangle.close(); triangle.fill()
        NSGraphicsContext.restoreGraphicsState()
        if let selectedIndex, titles.indices.contains(selectedIndex) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (titles[selectedIndex] as NSString).draw(in: CGRect(x: 6, y: max(3, (bounds.height - 14 * scale) / 2), width: max(0, arrow.minX - 10), height: 16 * scale),
                withAttributes: [.font: NativeRetro.font(appearanceChoice, scale: scale), .foregroundColor: isEnabled ? NSColor.black : NativeRetro.rgb(0x6d6d6d), .paragraphStyle: paragraph])
        }
        super.draw(dirtyRect)
    }
    func openPopup(keyboard: Bool) {
        guard isEnabled, popup == nil, !titles.isEmpty, let window, !isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(self); highlightedIndex = selectedIndex ?? 0; query = ""
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let available = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor.insetBy(dx: -400, dy: -400)
        let rowHeight = 23 * scale
        let width = min(max(bounds.width, 120), available.width - 8)
        let height = min(CGFloat(titles.count) * rowHeight + 2, min(280 * scale, available.height - 8))
        var frame = CGRect(x: min(max(anchor.minX, available.minX + 4), available.maxX - width - 4), y: anchor.minY - height, width: width, height: height)
        if frame.minY < available.minY + 4 { frame.origin.y = min(anchor.maxY, available.maxY - height - 4) }
        frame.origin.y = min(max(frame.minY, available.minY + 4), available.maxY - height - 4)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .popUpMenu; panel.hasShadow = true
        panel.backgroundColor = NativeRetro.color("inputLine", appearance: appearanceChoice)
        let container = NativeRetroSelectionContainer(frame: CGRect(origin: .zero, size: frame.size))
        container.borderColor = NativeRetro.color("inputLine", appearance: appearanceChoice)
        let scroll = NSScrollView(frame: container.bounds.insetBy(dx: 1, dy: 1)); scroll.drawsBackground = true; scroll.backgroundColor = .white
        let document = NativeRetroSelectionDocument(frame: CGRect(x: 0, y: 0, width: scroll.bounds.width, height: CGFloat(titles.count) * rowHeight))
        document.setAccessibilityElement(false)
        rows = titles.enumerated().map { index, title in
            let row = NativeRetroSelectionRow(frame: CGRect(x: 0, y: CGFloat(index) * rowHeight, width: document.bounds.width - (CGFloat(titles.count) * rowHeight > height ? 17 : 0), height: rowHeight))
            row.title = title; row.font = NativeRetro.font(appearanceChoice, scale: scale)
            row.selectionHighlighted = index == highlightedIndex; row.target = self; row.action = #selector(chooseRow(_:)); row.tag = index
            row.hover = { [weak self] in self?.highlight(index) }
            document.addSubview(row); return row
        }
        scroll.documentView = document; container.addSubview(scroll)
        let rail = NativeRetroScrollbar(scroll: scroll); rail.appearanceChoice = appearanceChoice; rail.interactionWindow = window; scroll.addSubview(rail); rail.refresh()
        panel.contentView = container; self.scroll = scroll; popup = panel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.window === self.window {
                if self.handlePopupKey(event) { return nil }
            } else if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window !== self.popup { self.closePopup() }
            } else if event.type == .scrollWheel, event.window !== self.popup { self.closePopup() }
            return event
        }
        blur = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.closePopup() } }
        window.addChildWindow(panel, ordered: .above); panel.orderFront(nil)
        if appearanceChoice == .windowsXP, !keyboard, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0; NSAnimationContext.runAnimationGroup { context in context.duration = 0.15; context.timingFunction = CAMediaTimingFunction(name: .linear); panel.animator().alphaValue = 1 }
        }
        highlight(highlightedIndex ?? 0); needsDisplay = true
    }
    @objc private func chooseRow(_ sender: NSButton) { if rows.contains(where: { $0 === sender }) { confirm(sender.tag) } }
    func confirm(_ index: Int) {
        guard popup != nil, isEnabled, titles.indices.contains(index) else { return }
        closePopup(); commit(index)
    }
    func highlight(_ index: Int) {
        guard titles.indices.contains(index) else { return }
        highlightedIndex = index
        for row in rows { row.selectionHighlighted = row.tag == index }
        scroll?.documentView?.scrollToVisible(rows[index].frame)
    }
    func closePopup() {
        spaceConfirmation = false; cancelPress()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let blur { NotificationCenter.default.removeObserver(blur); self.blur = nil }
        if let popup { window?.removeChildWindow(popup); popup.orderOut(nil); popup.close() }
        popup = nil; rows = []; scroll = nil; highlightedIndex = nil; needsDisplay = true
    }
    @discardableResult func handlePopupKey(_ event: NSEvent) -> Bool {
        guard popup != nil else { return false }
        switch event.keyCode {
        case 53: closePopup()
        case 36, 76: if let highlightedIndex { confirm(highlightedIndex) }
        case 49: if !event.isARepeat { spaceConfirmation = true; beginPress() }
        case 125: highlight(min(titles.count - 1, (highlightedIndex ?? -1) + 1))
        case 126: highlight(max(0, (highlightedIndex ?? 1) - 1))
        case 115: highlight(0)
        case 119: highlight(titles.count - 1)
        case 48: closePopup(); return false
        default:
            guard !event.modifierFlags.contains(.command), let characters = event.characters, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            query = now - queryTime > 1 ? characters : query + characters; queryTime = now
            if let index = titles.firstIndex(where: { $0.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }) { highlight(index) }
        }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if handlePopupKey(event) { return }
        if [36, 76, 125, 126].contains(event.keyCode) { openPopup(keyboard: true) }
        else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceConfirmation, let highlightedIndex { confirm(highlightedIndex) }
        else if event.keyCode == 49, popup == nil, pressed { cancelPress(); openPopup(keyboard: true) }
        else { super.keyUp(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; openPopup(keyboard: true); return true }
    override func accessibilityValue() -> Any? { selectedIndex.flatMap { titles.indices.contains($0) ? titles[$0] : nil } }
}

private final class NativeRetroSelectionContainer: NSView {
    var borderColor = NSColor.black
    override func draw(_ dirtyRect: NSRect) { borderColor.setFill(); bounds.fill() }
}
private final class NativeRetroSelectionDocument: NSView { override var isFlipped: Bool { true } }
private final class NativeRetroSelectionRow: NSButton {
    var selectionHighlighted = false { didSet { needsDisplay = true; setAccessibilitySelected(selectionHighlighted) } }
    var hover: () -> Void = {}
    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); isBordered = false; setAccessibilityRole(.menuItem) }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover() }
    override func draw(_ dirtyRect: NSRect) {
        (selectionHighlighted ? NativeRetro.rgb(0x000080) : NSColor.white).setFill(); bounds.fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: bounds.insetBy(dx: 5, dy: 3), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: selectionHighlighted ? NSColor.white : NSColor.black, .paragraphStyle: paragraph])
    }
}
