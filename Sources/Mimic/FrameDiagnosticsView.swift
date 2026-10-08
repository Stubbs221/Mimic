//
//  FrameDiagnosticsView.swift
//  Mimic
//
//  Created by Василий Маслов on 08.10.2026.
import AppKit
import QuartzCore
import SwiftUI
import MimicCore

// MARK: - Footer sizing

/// Sacrifice CI text and graph width before hiding shortcut captions; never grow the footer.
@MainActor struct FooterPerformanceLayout {
    let diagnosticsWidth: CGFloat
    let ciWidth: CGFloat
    let iconOnly: Bool
    static func resolve(width: CGFloat, scale: CGFloat) -> Self {
        let font = NSFont.systemFont(ofSize: 11 * scale)
        let textWidth = FrameDiagnosticsNativeView.textWidth(scale: scale)
        let captionWidth = ["Xcode", text("footer.finder")].reduce(CGFloat(0)) { $0 + ($1 as NSString).size(withAttributes: [.font: font]).width }
        let iconsWidth = 2 * (11 * scale + 16)
        let fullWidth = captionWidth + iconsWidth + 8
        let ciMinimum = 80 * scale, gaps: CGFloat = 32
        let iconOnly = width - ciMinimum - textWidth - fullWidth - gaps < 32
        let shortcuts = iconOnly ? iconsWidth : fullWidth
        let graphWidth = min(64, max(32, width - ciMinimum - textWidth - shortcuts - gaps))
        let diagnosticsWidth = textWidth + graphWidth
        let ciWidth = max(0, min(160 * scale, width - diagnosticsWidth - shortcuts - gaps))
        return Self(diagnosticsWidth: diagnosticsWidth, ciWidth: ciWidth, iconOnly: iconOnly)
    }
}

struct FrameDiagnosticsView: NSViewRepresentable {
    let scale: CGFloat
    @Environment(\.mimicPanelAppearance) private var appearance
    func makeNSView(context: Context) -> FrameDiagnosticsNativeView { FrameDiagnosticsNativeView() }
    func updateNSView(_ view: FrameDiagnosticsNativeView, context: Context) {
        view.configure(scale: scale, tiled: appearance == .tileGrid)
        view.updateSampling()
    }
    static func dismantleNSView(_ view: FrameDiagnosticsNativeView, coordinator: ()) { view.stop() }
}

// MARK: - Window-scoped sampling

/// A weak target breaks CADisplayLink's retained-target cycle even if an owner forgets teardown.
@MainActor private final class FrameDiagnosticsTarget: NSObject {
    weak var view: FrameDiagnosticsNativeView?
    @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
}

