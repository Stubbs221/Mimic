// Created by Василий Маслов on 02.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// One persistent window hosts independent Bootstrap and CI sections with operation-scoped dismissal.
@MainActor
final class BootstrapActivityPanel: NSObject, NSWindowDelegate {
    let window = PersistentBootstrapPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model: TaskCoordinator
    private let defaults: UserDefaults
    private var taskID: UUID?
    private var deadlineID: UUID?
    private var hiddenID: UUID?
    private var timer: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    var isCompletionHidden: Bool { self.hiddenID != nil && self.hiddenID == self.taskID }
    private var updating = false
    private var motion: MimicWindowMotion!
    private var naturalHeight: CGFloat?
    private var scrollHost: NSHostingView<MimicWindowRoot<ActivityViewport>>?
    private let completionDelay: Duration
    var anchor: () -> NSRect? = { nil }
    var open: () -> Void = { }
    init(model: TaskCoordinator, defaults: UserDefaults = .standard, completionDelay: Duration = .seconds(5)) {
        self.model = model; self.defaults = defaults; self.completionDelay = completionDelay
        super.init()
        self.window.title = text("ci.activity.title")
        self.window.isOpaque = false; self.window.backgroundColor = .clear; self.window.hasShadow = true
        self.window.level = .floating; self.window.hidesOnDeactivate = false
        self.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.window.delegate = self
        self.motion = MimicWindowMotion(window: self.window, settings: self.model.motionSettings)
        self.window.beginDrag = { [weak self] in self?.motion.beginDrag() }
        self.observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.screenChanged() } }
    }

    private var showsBootstrap: Bool {
        guard let activity = self.model.quickBootstrapActivity else { return false }
        return self.hiddenID != activity.record(in: self.model.records).id
    }
    private var contentStamp: String {
        (self.showsBootstrap ? self.taskID?.uuidString ?? "" : "") + ":" + (self.model.ciMonitor.overlay?.identity ?? "")
    }

    func update(force: Bool = false, show: Bool = true, immediateGeometry: Bool = false) {
        let activity = self.model.quickBootstrapActivity
        let record = activity?.record(in: self.model.records)
        if self.taskID != record?.id {
            self.timer?.cancel(); self.timer = nil; self.deadlineID = nil; self.hiddenID = nil; self.taskID = record?.id
        }
        if force { self.hiddenID = nil; self.deadlineID = nil; self.timer?.cancel(); self.timer = nil }
        guard self.showsBootstrap || self.model.ciMonitor.overlay != nil else { self.motion.setVisible(false); return }
        self.updating = true
        defer { self.updating = false }
        let content = MimicWindowRoot(presentation: self.motion.presentation, settings: self.model.motionSettings) {
            ActivityViewport(model: self.model, showsBootstrap: self.showsBootstrap, stamp: self.contentStamp,
                open: { [weak self] in self?.open() }, measured: { [weak self] height, stamp in
                    DispatchQueue.main.async { self?.naturalHeightChanged(height, stamp: stamp) }
                })
        }
        if let scrollHost { scrollHost.rootView = content }
        else {
            self.scrollHost = NSHostingView(rootView: content)
            self.scrollHost?.sizingOptions = []
            self.window.contentView = self.scrollHost
        }
        let natural = self.naturalHeight ?? 180
        let anchorRect = self.anchor() ?? NSScreen.main?.visibleFrame ?? .zero
        let saved = self.defaults.string(forKey: "bootstrap.card.origin").map(NSPointFromString)
        let point = self.window.isVisible ? self.window.frame.origin : saved ?? NSPoint(x: anchorRect.midX - 160, y: anchorRect.minY - natural)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchorRect
        let height = min(natural, max(60, visible.height - 16))
        let y = self.window.isVisible ? self.window.frame.maxY - height : point.y
        self.motion.setFrame(Self.clamped(NSRect(x: point.x, y: y, width: MimicMetrics.cardWidth, height: height), to: visible), immediate: immediateGeometry || !show || !self.window.isVisible)
        if show { self.motion.setVisible(true) }
        if self.deadlineID == nil, let activity, let record, activity.error == nil, record.status == .succeeded || record.status == .cancelled {
            self.deadlineID = record.id
            self.timer = Task { [weak self] in
                guard let delay = self?.completionDelay else { return }
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.taskID == record.id else { return }
                self.hiddenID = record.id; self.update()
            }
        }
    }

    /// The displayed host remains stable while either section appears, completes or is dismissed.
    private func naturalHeightChanged(_ height: CGFloat, stamp: String) {
        guard stamp == self.contentStamp, height > 0 else { return }
        guard self.naturalHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
        self.naturalHeight = height
        self.update(show: self.motion.desiredVisible)
    }

    func windowDidMove(_: Notification) {
        guard !self.updating, !self.motion.isAnimatingFrame else { return }
        self.defaults.set(NSStringFromPoint(self.window.frame.origin), forKey: "bootstrap.card.origin")
    }

    private func screenChanged() {
        self.motion.beginDrag()
        let visible = self.window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? self.window.frame
        self.updating = true
        self.motion.setFrame(Self.clamped(self.window.frame, to: visible), immediate: true)
        self.updating = false
        self.update(immediateGeometry: true)
    }

    static func clamped(_ frame: NSRect, to visible: NSRect) -> NSRect {
        NSRect(x: min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width)), y: min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height)), width: frame.width, height: frame.height)
    }

    func adjacentFrame(size: NSSize) -> NSRect {
        let card = self.window.frame
        let visible = self.window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? card
        let left = NSRect(x: card.minX - size.width - 8, y: card.maxY - size.height, width: size.width, height: min(size.height, visible.height))
        if left.minX >= visible.minX { return Self.clamped(left, to: visible) }
        var right = left; right.origin.x = card.maxX + 8
        if right.maxX <= visible.maxX { return Self.clamped(right, to: visible) }
        right.origin = NSPoint(x: card.minX, y: card.minY - size.height - 8)
        return Self.clamped(right, to: visible)
    }

    func stop() { self.motion.stop(); self.timer?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}

final class PersistentBootstrapPanel: NSPanel {
    var beginDrag: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_: Any?) { }
}

/// Section updates retain the same hosting view and window drag surface.
private struct ActivityViewport: View {
    @ObservedObject var model: TaskCoordinator
    let showsBootstrap: Bool
    let stamp: String
    let open: () -> Void
    let measured: (CGFloat, String) -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if self.showsBootstrap { QuickBootstrapView(model: self.model, showMimic: self.open, framed: false) }
                if self.showsBootstrap, self.model.ciMonitor.overlay != nil { Divider() }
                if let summary = self.model.ciMonitor.overlay {
                    CIActivitySection(summary: summary, open: { self.model.showCI(summary) }, hide: { self.model.ciMonitor.hideCI() })
                }
            }.fixedSize(horizontal: false, vertical: true).modifier(MimicCardBackground())
                .clipShape(RoundedRectangle(cornerRadius: MimicMetrics.surfaceRadius))
                .background(GeometryReader { proxy in Color.clear.preference(key: BootstrapHeightKey.self, value: proxy.size.height) })
        }.scrollIndicators(.hidden).frame(width: MimicMetrics.cardWidth).frame(maxHeight: .infinity)
            .onPreferenceChange(BootstrapHeightKey.self) { height in self.measured(height, self.stamp) }
    }
}

private struct BootstrapHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
