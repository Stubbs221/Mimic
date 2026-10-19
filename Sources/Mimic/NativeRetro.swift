//
//  NativeRetro.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import MimicCore

// MARK: - Approved R1 artwork

/// Native R1 uses the same SVG artwork and pixel geometry as the accepted Web themes.
/// Fonts are resolved locally; these copyrighted fonts are never bundled with the app.
enum NativeRetro {
    static func rgb(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func color(_ key: String, appearance: PanelAppearance) -> NSColor {
        let xp = appearance == .windowsXP
        let value = switch key {
        case "ink": 0x000000
        case "muted": 0x6d6d6d
        case "line": xp ? 0xaca899 : 0x808080
        case "inputLine": xp ? 0x7f9db9 : 0x808080
        case "accent", "title": xp ? 0x0050ee : 0x000080
        case "accentSoft": xp ? 0xd5e2fa : 0xdfdfdf
        case "terminal": 0x000000
        case "terminalText": 0xc0c0c0
        case "onAccent": 0xffffff
        case "error": 0x800000
        case "warning": 0x806000
        case "success", "progress": xp ? 0x2fbe2f : 0x000080
        case "usagePurple": 0x663399
        case "usageRose": 0x993366
        default: xp ? 0xece9d8 : 0xc0c0c0
        }
        return rgb(value)
    }
    static func font(_ appearance: PanelAppearance, role: MimicFontRole = .body, bold: Bool = false, scale: CGFloat = 1) -> NSFont {
        let caption = appearance == .windowsXP && role == .heading
        let name = appearance == .windows95 ? (bold || role == .heading ? "MS Sans Serif 95 Bold" : "MS Sans Serif 95 Regular")
            : caption ? "TrebuchetMS-Bold" : bold ? "Tahoma-Bold" : "Tahoma"
        return NSFont(name: name, size: (caption ? 13 : 11) * scale)
            ?? .systemFont(ofSize: (caption ? 13 : 11) * scale, weight: bold || role == .heading ? .bold : .regular)
    }
    static func missingFonts(_ appearance: PanelAppearance) -> [String] {
        let names = appearance == .windows95 ? ["MS Sans Serif 95 Regular", "MS Sans Serif 95 Bold"]
            : appearance == .windowsXP ? ["Tahoma", "Tahoma-Bold", "TrebuchetMS-Bold"] : []
        return names.filter { NSFont(name: $0, size: 11) == nil }
    }
    static func titleHeight(_ appearance: PanelAppearance) -> CGFloat { appearance == .windowsXP ? 28 : 18 }
    static func icon(_ block: PanelBlockKind) -> String {
        switch block {
        case .bootstrap: "folder"
        case .builds: "build"
        case .simulators: "screen"
        default: "list"
        }
    }
    static func assetName(_ name: String, appearance: PanelAppearance) -> String {
        "native-r1-" + (appearance == .windowsXP ? "xp-" : "win95-") + name
    }
    @MainActor private static var images: [String: NSImage] = [:]
    @MainActor static func image(_ name: String, appearance: PanelAppearance) -> NSImage? {
        let key = assetName(name, appearance: appearance)
        if let image = images[key] { return image }
        guard let url = MimicResources.bundle.url(forResource: key, withExtension: "png"),
              let data = try? Data(contentsOf: url), let small = NSBitmapImageRep(data: data) else { return nil }
        let image = NSImage(size: CGSize(width: small.pixelsWide, height: small.pixelsHigh))
        small.size = image.size; image.addRepresentation(small)
        if let url = MimicResources.bundle.url(forResource: key + "@2x", withExtension: "png"),
           let data = try? Data(contentsOf: url), let large = NSBitmapImageRep(data: data) {
            large.size = image.size; image.addRepresentation(large)
        }
        images[key] = image; return image
    }
}

/// Artwork-only AppKit view: hit testing, keyboard activation and accessibility stay with SwiftUI controls.
struct NativeRetroArtwork: NSViewRepresentable {
    enum Kind: Equatable { case frame, border, surfaceBorder, button, title, input, inputBorder, checkbox(Bool), progress(Double?), caption(String) }
    let appearance: PanelAppearance
    var kind: Kind = .frame
    var pressed = false
    var hovered = false
    var enabled = true
    func makeNSView(context: Context) -> ArtworkView { ArtworkView() }
    func updateNSView(_ view: ArtworkView, context: Context) {
        view.appearanceChoice = appearance; view.kind = kind; view.pressed = pressed
        view.hovered = hovered; view.enabled = enabled; view.needsDisplay = true
    }
    final class ArtworkView: NSView {
        var appearanceChoice = PanelAppearance.windows95
        var kind = Kind.frame
        var pressed = false, hovered = false, enabled = true
        var drawsFocus = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { nil }
        private func fill(_ rect: CGRect, _ color: NSColor) { color.setFill(); rect.fill() }
        private func bevel(_ rect: CGRect, sunken: Bool = false) {
            for (inset, light, dark) in [(CGFloat(0), sunken ? 0x808080 : 0xffffff, sunken ? 0xffffff : 0x000000),
                                        (CGFloat(1), sunken ? 0x000000 : 0xdfdfdf, sunken ? 0xdfdfdf : 0x808080)] {
                let r = rect.insetBy(dx: inset, dy: inset)
                fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1), NativeRetro.rgb(light))
                fill(CGRect(x: r.minX, y: r.minY, width: 1, height: r.height), NativeRetro.rgb(light))
                fill(CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), NativeRetro.rgb(dark))
                fill(CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height), NativeRetro.rgb(dark))
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            guard appearanceChoice.isRetro else { return }
            let xp = appearanceChoice == .windowsXP
            switch kind {
            case .title:
                if xp {
                    NSGraphicsContext.saveGraphicsState()
                    let contour = NSBezierPath()
                    contour.move(to: CGPoint(x: 0, y: bounds.height)); contour.line(to: CGPoint(x: 0, y: 8))
                    contour.curve(to: CGPoint(x: 8, y: 0), controlPoint1: CGPoint(x: 0, y: 3), controlPoint2: CGPoint(x: 3, y: 0))
                    contour.line(to: CGPoint(x: bounds.width - 8, y: 0))
                    contour.curve(to: CGPoint(x: bounds.width, y: 8), controlPoint1: CGPoint(x: bounds.width - 3, y: 0), controlPoint2: CGPoint(x: bounds.width, y: 3))
                    contour.line(to: CGPoint(x: bounds.width, y: bounds.height)); contour.close(); contour.addClip()
                    let stops: [(CGFloat, Int)] = [(0,0x0997ff),(0.08,0x0053ee),(0.40,0x0050ee),(0.88,0x0066ff),(0.93,0x0066ff),(0.95,0x005bff),(0.96,0x003dd7),(1,0x003dd7)]
                    let gradient = NSGradient(colors: stops.map { NativeRetro.rgb($0.1) }, atLocations: stops.map(\.0), colorSpace: .sRGB)!
                    gradient.draw(in: bounds, angle: 90)
                    for side in [false, true] {
                        if let image = NativeRetro.image("top-contour", appearance: appearanceChoice) {
                            image.draw(in: CGRect(x: side ? bounds.width - 8 : 0, y: 0, width: 8, height: 8), from: CGRect(x: side ? image.size.width - 8 : 0, y: 0, width: 8, height: 8), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
                        }
                    }
                    NSGraphicsContext.restoreGraphicsState()
                } else { fill(bounds, NativeRetro.color("title", appearance: appearanceChoice)) }
            case .frame, .border:
                if kind == .frame { fill(bounds, NativeRetro.color("surface", appearance: appearanceChoice)) }
                if xp {
                    for (offset, left, right) in [(CGFloat(0),0x0831d9,0x00138c),(1,0x166aee,0x001ea0),(2,0x0855dd,0x003bda)] {
                        fill(CGRect(x: offset, y: 8, width: 1, height: max(0, bounds.height - 8)), NativeRetro.rgb(left))
                        fill(CGRect(x: bounds.width - offset - 1, y: 8, width: 1, height: max(0, bounds.height - 8)), NativeRetro.rgb(right))
                        fill(CGRect(x: 0, y: bounds.height - offset - 1, width: bounds.width, height: 1), NativeRetro.rgb(right))
                    }
                } else { bevel(bounds) }
            case .surfaceBorder:
                if xp {
                    NativeRetro.color("line", appearance: appearanceChoice).setStroke()
                    NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
                } else { bevel(bounds) }
            case .button, .caption:
                let isPressed = pressed && enabled
                if xp {
                    if case .caption = kind { fill(bounds, NativeRetro.color("title", appearance: appearanceChoice)) }
                    else {
                        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                        NSGradient(starting: NativeRetro.rgb(isPressed ? 0xc9c3b6 : 0xffffff), ending: NativeRetro.rgb(isPressed ? 0xf5f4ee : 0xd8d0c4))!.draw(in: path, angle: 90)
                        NativeRetro.rgb(0x003c74).setStroke(); path.stroke()
                        if hovered && enabled && !isPressed {
                            NativeRetro.rgb(0xf6c26b).setStroke()
                            let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 2, yRadius: 2)
                            inner.lineWidth = 2; inner.stroke()
                        }
                    }
                } else { fill(bounds, NativeRetro.rgb(0xc0c0c0)); bevel(bounds, sunken: isPressed) }
                if case let .caption(name) = kind {
                    let state = !enabled ? "disabled" : isPressed ? "pressed" : hovered ? "hot" : "normal"
                    if let image = NativeRetro.image(name + "-" + state, appearance: appearanceChoice) {
                        let rect = xp ? bounds : CGRect(x: isPressed ? 4 : 3, y: isPressed ? 3 : 2, width: image.size.width, height: image.size.height)
                        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
                    }
                }
            case let .checkbox(checked):
                fill(bounds, enabled && !pressed ? .white : NativeRetro.color("surface", appearance: appearanceChoice))
                if xp {
                    NativeRetro.rgb(0x7f9db9).setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
                } else { bevel(bounds, sunken: true) }
                if checked {
                    (enabled ? NSColor.black : NativeRetro.rgb(0x6d6d6d)).setStroke()
                    let mark = NSBezierPath(); mark.lineWidth = max(2, bounds.width / 6.5)
                    mark.move(to: CGPoint(x: bounds.width * 0.23, y: bounds.height * 0.48))
                    mark.line(to: CGPoint(x: bounds.width * 0.43, y: bounds.height * 0.7))
                    mark.line(to: CGPoint(x: bounds.width * 0.8, y: bounds.height * 0.25)); mark.stroke()
                }
            case .input, .inputBorder, .progress:
                if kind != .inputBorder { fill(bounds, .white) }
                if xp {
                    NativeRetro.rgb(0x7f9db9).setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
                } else { bevel(bounds, sunken: true) }
                if case let .progress(value) = kind, let value, value.isFinite {
                    let inner = bounds.insetBy(dx: 3, dy: 3)
                    let end = inner.width * min(1, max(0, value))
                    for x in stride(from: CGFloat(0), to: end, by: 8) {
                        fill(CGRect(x: inner.minX + x, y: inner.minY, width: min(6, end - x), height: inner.height), NativeRetro.color("progress", appearance: appearanceChoice))
                    }
                }
            }
            if drawsFocus {
                NSColor.black.setStroke(); let path = NSBezierPath(rect: bounds.insetBy(dx: 4.5, dy: 4.5))
                path.setLineDash([1, 1], count: 2, phase: 0); path.lineWidth = 1; path.stroke()
            }
        }
    }
}

