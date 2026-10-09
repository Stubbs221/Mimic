// Created by Василий Маслов on 04.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// An independent nonactivating overlay. Hiding it only detaches presentation.
@MainActor final class BuildActivityPanel: NSObject, NSWindowDelegate {
    let window = BuildFloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model: TaskCoordinator
    private let defaults: UserDefaults
    private var motion: MimicWindowMotion!
    private var currentID: UUID?
    private var hiddenID: UUID?
    private var deadlineID: UUID?
    private var timer: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var updating = false
    private var naturalHeight: CGFloat = 302
    var anchor: () -> NSRect? = { nil }
    init(model: TaskCoordinator, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        currentID = model.builds.records.last { $0.startedAt != nil }?.id; hiddenID = currentID
        super.init()
        window.title = text("build.title"); window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .floating; window.hidesOnDeactivate = false; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true; window.delegate = self
        motion = MimicWindowMotion(window: window, settings: model.motionSettings)
        window.beginDrag = { [weak self] in self?.motion.beginDrag() }
        window.contentView = NSHostingView(rootView: MimicWindowRoot(presentation: motion.presentation, settings: model.motionSettings, appearance: model.appearance) {
            BuildOverlayView(builds: model.builds, hide: { [weak self] in self?.hide() }, measured: { [weak self] height in
                DispatchQueue.main.async {
                    guard let self, height > 0, abs(self.naturalHeight - height) > 0.5 else { return }
                    self.naturalHeight = height
                    if self.motion.desiredVisible { self.update() }
                }
            })
        })
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.screenChanged() } }
    }
    var isPresented: Bool { motion.desiredVisible }
    func update() {
        guard let record = model.builds.overlayActivity else { return }
        if currentID != record.id { timer?.cancel(); timer = nil; deadlineID = nil; hiddenID = nil; currentID = record.id }
        if model.builds.pinned { timer?.cancel(); timer = nil; deadlineID = nil }
        guard hiddenID != record.id else { return }
        let visible = anchor() ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = window.isVisible ? window.frame.origin : defaults.string(forKey: "build.card.origin").map(NSPointFromString) ?? NSPoint(x: visible.maxX - 520 - 16, y: visible.minY + 16)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(origin) }?.visibleFrame ?? visible
        let height = min(self.naturalHeight, screen.height)
        let width = min(520, screen.width)
        if model.builds.overlayWidth != width { model.builds.overlayWidth = width }
        if window.isVisible { origin.y = window.frame.maxY - height }
        updating = true
        motion.setFrame(BootstrapActivityPanel.clamped(NSRect(origin: origin, size: .init(width: width, height: height)), to: screen), immediate: !window.isVisible)
        updating = false
        motion.setVisible(true)
        if !model.builds.pinned, deadlineID == nil, record.status == .succeeded || record.status == .cancelled {
            deadlineID = record.id
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, currentID == record.id, !model.builds.pinned else { return }
                hide()
            }
        }
    }
    func hide() { hiddenID = currentID; timer?.cancel(); timer = nil; motion.setVisible(false) }
    func windowDidMove(_ notification: Notification) { if !updating, !motion.isAnimatingFrame { defaults.set(NSStringFromPoint(window.frame.origin), forKey: "build.card.origin") } }
    private func screenChanged() {
        guard window.isVisible else { return }; updating = true; motion.beginDrag()
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        motion.setFrame(BootstrapActivityPanel.clamped(window.frame, to: screen), immediate: true); updating = false
    }
    func stop() { timer?.cancel(); motion.stop(); window.orderOut(nil); window.contentView = nil; window.delegate = nil; if let observer { NotificationCenter.default.removeObserver(observer) } }
}
final class BuildFloatingPanel: NSPanel {
    var beginDrag: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func mouseDown(with event: NSEvent) { beginDrag?(); super.mouseDown(with: event) }
}

struct BuildOverlayView: View {
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var textScale
    @ObservedObject var builds: BuildCoordinator
    let hide: () -> Void
    var measured: (CGFloat) -> Void = { _ in }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        if let record = builds.overlayActivity {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(buildTitle(record)).font(.system(size: 13, weight: .semibold)); Spacer(); Button { builds.pinned.toggle() } label: { Image(systemName: builds.pinned ? "pin.fill" : "pin") }.buttonStyle(.plain).accessibilityLabel(text("build.pin")).accessibilityValue(text(builds.pinned ? "build.pinned" : "build.unpinned")); Button(action: hide) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(text("build.hide")) }
                ViewThatFits(in: .horizontal) {
                    HStack { Text(text(record.phase)).fixedSize(horizontal: true, vertical: false); Spacer(); clock(record) }
                    VStack(alignment: .leading, spacing: 4) { Text(text(record.phase)); clock(record) }
                }.mimicFont(.body).foregroundStyle(buildColor(record))
                BuildProgressView(record: record)
                if let count = record.completedStages, record.parameters.intent == .run { Text(String(format: text("build.progress.stages"), count, record.progressTotal)).mimicFont(.caption).foregroundStyle(.secondary) }
                if let count = record.completedTestCount, let total = record.selectedTestCount { Text(String(format: text("build.progress.tests"), count, total)).mimicFont(.caption).foregroundStyle(.secondary) }
                Text(URL(fileURLWithPath: record.project.path).lastPathComponent + " · " + record.project.branch).mimicFont(.caption).fixedSize(horizontal: false, vertical: true).help(record.project.path)
                Text([record.parameters.scheme, record.destinationName ?? text("build.destination.selected"), buildInitiator(record)].filter { !$0.isEmpty }.joined(separator: " · ")).mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = record.errorCode { Text(text("build.error." + error)).mimicFont(.caption).foregroundStyle(.orange) }
                HStack {
                    if record.canCancel { Button(text("build.stop")) { builds.cancel(record.id) } }
                    if record.stage == .products, let products = record.products, products.count > 1 {
                        Menu(text("build.chooseProduct")) { ForEach(products) { product in Button(product.name) { try? builds.chooseProduct(product.id, activityID: record.id) } } }
                    }
                    Spacer(minLength: 0)
                    Button(text("build.output")) { builds.showResult(record.id) }
                }.controlSize(.small).buttonStyle(MimicAuxiliaryButtonStyle())
            }.padding(MimicMetrics.cardInsets).frame(width: builds.overlayWidth).fixedSize(horizontal: false, vertical: true)
                .background { if theme.tiled { theme.color("surface") } else if reduceTransparency || contrast == .increased { Color(nsColor: .windowBackgroundColor) } else if #available(macOS 26.0, *) { Rectangle().fill(.clear).glassEffect(.regular, in: RoundedRectangle(cornerRadius: theme.tiled ? 18 : 12)) } else { Rectangle().fill(.regularMaterial) } }
                .clipShape(RoundedRectangle(cornerRadius: theme.tiled ? 18 : 12)).overlay(RoundedRectangle(cornerRadius: theme.tiled ? 18 : 12).stroke(.primary.opacity(contrast == .increased ? 0.5 : 0.12)))
                .accessibilityIdentifier("build.overlay")
                .background(GeometryReader { proxy in Color.clear.preference(key: BuildOverlayHeight.self, value: proxy.size.height) })
                .onPreferenceChange(BuildOverlayHeight.self) { self.measured($0) }
        }
    }
    private func clock(_ record: BuildActivity) -> some View {
        MimicActivityClock(running: record.status.isPending) { _ in Text(buildDuration(record)).monospacedDigit() }
    }

}

private struct BuildOverlayHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