/// Draws only this tiny native surface, avoiding SwiftUI or TaskCoordinator publications per frame.
final class FrameDiagnosticsNativeView: NSView {
    var tiled = false
    var textScale: CGFloat = 1
    private(set) var displayLink: CADisplayLink?
    private(set) var snapshot = FrameDiagnosticsSnapshot()
    private var samples = FrameDiagnosticsSamples()
    private var cpuOrigin = FrameMainThreadCPU.seconds()
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("footer.performance")
        setAccessibilityLabel(text("diagnostics.accessibility"))
        setAccessibilityHelp(text("diagnostics.help"))
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { displayLink?.invalidate(); NotificationCenter.default.removeObserver(self) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stop(); NotificationCenter.default.removeObserver(self)
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: NSApp)
        }
        updateSampling()
    }
    override func viewDidHide() { super.viewDidHide(); stop() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateSampling() }

    @objc private func visibilityChanged(_ note: Notification) {
        if note.name == NSWindow.willCloseNotification { stop(); return }
        if note.name == NSWindow.didChangeScreenNotification { stop() }
        updateSampling()
    }
    /// Unrelated owner updates must not schedule extra diagnostic redraws.
    func configure(scale: CGFloat, tiled: Bool) {
        guard textScale != scale || self.tiled != tiled else { return }
        textScale = scale; self.tiled = tiled; needsDisplay = true
    }
    func updateSampling() {
        guard let window, window.isVisible, !window.isMiniaturized, !NSApp.isHidden,
              window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { stop(); return }
        guard displayLink == nil else { return }
        // Hidden-window CPU must not be attributed to the next visible sampling window.
        cpuOrigin = FrameMainThreadCPU.seconds()
        let target = FrameDiagnosticsTarget(); target.view = self
        let link = displayLink(target: target, selector: #selector(FrameDiagnosticsTarget.tick(_:)))
        self.displayLink = link
        FramePerformanceTrace.view = self
        link.add(to: .main, forMode: .common)
    }
    func stop() {
        displayLink?.invalidate(); displayLink = nil
        samples.reset(); snapshot = .init(); needsDisplay = true
        cpuOrigin = FrameMainThreadCPU.seconds()
    }
    /// A private inspection resets only measurements, preserving the window-scoped display link.
    func resetMeasurements() { samples.reset(); cpuOrigin = FrameMainThreadCPU.seconds() }
    var report: FrameDiagnosticsReport { samples.report() }
    var mainThreadCPUSeconds: Double { max(0, FrameMainThreadCPU.seconds() - cpuOrigin) }
    fileprivate func tick(_ link: CADisplayLink) {
        let publish = samples.record(at: CACurrentMediaTime(), budget: link.targetTimestamp - link.timestamp)
        if samples.lastIntervalMS > samples.frameBudgetMS * 2 + 0.001 {
            FramePerformanceTrace.frameMiss(durationMS: samples.lastIntervalMS, budgetMS: samples.frameBudgetMS)
        }
        guard publish else { return }
        present(samples.snapshot())
    }
    func present(_ value: FrameDiagnosticsSnapshot) {
        snapshot = value
        setAccessibilityValue(fpsLabel + ", " + milliseconds(snapshot.maximumMS))
        needsDisplay = true
    }

    // MARK: - Drawing and hover inspection

    static func textWidth(scale: CGFloat) -> CGFloat {
        fpsWidth(scale: scale) + (text("diagnostics.ms") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10 * scale)]).width + 8
    }
    private static func fpsWidth(scale: CGFloat) -> CGFloat {
        ceil(("9999 FPS" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 * scale, weight: .regular)]).width)
    }
    var graphRect: NSRect {
        let start = Self.fpsWidth(scale: textScale) + 4
        return NSRect(x: start, y: 3, width: max(1, bounds.width - Self.textWidth(scale: textScale)), height: max(1, bounds.height - 6))
    }
    var fpsLabel: String { snapshot.fps.map { String(Int($0.rounded())) + " FPS" } ?? "— FPS" }
    private func milliseconds(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale.current, value) + " " + text("diagnostics.ms")
    }
    /// Tooltip coordinates select the same oldest-to-newest bucket as the rendered path.
    func graphHelp(at point: NSPoint) -> String {
        let index = min(39, max(0, Int((point.x - graphRect.minX) / graphRect.width * 40)))
        guard let peak = snapshot.peaks[index] else { return text("diagnostics.empty") }
        return milliseconds(peak) + " · " + text("diagnostics.bucket")
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        if graphRect.contains(point) { return graphHelp(at: point) }
        let report = samples.report()
        return text("diagnostics.help") + String(format: "\np95 %.2f · p99 %.2f %@ · >2×: %d (%.0f s)", report.p95MS, report.p99MS, text("diagnostics.ms"), report.overTwoBudgets, report.elapsedSeconds)
    }
    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11 * textScale, weight: .regular)
        let label = fpsLabel as NSString
        label.draw(at: NSPoint(x: 0, y: (bounds.height - label.size(withAttributes: [.font: font]).height) / 2),
                   withAttributes: [.font: font, .foregroundColor: tiled ? MimicTheme.adaptive("ink") : NSColor.labelColor])
        let unitFont = NSFont.systemFont(ofSize: 10 * textScale), unit = text("diagnostics.ms") as NSString
        let size = unit.size(withAttributes: [.font: unitFont])
        unit.draw(at: NSPoint(x: bounds.maxX - size.width, y: (bounds.height - size.height) / 2),
                  withAttributes: [.font: unitFont, .foregroundColor: NSColor.secondaryLabelColor])
        let plot = graphRect, scale = snapshot.scaleMS
        let reference = NSBezierPath(); reference.move(to: NSPoint(x: plot.minX, y: plot.maxY - snapshot.budgetMS / scale * plot.height))
        reference.line(to: NSPoint(x: plot.maxX, y: plot.maxY - snapshot.budgetMS / scale * plot.height))
        reference.setLineDash([2, 2], count: 2, phase: 0); reference.lineWidth = 0.5
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke(); reference.stroke()
        let graph = NSBezierPath(); var connected = false
        for (index, value) in snapshot.peaks.enumerated() {
            guard let value else { connected = false; continue }
            let point = NSPoint(x: plot.minX + (CGFloat(index) + 0.5) / 40 * plot.width, y: plot.maxY - value / scale * plot.height)
            if connected { graph.line(to: point) } else { graph.move(to: point) }
            connected = true
        }
        graph.lineWidth = 1.2; (tiled ? MimicTheme.adaptive("accent") : NSColor.controlAccentColor).setStroke(); graph.stroke()
    }
}

struct FrameDiagnosticsSettingsView: View {
    @Bindable var settings: FrameDiagnosticsSettings
    @State private var helpExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("diagnostics.title")).mimicFont(.heading)
            SettingsSwitch(title: text("diagnostics.enabled"), isOn: $settings.enabled, identifier: "settings.frameDiagnostics")
            DisclosureGroup(text("settings.diagnostics.help"), isExpanded: $helpExpanded) {
                Text(text("diagnostics.help")).mimicFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.mimicFont(.caption)

        }
    }
}