// MARK: - Native interaction and retained content

struct NativeRetroTitle: View {
    let block: PanelBlockKind
    let expanded: Bool
    let action: () -> Void
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var textScale
    var body: some View {
        let xp = theme.appearance == .windowsXP
        HStack(spacing: 4) {
            if let image = NativeRetro.image(NativeRetro.icon(block), appearance: theme.appearance) {
                Image(nsImage: image).interpolation(.none).frame(width: 16, height: 16).accessibilityHidden(true)
            }
            Text(text(block.titleKey)).font(Font(NativeRetro.font(theme.appearance, role: .heading, bold: true, scale: textScale)))
                .foregroundStyle(.white).lineLimit(1).mimicHelp(text(block.titleKey))
                .shadow(color: xp ? Color(nsColor: NativeRetro.rgb(0x0f0f8a)) : .clear, radius: 0, x: 1, y: 1)
            Spacer(minLength: 0)
            Button(action: action) { Color.clear.frame(width: xp ? 21 : 16, height: xp ? 21 : 14) }
                .buttonStyle(NativeRetroPrimitiveButtonStyle(height: xp ? 21 : 14, caption: expanded ? "restore" : "maximize"))
                .accessibilityLabel(text(expanded ? "panel.collapsed" : "panel.expanded") + ": " + text(block.titleKey))
                .accessibilityIdentifier("panel.caption." + block.rawValue).background(PanelControlRegion())
        }.padding(.leading, xp ? 7 : 5).padding(.trailing, 3)
            .frame(height: NativeRetro.titleHeight(theme.appearance) * textScale)
            .background(NativeRetroArtwork(appearance: theme.appearance, kind: .title))
            .background(PanelDragHeaderRegion()).accessibilityValue(disclosureValue(expanded))
    }
}

