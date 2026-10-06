//
//  AIUsageTrendPopoverTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

/// Advances hover deadlines synchronously; cancelled callbacks never run.
@MainActor
private final class TrendHoverClock {
    private final class Job {
        let at: Double
        let action: @MainActor () -> Void
        var cancelled = false
        init(at: Double, action: @escaping @MainActor () -> Void) { self.at = at; self.action = action }
    }
    var now = 0.0
    private var jobs: [Job] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let job = Job(at: self.now + delay, action: action); self.jobs.append(job)
        return { job.cancelled = true }
    }
    func advance(_ seconds: Double) {
        self.now += seconds
        let due = self.jobs.filter { $0.at <= self.now }; self.jobs.removeAll { $0.at <= self.now }
        for job in due where !job.cancelled { job.action() }
    }
}

@Suite(.serialized) @MainActor
struct AIUsageTrendPopoverTests {
    private func points() -> [AIUsageDailyPoint] {
        let now = Date(timeIntervalSince1970: 1_791_187_200)
        return (0...30).map { .init(date: now.addingTimeInterval(Double($0) * 86400), tokens: $0.isMultiple(of: 5) ? 0 : $0 * 1000) }
    }
    @Test
    func dwellAndTravelGraceAreDeterministic() {
        let clock = TrendHoverClock(), state = AIUsageTrendPopoverState(points: self.points(), schedule: clock.schedule)
        state.inlineHover(true); #expect(state.overInline && !state.isPresented)
        clock.advance(0.399); #expect(!state.isPresented)
        clock.advance(0.0011); #expect(state.isPresented)
        state.inlineHover(false); clock.advance(0.179); #expect(state.isPresented)
        state.detailHover(true); clock.advance(1); #expect(state.isPresented)
        state.detailHover(false); clock.advance(0.179); #expect(state.isPresented)
        clock.advance(0.0011); #expect(!state.isPresented)
    }
    @Test
    func quickHoverCloseAndReopenCancelOldDeadlines() {
        let clock = TrendHoverClock(), state = AIUsageTrendPopoverState(points: self.points(), schedule: clock.schedule)
        state.inlineHover(true); clock.advance(0.2); state.inlineHover(false)
        clock.advance(1); #expect(!state.isPresented && !state.overInline)
        state.inlineHover(true); state.dismiss(); clock.advance(1)
        #expect(!state.isPresented && !state.isPinned && !state.overInline)
        state.inlineHover(true); clock.advance(0.4); #expect(state.isPresented)
        state.inlineHover(false); clock.advance(0.1); state.inlineHover(true); clock.advance(0.2)
        #expect(state.isPresented)
        state.dismiss(); clock.advance(1); #expect(!state.isPresented)
    }
    @Test
    func explicitOpeningPinsUntilDismissalAndEmptyDataCannotOpen() {
        let clock = TrendHoverClock(), state = AIUsageTrendPopoverState(points: self.points(), schedule: clock.schedule)
        state.toggleExplicit(); #expect(state.isPinned && state.isPresented)
        state.inlineHover(false); state.detailHover(false); clock.advance(10)
        #expect(state.isPresented)
        state.toggleExplicit(); #expect(!state.isPresented && !state.isPinned)
        state.replacePoints([]); state.toggleExplicit(); state.inlineHover(true); clock.advance(10)
        #expect(!state.isPresented)
    }
    @Test
    func selectionCoversCalendarWindowTiesKeyboardAndUpdates() {
        var points = self.points(); points[2] = .init(date: points[2].date, tokens: 100000)
        points[29] = .init(date: points[29].date, tokens: 100000)
        let state = AIUsageTrendPopoverState(points: points)
        #expect(state.peakIndex == 29 && state.selectedPoint == points[29])
        for index in points.indices { state.select(index); #expect(state.selectedPoint == points[index]) }
        state.moveSelection(1); #expect(state.activeIndex == 30)
        state.moveSelection(-100); #expect(state.activeIndex == 0)
        state.clearSelection(); #expect(state.selectedIndex == 29)
        state.select(4); state.detailHover(false); #expect(state.activeIndex == nil)
        state.select(4); points[4] = .init(date: points[4].date, tokens: 200000)
        state.replacePoints(points); #expect(state.activeIndex == nil && state.selectedIndex == 4)
        state.toggleExplicit(); state.replacePoints([])
        #expect(!state.isPresented && state.selectedPoint == nil)
    }
    @Test
    func formattingPreservesExactCountsAndDifferentChartFloors() {
        #expect(AIUsageTrendFormat.barHeight(0, peak: 1000, height: 76, floor: 0.06) == 2)
        #expect(AIUsageTrendFormat.barHeight(1, peak: 1000, height: 76, floor: 0.06) == 76 * 0.06)
        #expect(AIUsageTrendFormat.barHeight(1, peak: 1000, height: 18, floor: 0.18) == 18 * 0.18)
        #expect(AIUsageTrendFormat.barHeight(1000, peak: 1000, height: 76, floor: 0.06) == 76)
        let large = AIUsageDailyPoint(date: self.points()[0].date, tokens: Int.max)
        #expect(AIUsageTrendFormat.exact(large).contains(Int.max.formatted()))
        #expect(!AIUsageTrendFormat.readout(large).isEmpty)
        #expect(AIUsageTrendFormat.source(.codex).contains("Codex"))
        #expect(AIUsageTrendFormat.source(.claude).contains("Claude"))
    }
    @Test
    func renderDetailAt340PointsInBothThemes() throws {
        let state = AIUsageTrendPopoverState(points: self.points())
        let output = ProcessInfo.processInfo.environment["MIMIC_TREND_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for mode in ["peak", "day", "large"] {
                if mode == "day" { state.select(7) }
                if mode == "large" { state.replacePoints(self.points().map { .init(date: $0.date, tokens: Int.max) }); state.select(7) }
                let view = NSHostingView(rootView: AIUsageTrendDetail(provider: .codex, state: state).background(Color(nsColor: .windowBackgroundColor)))
                view.appearance = NSAppearance(named: name)
                view.frame = NSRect(x: 0, y: 0, width: 340, height: view.fittingSize.height); view.layoutSubtreeIfNeeded()
                #expect(view.fittingSize.width == 340 && view.fittingSize.height < 240)
                if let output {
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("trend-" + mode + "-" + name.rawValue + ".png"))
                }
            }
            state.replacePoints(self.points())
        }
    }
    @Test
    func nativeWindowOwnershipEscapeAndEdgePlacement() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        for origin in [NSPoint(x: screen.visibleFrame.minX + 4, y: screen.visibleFrame.minY + 4), NSPoint(x: screen.visibleFrame.maxX - 170, y: screen.visibleFrame.maxY - 60)] {
            let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 160, height: 50)), styleMask: [.borderless], backing: .buffered, defer: false)
            let anchor = NSView(frame: NSRect(x: 5, y: 5, width: 150, height: 18)); window.contentView?.addSubview(anchor)
            let state = AIUsageTrendPopoverState(points: self.points())
            let controller = AIUsageTrendPopoverController(provider: .codex, state: state); controller.attach(anchor)
            window.orderFront(nil)
            defer { controller.dismiss(); window.orderOut(nil) }
            state.toggleExplicit()
            let detail = try #require(controller.detailWindow)
            #expect(AIUsageTrendPopoverController.owns(detail))
            #expect(!AIUsageTrendPopoverController.owns(window))
            #expect(screen.visibleFrame.contains(detail.frame))
            let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: detail.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
            let peak = try #require(state.selectedIndex)
            #expect(AIUsageTrendPopoverController.handleKey(arrow) && state.selectedIndex == peak - 1)
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: detail.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
            #expect(AIUsageTrendPopoverController.handleKey(escape))
            #expect(!state.isPresented && !AIUsageTrendPopoverController.owns(detail) && window.isVisible)
            #expect(!AIUsageTrendPopoverController.handleKey(escape))
            state.toggleExplicit(); AIUsageTrendPopoverController.dismissAll(); window.orderOut(nil)
            #expect(!state.isPresented && !state.overInline && !state.isPinned)
            window.orderFront(nil); #expect(!state.isPresented)
        }
    }
    @Test
    func anchorTeardownClosesImmediatelyAndDoesNotInterceptClicks() async throws {
        _ = NSApplication.shared
        let clock = TrendHoverClock(), state = AIUsageTrendPopoverState(points: self.points(), schedule: clock.schedule)
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 180, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        let anchor = AIUsageTrendAnchorView(frame: NSRect(x: 10, y: 10, width: 150, height: 18))
        #expect(anchor.hitTest(NSPoint(x: 20, y: 15)) == nil)
        window.contentView?.addSubview(anchor); window.orderFront(nil)
        let controller = AIUsageTrendPopoverController(provider: .codex, state: state); controller.attach(anchor)
        defer { controller.dismiss(); window.orderOut(nil) }
        state.inlineHover(true); state.toggleExplicit(); state.select(7)
        let detail = try #require(controller.detailWindow)
        controller.detach()
        state.detailHover(false); state.inlineHover(true); state.select(8); state.clearSelection()
        #expect(state.activeIndex == 7) // Late native callbacks cannot invalidate a dying SwiftUI graph.
        #expect(!AIUsageTrendPopoverController.owns(detail))
        clock.advance(10)
        for _ in 0..<10 where state.isPresented { await Task.yield() }
        #expect(!state.isPresented && !state.isPinned && !state.overInline)
    }
    @Test
    func switchingProviderClosesOnlyOwnedDetails() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 180, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 10, y: 10, width: 150, height: 18)); window.contentView?.addSubview(anchor)
        let codex = AIUsageTrendPopoverState(points: self.points()), claude = AIUsageTrendPopoverState(points: self.points())
        let first = AIUsageTrendPopoverController(provider: .codex, state: codex), second = AIUsageTrendPopoverController(provider: .claude, state: claude)
        first.attach(anchor); second.attach(anchor); window.orderFront(nil)
        defer { AIUsageTrendPopoverController.dismissAll(); window.orderOut(nil) }
        codex.toggleExplicit(); #expect(codex.isPresented)
        claude.toggleExplicit(); #expect(!codex.isPresented && claude.isPresented)
        AIUsageTrendPopoverController.dismiss(for: .codex); #expect(claude.isPresented)
        AIUsageTrendPopoverController.dismiss(for: .claude); #expect(!claude.isPresented)
    }
}
