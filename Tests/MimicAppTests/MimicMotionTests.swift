//
//  MimicMotionTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import Combine
import Observation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor private final class MotionClock { var now = 0.0 }
@MainActor private struct MotionFixture {
    let window: NSPanel
    let settings = MimicMotionSettings()
    let clock = MotionClock()
    let controller: MimicWindowMotion
    init() {
        _ = NSApplication.shared
        self.window = NSPanel(contentRect: NSRect(x: 60, y: 60, width: 320, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.settings.reduceMotionOverride = false
        self.controller = MimicWindowMotion(window: self.window, settings: self.settings, automaticallyTicks: false, clock: { [clock] in clock.now })
    }
    func cleanUp() { self.controller.stop(); self.window.orderOut(nil) }
    func advance(_ seconds: Double) { self.clock.now += seconds; self.controller.advance(to: self.clock.now) }
}

@MainActor @Observable private final class CollapseProbe {
    var expanded = true
    var source = MimicMotionSource.pointer
    var mounted = 0
    var removed = 0
}
private struct CollapseProbeView: View {
    let probe: CollapseProbe
    var retainsContent = false
    var body: some View {
        MimicCollapse(expanded: self.probe.expanded, source: self.probe.source, retainsContent: self.retainsContent) {
            Text("Fixture disclosure").frame(width: 200, height: 100).background(Color.red)
                .onAppear { self.probe.mounted += 1 }.onDisappear { self.probe.removed += 1 }
        }.frame(width: 200, height: 130, alignment: .top)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct MimicMotionTests {
    @Test(arguments: [false, true])
    func retainedDisclosureMountsOnlyOnFirstOpenAndPreservesItsSubtree(reduceMotion: Bool) async throws {
        let probe = CollapseProbe(); probe.expanded = false
        let settings = MimicMotionSettings(); settings.reduceMotionOverride = reduceMotion
        let host = NSHostingView(rootView: CollapseProbeView(probe: probe, retainsContent: true).environment(\.mimicMotionSettings, settings))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 200, height: 130), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.mounted == 0 && probe.removed == 0)
        probe.expanded = true
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.mounted == 1 && probe.removed == 0)
        probe.expanded = false
        try await Task.sleep(for: .milliseconds(250))
        #expect(probe.mounted == 1 && probe.removed == 0)
        probe.expanded = true
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.mounted == 1 && probe.removed == 0)
    }