/// One conditional background preserves the identity of the content being restyled.
struct NativeRetroSurface: ViewModifier {
    private var theme = MimicTheme()
    func body(content: Content) -> some View {
        content.overlay { if theme.appearance.isRetro { NativeRetroArtwork(appearance: theme.appearance, kind: .surfaceBorder).allowsHitTesting(false) } }
    }
}

/// Unknown work remains a static indicator in R1; only observed fractions fill the segmented bar.
struct MimicActivityProgressStyle: ProgressViewStyle {
    private var theme = MimicTheme()
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if theme.retro {
            if let fraction = configuration.fractionCompleted {
                MimicProgressBar(value: fraction, color: theme.color("progress"), label: text("build.progress"))
            } else { Text("…").mimicFont(.caption).accessibilityLabel(text("build.progress.active")) }
        } else { ProgressView(configuration).progressViewStyle(.automatic) }
    }
}

/// A native field editor is shared by its window. Preserve ordinary selection after relayout,
/// and defer all theme geometry until marked text commits, including changes arriving from Codex.
@MainActor final class NativeAppearanceContinuity {
    private let store: PanelAppearanceStore
    private var compositionTimer: Timer?
    private let editingWindow: () -> NSWindow?
    init(store: PanelAppearanceStore, shared: CodexPanelAppearanceStore, editingWindow: @escaping () -> NSWindow? = { NSApp?.keyWindow }) {
        self.store = store
        self.editingWindow = editingWindow
        shared.selectionWillChange = { [weak self] in self?.prepareChange() }
    }
    private func prepareChange() {
        guard let window = editingWindow(), let editor = window.firstResponder as? NSTextView else { return }
        if editor.hasMarkedText() {
            store.deferPresentation()
            compositionTimer?.invalidate()
            compositionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak editor] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if editor?.hasMarkedText() != true {
                        let selection = editor?.selectedRange()
                        self.compositionTimer?.invalidate(); self.compositionTimer = nil
                        self.store.resumePresentation()
                        if let editor, let selection { self.restoreSelection(editor, window: window, selection: selection) }
                    }
                }
            }
        } else { restoreSelection(editor, window: window, selection: editor.selectedRange()) }
    }
    private func restoreSelection(_ editor: NSTextView, window: NSWindow, selection: NSRange) {
        DispatchQueue.main.async { [weak editor, weak window] in
            guard let editor, let window, window.firstResponder === editor, !editor.hasMarkedText() else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            let count = editor.string.utf16.count
            if selection.location <= count { editor.setSelectedRange(NSRange(location: selection.location, length: min(selection.length, count - selection.location))) }
        }
    }
}
