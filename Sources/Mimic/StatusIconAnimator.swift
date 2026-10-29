//
//  StatusIconAnimator.swift
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import AppKit
import MimicCore

/// Queue occupancy alone is not work: prompts and uncertain Xcode ownership must not keep chewing.
@MainActor
struct StatusIconActivity {
    let working: Bool
    let marker: StatusIcon.Marker
    let healthKey: String

    init(model: TaskCoordinator) {
        let build = model.builds.active
        let buildWaiting = build?.needsInput == true || (build?.stage == .products && (build?.products?.count ?? 0) > 1 && build?.selectedProductID == nil)
        let taskWaiting = model.activeID.map { model.awaitingInput.contains($0) } == true
        self.working = model.analysis.isActive || model.switchingBranch || !model.agentMetadataPending.isEmpty || model.simulatorScreen.busy
            || (model.preparing && !model.bootstrapIsBlocked)
            || model.records.contains { $0.status == .running && !model.awaitingInput.contains($0.id) }
            || (build.map { $0.status == .preparing || $0.status == .running } == true && !buildWaiting)
        self.marker = model.bootstrapIsBlocked || (!self.working && (taskWaiting || buildWaiting)) ? .paused : model.unreadFailure ? .failed : .none
        self.healthKey = model.bootstrapIsBlocked ? "bootstrap.xcode.waiting" : self.working ? "status.running"
            : taskWaiting || build?.needsInput == true ? "panel.notice.input" : buildWaiting ? "build.phase.products"
            : model.unreadFailure ? "status.failed" : "status.idle"
    }
}

/// Owns only the existing button's image. Frames never refresh the panel, usage text or accessibility value.
@MainActor
final class StatusIconAnimator {
    static let cycleDuration = 4.0
    private static let chewingDuration = 0.64
    private static let frameSteps = 16
    private weak var button: NSStatusBarButton?
    private let settings: MimicMotionSettings
    private let clock: () -> Double
    private let automaticallyTicks: Bool
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var startedAt: Double?
    private var marker: StatusIcon.Marker = .none
    private var frames: [NSImage] = []
    private var renderedFrame = -1
    private var suspended = false
    private(set) var working = false
    private(set) var openness: CGFloat = 0
    var image: NSImage { self.frames[self.renderedFrame] }
    var isAnimating: Bool { self.working && !self.suspended && !self.settings.nativeReduceMotion }

    init(settings: MimicMotionSettings, automaticallyTicks: Bool = true, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings; self.automaticallyTicks = automaticallyTicks; self.clock = clock
        let center = NSWorkspace.shared.notificationCenter
        self.observers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMotion() }
        })
        for (name, suspended) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended(suspended) }
            })
        }
        self.frames = [StatusIcon.image()]; self.renderedFrame = 0
    }

    isolated deinit {
        self.timer?.invalidate()
        for observer in self.observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    // MARK: - Work and accessibility transitions

    func update(button: NSStatusBarButton, working: Bool, marker: StatusIcon.Marker) {
        let changesArtwork = self.marker != marker || self.button !== button
        self.button = button
        if changesArtwork { self.marker = marker; self.frames = []; self.renderedFrame = -1 }
        let working = working && marker != .paused
        if self.working != working {
            self.working = working; self.startedAt = working ? self.clock() : nil
        }
        self.refreshMotion()
    }

    /// Accessibility changes apply immediately, including while the native menu is tracking.
    func refreshMotion() {
        self.timer?.invalidate(); self.timer = nil
        self.advance(to: self.clock()); self.scheduleTick()
    }

    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        self.refreshMotion()
    }

    func stop() {
        self.working = false; self.startedAt = nil
        self.timer?.invalidate(); self.timer = nil
        self.advance(to: self.clock()); self.button = nil
    }

    // MARK: - Double chew and sleeping driver

    /// Two peaks at 140/460 ms, shut at 290/640 ms, then a 3.36-second rest.
    static func amount(at elapsed: Double) -> CGFloat {
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: self.cycleDuration)
        let keys: [(Double, Double)] = [(0, 0), (0.14, 1), (0.29, 0), (0.46, 1), (0.64, 0), (self.cycleDuration, 0)]
        for (start, end) in zip(keys, keys.dropFirst()) where phase <= end.0 {
            let fraction = MimicMotionPolicy.fraction((phase - start.0) / (end.0 - start.0), geometry: true)
            return CGFloat(start.1 + (end.1 - start.1) * fraction)
        }
        return 0
    }

    func advance(to now: Double) {
        let amount: CGFloat
        if !self.working || self.suspended { amount = 0 }
        else if self.settings.nativeReduceMotion { amount = 1 }
        else { amount = Self.amount(at: now - (self.startedAt ?? now)) }
        let index = Int((amount * CGFloat(Self.frameSteps)).rounded())
        self.openness = CGFloat(index) / CGFloat(Self.frameSteps)
        if self.frames.isEmpty || (index > 0 && self.frames.count == 1) {
            self.frames = (0...Self.frameSteps).map { StatusIcon.image(marker: self.marker, openness: CGFloat($0) / CGFloat(Self.frameSteps)) }
        }
        guard index != self.renderedFrame || self.button?.image !== self.frames[index] else { return }
        self.renderedFrame = index; self.button?.image = self.frames[index]
    }

    private func scheduleTick() {
        guard self.automaticallyTicks, self.isAnimating, self.button != nil else { return }
        let phase = max(0, self.clock() - (self.startedAt ?? self.clock())).truncatingRemainder(dividingBy: Self.cycleDuration)
        // The pause needs one wake-up, not a permanent 30 Hz timer; idle and reduced motion need none.
        let interval = phase < Self.chewingDuration ? 1.0 / 30 : Self.cycleDuration - phase
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil; self.advance(to: self.clock()); self.scheduleTick()
            }
        }
        timer.tolerance = phase < Self.chewingDuration ? 0.002 : 0.02
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
}