    @Test func initiallyClosedDisclosureRevealsWithReduceMotion() async throws {
        let probe = CollapseProbe(); probe.expanded = false
        let settings = MimicMotionSettings(); settings.reduceMotionOverride = true
        let host = NSHostingView(rootView: CollapseProbeView(probe: probe).environment(\.mimicMotionSettings, settings))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 200, height: 130), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50)); probe.expanded = true
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/MimicTileGrid-20261008/native/reduced-disclosure.png"))
        let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(pixel.redComponent > 0.8 && pixel.greenComponent < 0.5, "Disclosure pixel: \(pixel)")
        #expect(probe.mounted == 1 && probe.removed == 0)
    }

    @Test(arguments: [MimicMotionSource.pointer, .keyboard, .automatic])
    func policyCoversKeyboardReducedMotionAndDebugSpeed(_ source: MimicMotionSource) {
        for reduced in [false, true] {
            let policy = MimicMotionPolicy(source: source, reduceMotion: reduced)
            let kinds: [MimicMotionPolicy.Kind] = [.disclosure, .status, .enter, .exit, .geometry, .progress, .feedback]
            for kind in kinds {
                if source == .keyboard { #expect(policy.duration(kind) == 0); #expect(policy.animation(kind) == nil) }
                else if reduced { #expect(policy.duration(kind) == (kind == .geometry || kind == .progress ? 0 : 0.125)) }
                else { #expect(policy.duration(kind) <= 0.2 && policy.duration(kind) >= 0.125) }
                var slow = policy; slow.multiplier = 5
                #expect(slow.duration(kind) == policy.duration(kind) * 5)
            }
            #expect(policy.moves == (source != .keyboard && !reduced))
        }
    }

    @Test func specifiedCurvesHaveStableEndpointsAndMonotonicFrames() {
        for geometry in [false, true] {
            #expect(MimicMotionPolicy.fraction(0, geometry: geometry) == 0)
            #expect(MimicMotionPolicy.fraction(1, geometry: geometry) == 1)
            let fractions = (0...100).map { MimicMotionPolicy.fraction(Double($0) / 100, geometry: geometry) }
            #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        }
        #expect(MimicMotionPolicy.fraction(0.5) > 0.9)
        #expect(abs(MimicMotionPolicy.fraction(0.5, geometry: true) - 0.5) < 0.1)
    }

    @Test func visibilityFirstMiddleLastFramesAndImmediateSemantics() {
        let fixture = MotionFixture(); defer { fixture.cleanUp() }
        var changes: [Bool] = []; fixture.controller.visibilityChanged = { changes.append($0) }
        fixture.controller.setVisible(true, source: .pointer)
        #expect(fixture.window.isVisible && fixture.controller.desiredVisible && fixture.controller.presentation.interactive)
        #expect(fixture.window.alphaValue == 0 && fixture.controller.presentation.offset == -8)
        fixture.advance(0.075)
        #expect(fixture.window.alphaValue > 0 && fixture.window.alphaValue < 1)
        #expect(fixture.controller.presentation.offset > -8 && fixture.controller.presentation.offset < 0)
        fixture.advance(0.075)
        #expect(fixture.window.alphaValue == 1 && fixture.controller.presentation.offset == 0 && !fixture.controller.isTransitioning)
        fixture.controller.setVisible(false, source: .pointer)
        #expect(fixture.window.isVisible && !fixture.controller.presentation.interactive && fixture.window.ignoresMouseEvents)
        #expect(changes == [true, false])
        fixture.advance(0.063)
        #expect(fixture.window.isVisible && fixture.window.alphaValue > 0 && fixture.window.alphaValue < 1)
        fixture.advance(0.063)
        #expect(!fixture.window.isVisible)
    }

    @Test func reopenRetargetsCurrentFrameAndRejectsStaleCompletion() {
        let fixture = MotionFixture(); defer { fixture.cleanUp() }
        fixture.controller.setVisible(true, source: .keyboard)
        fixture.controller.setVisible(false, source: .pointer)
        let stale = fixture.controller.revision
        fixture.advance(0.04)
        let alpha = fixture.window.alphaValue, offset = fixture.controller.presentation.offset
        fixture.controller.setVisible(true, source: .pointer)
        #expect(fixture.window.alphaValue == alpha && fixture.controller.presentation.offset == offset)
        fixture.controller.completeVisibility(revision: stale)
        #expect(fixture.window.isVisible && fixture.controller.desiredVisible)
        fixture.advance(0.2)
        #expect(fixture.window.alphaValue == 1 && fixture.window.isVisible)
    }

    @Test func repeatedUpdatesDoNotReplayAppearanceAndEscapeFinishesExit() {
        let fixture = MotionFixture(); defer { fixture.cleanUp() }
        fixture.controller.setVisible(true, source: .pointer); fixture.advance(0.05)
        let revision = fixture.controller.revision, alpha = fixture.window.alphaValue
        fixture.controller.setVisible(true)
        #expect(fixture.controller.revision == revision && fixture.window.alphaValue == alpha)
        fixture.controller.setVisible(false, source: .pointer); fixture.advance(0.02)
        fixture.controller.setVisible(false, source: .keyboard)
        #expect(!fixture.window.isVisible && !fixture.controller.isTransitioning)
        fixture.advance(1)
        #expect(!fixture.window.isVisible)
        fixture.controller.setVisible(true, source: .keyboard)
        #expect(fixture.window.alphaValue == 1 && fixture.controller.presentation.offset == 0)
    }

    @Test func reduceMotionFadesWithoutOffsetOrHeightInterpolation() {
        let fixture = MotionFixture(); defer { fixture.cleanUp() }
        fixture.settings.reduceMotionOverride = true
        fixture.controller.setVisible(true, source: .pointer)
        #expect(fixture.controller.presentation.offset == 0)
        fixture.advance(0.06); #expect(fixture.window.alphaValue > 0 && fixture.window.alphaValue < 1)
        let target = NSRect(x: 60, y: 20, width: 320, height: 160)
        fixture.controller.setFrame(target)
        #expect(fixture.window.frame == target && !fixture.controller.isAnimatingFrame)
        fixture.advance(0.07); #expect(fixture.window.alphaValue == 1)
        fixture.controller.setVisible(false, source: .keyboard)
        #expect(!fixture.window.isVisible)
    }

    @Test func enablingReduceMotionFinishesGeometryAndRetainsOnlyFade() {
        let fixture = MotionFixture(); defer { fixture.cleanUp() }
        fixture.controller.setVisible(true, source: .pointer)
        let target = NSRect(x: 60, y: 20, width: 320, height: 160)
        fixture.controller.setFrame(target)
        fixture.advance(0.05)
        fixture.settings.reduceMotionOverride = true
        fixture.controller.advance(to: fixture.clock.now)
        #expect(fixture.controller.presentation.offset == 0 && fixture.window.frame == target && !fixture.controller.isAnimatingFrame)
        fixture.advance(0.125)
        #expect(fixture.window.alphaValue == 1 && fixture.controller.presentation.offset == 0)
    }

    @Test func heightKeepsTopEdgeAndDragCancelsAtCurrentFrame() {
        let fixture = MotionFixture(); defer { fixture.cleanUp() }
        fixture.controller.setVisible(true, source: .keyboard)
        let top = fixture.window.frame.maxY
        let target = NSRect(x: 60, y: top - 180, width: 320, height: 180)
        fixture.controller.setFrame(target)
        fixture.advance(0.1)
        #expect(fixture.window.frame.height > 120 && fixture.window.frame.height < 180)
        #expect(abs(fixture.window.frame.maxY - top) < 0.01)
        let current = fixture.window.frame
        fixture.controller.beginDrag(); fixture.advance(1)
        #expect(fixture.window.frame == current && !fixture.controller.isAnimatingFrame)
        fixture.controller.setFrame(target, immediate: true)
        #expect(fixture.window.frame == target)
    }

    @Test func keyboardNavigationPreservesDraftsAndManualScrollInvalidatesRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-motion-" + UUID().uuidString)
        let suite = "Mimic-motion-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        model.installInlinePanelPreview(); model.taskSearch = "fixture"; model.simulatorSearch = "iPad"
        var focusReleases = 0
        model.releasePanelFocus = { focusReleases += 1 }
        model.openSettings(source: .pointer)
        model.revealSection(.tasks, source: .keyboard)
        #expect(focusReleases > 0)
        #expect(model.expandedSection == .tasks && model.navigationSource == .keyboard && model.scrollSource == .keyboard)
        let request = model.panelScrollRequest
        model.cancelPanelScroll()
        #expect(model.panelScrollTarget.isEmpty && request != model.panelScrollRequest)
        model.toggleSection(.tasks, source: .keyboard)
        #expect(model.expandedSection == nil && model.taskSearch == "fixture" && model.simulatorSearch == "iPad")
        let original = try #require(model.records.first)
        model.showHistory(id: original.id, focusTerminal: true, source: .keyboard)
        #expect(model.selectedTaskID == original.id && model.navigationSource == .keyboard && model.scrollSource == .keyboard)
    }

    @Test func idleScrollDoesNotPublishAndActiveCancellationIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-scroll-" + UUID().uuidString)
        let suite = "Mimic-scroll-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        defer { model.stopAndExit(); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        model.aiUsage.stop()
        // Drain the model's queued startup notification before observing scroll-only mutations.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        var domain = 0, scroll = 0, callbacks = 0
        let domainSubscription = model.objectWillChange.sink { domain += 1 }
        let scrollSubscription = model.panelScroll.objectWillChange.sink { scroll += 1 }
        model.stateChanged = { callbacks += 1 }
        for _ in 0..<120 { #expect(!model.cancelPanelScroll()) }
        #expect(domain == 0 && scroll == 0)
        model.scrollPanel(to: "section.tasks", source: .keyboard)
        let old = model.panelScrollRequest
        #expect(model.panelScroll.isActive(old))
        #expect(model.cancelPanelScroll())
        for _ in 0..<120 { #expect(!model.cancelPanelScroll()) }
        #expect(!model.panelScroll.isActive(old) && scroll == 2 && domain == 0)
        model.scrollPanel(to: "section.tasks", source: .pointer)
        let current = model.panelScrollRequest
        model.panelScroll.complete(old)
        #expect(model.panelScroll.isActive(current))
        model.panelScroll.complete(current)
        #expect(!model.cancelPanelScroll())
        await Task.yield()
        #expect(callbacks == 0)
        withExtendedLifetime((domainSubscription, scrollSubscription)) { }
    }

    @Test func domainCallbacksCoalesceWithinOneTransaction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-callback-" + UUID().uuidString)
        let suite = "Mimic-callback-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        var callbacks = 0
        model.stateChanged = { callbacks += 1 }
        model.taskSearch = "fixture"; model.simulatorSearch = "iPad"; model.taskFilter = .failed
        try await Task.sleep(for: .milliseconds(10))
        #expect(callbacks == 1)
    }

    @Test func disclosureReopenKeepsOriginalSubtreeUntilFinalExit() async throws {
        let probe = CollapseProbe(), settings = MimicMotionSettings()
        let host = NSHostingView(rootView: CollapseProbeView(probe: probe).environment(\.mimicMotionSettings, settings))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 130)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        #expect(probe.mounted == 1)
        probe.expanded = false; host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        probe.expanded = true; host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(230))
        #expect(probe.mounted == 1 && probe.removed == 0)
        probe.source = .keyboard; probe.expanded = false; host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        #expect(probe.removed == 1)
    }

    @Test func newBootstrapCancelsOldHideAndKeepsDisplayedHost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-motion-card-" + UUID().uuidString)
        let suite = "Mimic-motion-card-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        model.motionSettings.reduceMotionOverride = false
        let panel = BootstrapActivityPanel(model: model, defaults: defaults, completionDelay: .milliseconds(40))
        defer { panel.stop(); panel.window.orderOut(nil); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        model.installBootstrapPreview()
        let index = try #require(model.records.indices.last)
        model.records[index].status = .succeeded; model.records[index].finishedAt = Date()
        panel.update()
        let host = panel.window.contentView
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !panel.isCompletionHidden, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(panel.isCompletionHidden)
        model.installBootstrapPreview(); panel.update()
        try await Task.sleep(for: .milliseconds(220))
        #expect(!panel.isCompletionHidden && panel.window.isVisible && panel.window.alphaValue == 1)
        #expect(panel.window.contentView === host)
        panel.update(); #expect(panel.window.contentView === host && panel.window.alphaValue == 1)
        #expect(defaults.string(forKey: "bootstrap.card.origin") == nil)
    }
    @Test func displayedBootstrapHeightInterpolatesWithoutPersistingFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-motion-height-" + UUID().uuidString)
        let suite = "Mimic-motion-height-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        model.motionSettings.reduceMotionOverride = false; model.motionSettings.speed = 5
        let panel = BootstrapActivityPanel(model: model, defaults: defaults)
        defer { panel.stop(); panel.window.orderOut(nil); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        model.installBootstrapPreview(); panel.update()
        let screen = try #require(panel.window.screen ?? NSScreen.main).visibleFrame
        var initial = panel.window.frame; initial.origin.y = screen.maxY - initial.height
        panel.window.setFrame(initial, display: true)
        let saved = defaults.string(forKey: "bootstrap.card.origin")
        let index = try #require(model.records.indices.last)
        model.records[index].status = .failed
        model.records[index].error = Array(repeating: "Fixture long error", count: 100).joined(separator: "\n")
        panel.update()
        #expect(panel.window.frame.height == initial.height)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while panel.window.frame.height <= initial.height, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(panel.window.frame.height > initial.height)
        #expect(panel.window.frame.height < screen.height - 16)
        #expect(abs(panel.window.frame.maxY - initial.maxY) < 1)
        #expect(defaults.string(forKey: "bootstrap.card.origin") == saved)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(panel.window.frame.height > initial.height + 100)
        #expect(screen.contains(panel.window.frame))
    }

}
