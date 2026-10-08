//
//  PanelScrollPerformanceTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 08.10.2026.
import AppKit
import Darwin
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

/// Opt-in profiling uses the real retained documents without accounts, subprocesses or AX queries.
/// Timings cover synchronous layout/display work, not the compositor's presented frame rate.
@Suite(.serialized) @MainActor struct PanelScrollPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_SCROLL_AUDIT_OUTPUT"] != nil))
    func retainedDocumentsScrollBenchmark() async throws {
        try await runFrameDiagnosticsApplication { try await measureRetainedDocuments() }
    }
    private func measureRetainedDocuments() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = try #require(environment["MIMIC_SCROLL_AUDIT_OUTPUT"])
        let seconds = Double(environment["MIMIC_SCROLL_AUDIT_SECONDS"] ?? "20") ?? 20
        let repeats = Int(environment["MIMIC_SCROLL_AUDIT_REPEATS"] ?? "3") ?? 3
        let scenarios = (environment["MIMIC_SCROLL_AUDIT_SCENARIOS"] ?? "home,expanded,settings").split(separator: ",").map(String.init)
        var results: [[String: Any]] = []
        for appearance in PanelAppearance.allCases {
            let suite = "PanelScrollAudit-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            let model = TaskCoordinator(directory: root, defaults: defaults)
            model.aiUsage.stop()
            model.frameDiagnostics.enabled = environment["MIMIC_SCROLL_AUDIT_DIAGNOSTICS"] == "1"
            defer {
                model.stopAndExit(); defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            model.appearance.select(appearance)
            model.activeProfile = try Profile11Fixture.snapshot(directory: root)
            let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: appearance.panelWidth, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.title = "Mimic scroll audit (fixture)"
            let host = NSHostingView(rootView: MimicPanel(model: model).frame(width: appearance.panelWidth, height: 420))
            window.contentView = host; window.orderFrontRegardless()
            defer { window.close() }
            for scenario in scenarios {
                model.returnHome(source: .keyboard)
                model.panelLayout.expanded = scenario == "expanded" ? .utils : nil
                if scenario == "settings" { model.openSettings(group: .application, source: .keyboard) }
                try await Task.sleep(for: .milliseconds(500))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                if model.frameDiagnostics.enabled {
                    let diagnostic = try #require(findDiagnostics(in: host))
                    diagnostic.updateSampling()
                    _ = try #require(diagnostic.displayLink)
                }
                let scroll = try #require(findScroll(in: host, id: scenario == "settings" ? "page.settings" : "page.home"))
                for repetition in 1...max(1, repeats) {
                    var costs: [Double] = []
                    let cpuStart = processCPUSeconds()
                    let start = ProcessInfo.processInfo.systemUptime
                    while ProcessInfo.processInfo.systemUptime - start < seconds {
                                let elapsed = ProcessInfo.processInfo.systemUptime - start
                        let limit = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                        let phase = elapsed.truncatingRemainder(dividingBy: 2) / 2
                        let fraction = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                        let before = ProcessInfo.processInfo.systemUptime
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: limit * fraction))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                        costs.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
                        try await Task.sleep(for: .milliseconds(16))
                    }
                    if model.frameDiagnostics.enabled { _ = try #require(findDiagnostics(in: host)?.snapshot.fps) }
                    let sorted = costs.sorted()
                    results.append(["appearance": appearance.rawValue, "scenario": scenario, "repetition": repetition,
                                    "diagnosticsEnabled": model.frameDiagnostics.enabled, "processCPUMS": (processCPUSeconds() - cpuStart) * 1000,
                                    "frames": costs.count, "totalWorkMS": costs.reduce(0, +),
                                    "p95WorkMS": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                                    "maxWorkMS": sorted.last ?? 0, "workOver100MS": costs.filter { $0 >= 100 }.count,
                                    "scrollRange": max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)])
                    try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
                }
            }
        }
    }

    /// Independent of the diagnostic counter, including work between scroll operations.
    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func findDiagnostics(in view: NSView) -> FrameDiagnosticsNativeView? {
        (view as? FrameDiagnosticsNativeView) ?? view.subviews.lazy.compactMap { findDiagnostics(in: $0) }.first
    }

    private func findScroll(in view: NSView, id: String) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.identifier?.rawValue == id { return scroll }
        return view.subviews.lazy.compactMap { findScroll(in: $0, id: id) }.first
    }
}
