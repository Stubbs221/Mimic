// Created by Василий Маслов on 08.10.2026.
import AppKit
import SwiftUI
import MimicCore
import Testing
@testable import Mimic

@Suite(.serialized) @MainActor struct FrameDiagnosticsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_NATIVE_TEST_HOST"] == "1"))
    func activityClockPausesAndResumesWithoutOwnerUpdates() async throws {
        try await runFrameDiagnosticsApplication {
            let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 240, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .floating
            defer { window.close() }
            let counter = ClockRenderCounter()
            @MainActor func clock(running: Bool, visible: Bool) -> some View {
                MimicActivityClock(running: running) { now in
                    counter.renders += 1
                    return Text(now.timeIntervalSince1970.description)
                }.environment(\.mimicPresentationVisible, visible)
            }
            let host = NSHostingView(rootView: clock(running: true, visible: true))
            window.contentView = host; window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(1250))
            #expect(counter.renders >= 2)
            for state in [(true, false), (false, true)] {
                host.rootView = clock(running: state.0, visible: state.1)
                try await Task.sleep(for: .milliseconds(100))
                let paused = counter.renders
                try await Task.sleep(for: .milliseconds(1250))
                #expect(counter.renders == paused)
            }
            let paused = counter.renders
            host.rootView = clock(running: true, visible: true)
            try await Task.sleep(for: .milliseconds(1250))
            #expect(counter.renders >= paused + 2)
        }
    }
    @Test func measurementWindowCountsBudgetMissesAndPercentiles() {
        var samples = FrameDiagnosticsSamples()
        var now = 0.0
        _ = samples.record(at: now, budget: 1 / 120)
        for index in 0..<120 {
            now += index == 60 ? 0.05 : 1 / 120
            _ = samples.record(at: now, budget: 1 / 120)
        }
        let report = samples.report()
        #expect(report.intervalCount == 120 && report.overTwoBudgets == 1)
        #expect(abs(report.p99MS - 1000 / 120) < 0.001)
        #expect(abs(report.maximumMS - 50) < 0.001)
        for _ in 0..<120 * 100 {
            now += 1 / 120
            _ = samples.record(at: now, budget: 1 / 120)
        }
        #expect(samples.report().elapsedSeconds <= 90.001)
        #expect(samples.report().overTwoBudgets == 0)
        samples.reset()
        #expect(samples.report().intervalCount == 0)
    }
    @Test(arguments: [60, 120]) func cadence(_ hz: Int) {
        var samples = FrameDiagnosticsSamples()
        var publications = 0
        for index in 0...hz * 3 {
            if samples.record(at: Double(index) / Double(hz), budget: 1 / Double(hz)) { publications += 1 }
        }
        #expect(abs((samples.snapshot().fps ?? 0) - Double(hz)) < 0.00001)
        #expect(abs(samples.snapshot().budgetMS - 1000 / Double(hz)) < 0.00001)
        #expect(publications == 12)
    }
    @Test func peaksHistoryAndReset() {
        var samples = FrameDiagnosticsSamples()
        _ = samples.record(at: 0, budget: 1 / 60)
        _ = samples.record(at: 0.15, budget: 1 / 60)
        _ = samples.record(at: 0.2, budget: 1 / 60)
        #expect(samples.snapshot().maximumMS == 150)
        #expect(samples.snapshot().peaks.count == 40)
        for index in 1...660 { _ = samples.record(at: 0.2 + Double(index) / 60, budget: 1 / 60) }
        #expect(samples.snapshot().maximumMS < 17)
        samples.reset()
        _ = samples.record(at: 1000, budget: 1 / 120)
        #expect(samples.snapshot().fps == nil)
        _ = samples.record(at: 1000 + 1 / 120, budget: 1 / 120)
        #expect(samples.snapshot().maximumMS < 9)
    }
    @Test func longIntervalAndHover() {
        var samples = FrameDiagnosticsSamples()
        for index in 0...60 { _ = samples.record(at: Double(index) / 60, budget: 1 / 60) }
        _ = samples.record(at: 1.15, budget: 1 / 60)
        let snapshot = samples.snapshot()
        #expect(abs(snapshot.maximumMS - 150) < 0.00001)
        #expect((snapshot.fps ?? 60) < 60)
        #expect(snapshot.scaleMS > 150)
        let view = FrameDiagnosticsNativeView()
        view.frame = NSRect(x: 0, y: 0, width: 170, height: 28)
        view.present(snapshot)
        let tooltip = view.graphHelp(at: NSPoint(x: view.graphRect.maxX - 0.1, y: 14))
        #expect(tooltip.contains("150")); #expect(tooltip.contains("мс"))
        #expect(!view.fpsLabel.contains("UI"))
    }
    @Test func persistenceAndSizing() throws {
        let suite = "FrameDiagnostics-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FrameDiagnosticsSettings(defaults: defaults)
        #expect(!settings.enabled)
        settings.enabled = true
        #expect(FrameDiagnosticsSettings(defaults: defaults).enabled)
        settings.enabled = false
        #expect(!FrameDiagnosticsSettings(defaults: defaults).enabled)
        #expect(!FooterPerformanceLayout.resolve(width: 528, scale: 1).iconOnly)
        #expect(FooterPerformanceLayout.resolve(width: 460, scale: 2).iconOnly)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_NATIVE_TEST_HOST"] == "1")) func windowLifetime() async throws {
        try await runFrameDiagnosticsApplication { try await verifyWindowLifetime() }
    }
    private func verifyWindowLifetime() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        var view: FrameDiagnosticsNativeView? = FrameDiagnosticsNativeView()
        weak var weakView = view
        window.contentView = view; window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        view?.updateSampling()
        var first = view?.displayLink
        _ = try #require(first)
        view?.updateSampling(); #expect(view?.displayLink === first)
        view?.isHidden = true; #expect(view?.displayLink == nil)
        view?.isHidden = false; view?.updateSampling()
        #expect(view?.displayLink != nil); #expect(view?.snapshot.fps == nil)
        window.close(); #expect(view?.displayLink == nil)
        window.contentView = nil; view = nil; first = nil
        try await Task.sleep(for: .milliseconds(150))
        #expect(weakView == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_NATIVE_TEST_HOST"] == "1")) func footerToggleAndAppearance() async throws {
        try await runFrameDiagnosticsApplication { try await verifyFooterToggleAndAppearance() }
    }
    private func verifyFooterToggleAndAppearance() async throws {
        let suite = "FrameDiagnosticsFooter-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        model.aiUsage.stop()
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 560, height: 76), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        defer { window.close() }
        let output = URL(fileURLWithPath: "/private/tmp/MimicFPS-20261008/renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in PanelAppearance.allCases {
            for dark in [false, true] {
                for scale: CGFloat in [1, 2] {
                    model.frameDiagnostics.enabled = false
                    let host = NSHostingView(rootView: MimicFooter(model: model)
                        .environment(\.mimicPanelAppearance, appearance).environment(\.mimicTextScale, scale)
                        .environment(\.colorScheme, dark ? .dark : .light).frame(width: 560, height: 76))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host; window.orderFrontRegardless()
                    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
                    #expect(diagnostics(in: host).isEmpty)
                    model.frameDiagnostics.enabled = true
                    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
                    let view = try #require(diagnostics(in: host).first)
                    #expect(diagnostics(in: host).count == 1)
                    #expect(view.frame.height == 28)
                    #expect(view.convert(view.bounds, to: host).maxX <= host.bounds.maxX)
                    view.present(.init(fps: 116, peaks: (0..<40).map { $0 == 31 ? 45 : 8.6 }, budgetMS: 1000 / 120))
                    host.displayIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(appearance.rawValue)-\(dark ? "dark" : "light")-\(Int(scale)).png"))
                    }
                    model.frameDiagnostics.enabled = false
                    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
                    #expect(diagnostics(in: host).isEmpty)
                    #expect(view.displayLink == nil)
                }
            }
        }
    }
    private func diagnostics(in view: NSView) -> [FrameDiagnosticsNativeView] {
        (view as? FrameDiagnosticsNativeView).map { [$0] } ?? view.subviews.flatMap { diagnostics(in: $0) }
    }

}

@MainActor private final class ClockRenderCounter { var renders = 0 }

// MARK: - Native test host precondition

/// Run opt-in window tests in a native host; SwiftPM does not own an NSApplication event loop.
@MainActor func runFrameDiagnosticsApplication(_ operation: @escaping @MainActor () async throws -> Void) async throws {
    try #require(NSApplication.shared.isRunning, "A native NSApplication test host is required")
    try await operation()
}
