// Created by Василий Маслов on 06.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor struct PanelDragTests {
    @Test func nativeBridgeLeavesPipelineChevronUntouched() async throws {
        let pipeline = try JSONDecoder().decode(CIPipeline.self, from: Data(#"{"id":7,"status":"success","sha":"fixture","ref":"develop","web_url":"https://example.invalid/pipelines/7"}"#.utf8))
        let state = CIState { _ in "fixture" }
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: CIPipelineCard(state: state, entry: CIFeedEntry(pipeline: pipeline)).frame(width: 400))
        window.contentView = root
        let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { _ in .init(block: .ci, header: false) }, click: { _ in }, lift: { _, _, _, _ in }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
        let view = PanelDragBridge.TrackingView(callbacks: bridge)
        view.frame = root.bounds; root.addSubview(view); window.orderFront(nil)
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        defer { view.stop(); window.close() }
        func markers(in node: NSView) -> [PanelControlRegion.MarkerView] {
            (node as? PanelControlRegion.MarkerView).map { [$0] } ?? node.subviews.flatMap { markers(in: $0) }
        }
        // The disclosure spans the row; the browser link has only its intrinsic icon width.
        let disclosure = try #require(markers(in: root).first { $0.bounds.width > 300 })
        let point = disclosure.convert(CGPoint(x: disclosure.bounds.maxX - 6, y: disclosure.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            #expect(view.receive(event) === event)
        }
    }
    @Test func nativeBridgeLeavesSwiftUILaunchButtonUntouched() async throws {
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: CILaunchButton(kind: .uiTests, action: {}).frame(width: 400, height: 240))
        window.contentView = root
        let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { _ in .init(block: .ci, header: false) }, click: { _ in }, lift: { _, _, _, _ in }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
        let view = PanelDragBridge.TrackingView(callbacks: bridge)
        view.frame = root.bounds; root.addSubview(view); window.orderFront(nil)
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        defer { view.stop(); window.close() }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 200, y: 120), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(view.receive(down) === down)
        let background = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 60), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        let backgroundIsControl = PanelControlRegion.MarkerView.contains(background.locationInWindow, in: root)
        #expect(!backgroundIsControl)
        #expect(view.receive(background) == nil)
    }
    @Test func resizeRequiresMovementAndAContinuousStationarySecond() {
        var resize = PanelDragResize(size: .mini, pointer: .zero)
        let changed1 = resize.update(zone: .center, pointer: .zero, time: 5); #expect(!changed1)
        let changed2 = resize.update(zone: .center, pointer: .zero, time: 10); #expect(!changed2)
        let changed3 = resize.update(zone: .center, pointer: CGPoint(x: 20, y: 0), time: 10); #expect(!changed3)
        let changed4 = resize.update(zone: .center, pointer: CGPoint(x: 28, y: 0), time: 10.999); #expect(!changed4)
        let changed5 = resize.update(zone: .center, pointer: CGPoint(x: 28, y: 0), time: 11); #expect(changed5)
        #expect(resize.size == .full)
        let changed6 = resize.update(zone: .right, pointer: CGPoint(x: 80, y: 0), time: 12); #expect(!changed6)
        let changed7 = resize.update(zone: .right, pointer: CGPoint(x: 88.1, y: 0), time: 12.8); #expect(!changed7)
        let changed8 = resize.update(zone: .right, pointer: CGPoint(x: 88.1, y: 0), time: 13.7); #expect(!changed8)
        let changed9 = resize.update(zone: .right, pointer: CGPoint(x: 88.1, y: 0), time: 13.8); #expect(changed9)
        #expect(resize.size == .mini)
    }
    @Test func passingThroughZonesAndLeavingNeverAccumulatesDwell() {
        var resize = PanelDragResize(size: .mini, pointer: CGPoint(x: 90, y: 0))
        let changed10 = resize.update(zone: .center, pointer: CGPoint(x: 70, y: 0), time: 0); #expect(!changed10)
        let changed11 = resize.update(zone: .left, pointer: CGPoint(x: 10, y: 0), time: 0.8); #expect(!changed11)
        let changed12 = resize.update(zone: .center, pointer: CGPoint(x: 60, y: 0), time: 1); #expect(!changed12)
        let changed13 = resize.update(zone: nil, pointer: CGPoint(x: 60, y: 0), time: 1.8); #expect(!changed13)
        let changed14 = resize.update(zone: .center, pointer: CGPoint(x: 60, y: 0), time: 2); #expect(!changed14)
        let changed15 = resize.update(zone: .center, pointer: CGPoint(x: 60, y: 0), time: 2.999); #expect(!changed15)
        let changed16 = resize.update(zone: .center, pointer: CGPoint(x: 60, y: 0), time: 3); #expect(changed16)
        #expect(PanelDragResize.Zone.resolve(x: 20, width: 100) == .left)
        #expect(PanelDragResize.Zone.resolve(x: 80, width: 100) == .right)
        #expect(PanelDragResize.Zone.resolve(x: 20.1, width: 100) == .center)
        #expect(PanelDragResize.Zone.resolve(x: -1, width: 100) == nil)
    }
    @Test func movingWithinOneZoneResetsAndMorphRetargetsItsPresentedSize() {
        var resize = PanelDragResize(size: .mini, pointer: .zero)
        for tick in 0..<10 { let changed17 = resize.update(zone: .center, pointer: CGPoint(x: 20 + tick * 9, y: 0), time: Double(tick) * 0.2); #expect(!changed17) }
        #expect(resize.size == .mini)
        let morph = PanelDragMorph(from: CGSize(width: 488, height: 136), to: CGSize(width: 238, height: 112), started: 1, duration: 0.2)
        #expect(morph.scale(at: 1).width == 488.0 / 238)
        #expect(abs(morph.scale(at: 1.2).width - 1) < 0.000001)
        #expect(abs(morph.scale(at: 1.2).height - 1) < 0.000001)
        let current = morph.scale(at: 1.1)
        let reverse = PanelDragMorph(from: CGSize(width: 238 * current.width, height: 112 * current.height), to: CGSize(width: 488, height: 136), started: 1.1, duration: 0.2)
        #expect(abs(reverse.scale(at: 1.1).width * 488 - current.width * 238) < 0.001)
        #expect(PanelDragMorph(from: morph.from, to: morph.to, started: 1, duration: 0).scale(at: 1) == CGSize(width: 1, height: 1))
    }
    @Test func holdThresholdPressureAndReleaseHaveOneActivationOwner() {
        var gesture = PanelDragGesture()
        gesture.press(at: .zero, time: 10, eligible: true)
        let early = gesture.activate(time: 10.349), heldActivation = gesture.activate(time: 10.350)
        #expect(!early); #expect(heldActivation)
        let repeated = gesture.activate(time: 11, pressureStage: 2); #expect(!repeated)
        let held = gesture.release(); #expect(held.drop && !held.click)
        gesture.press(at: .zero, time: 20, eligible: true)
        let primary = gesture.activate(time: 20.01, pressureStage: 1); #expect(!primary)
        let deep = gesture.activate(time: 20.02, pressureStage: 2); #expect(deep)
        let tracking = gesture.move(to: CGPoint(x: 100, y: 60)); #expect(tracking)
        let release = gesture.release(); #expect(release.drop)
    }
    @Test func movementControlsAndEscapeCannotTurnIntoClicksOrLateHolds() {
        var gesture = PanelDragGesture()
        gesture.press(at: .zero, time: 0, eligible: false)
        let excluded = gesture.activate(time: 1, pressureStage: 2); #expect(!gesture.ownsPress); #expect(!excluded)
        gesture.press(at: .zero, time: 0, eligible: true)
        gesture.move(to: CGPoint(x: 8, y: 0)); #expect(gesture.phase == .waiting)
        gesture.move(to: CGPoint(x: 8.1, y: 0)); let movedActivation = gesture.activate(time: 1, pressureStage: 2); #expect(!movedActivation)
        let moved = gesture.release(); #expect(!moved.drop && !moved.click)
        gesture.press(at: .zero, time: 0, eligible: true); let short = gesture.release(); #expect(short.click)
        gesture.press(at: .zero, time: 0, eligible: true); gesture.activate(time: 1); gesture.cancel()
        let cancelled = gesture.release(); #expect(!cancelled.drop && !cancelled.click)
    }
    @Test func nativeBridgeLeavesControlsUntouchedAndSuppressesMovedHeaderClicks() throws {
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 240)); window.contentView = root
        var clicks = 0, lifts = 0
        let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { point in .init(block: .utils, header: point.y < 48) }, click: { _ in clicks += 1 }, lift: { _, _, _, _ in lifts += 1 }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
        let view = PanelDragBridge.TrackingView(callbacks: bridge); view.frame = root.bounds; root.addSubview(view)
        let button = NSButton(frame: CGRect(x: 20, y: 50, width: 120, height: 30)), field = NSTextField(frame: CGRect(x: 20, y: 100, width: 120, height: 30))
        root.addSubview(button); root.addSubview(field); window.orderFront(nil)
        defer { view.stop(); window.close() }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let buttonDown = try event(.leftMouseDown, CGPoint(x: 60, y: 65)), fieldDown = try event(.leftMouseDown, CGPoint(x: 60, y: 115))
        #expect(view.receive(buttonDown) === buttonDown); #expect(view.receive(fieldDown) === fieldDown)
        let headerDown = try event(.leftMouseDown, CGPoint(x: 50, y: 215)), headerUp = try event(.leftMouseUp, CGPoint(x: 50, y: 215))
        #expect(view.receive(headerDown) == nil); #expect(view.receive(headerUp) == nil); #expect(clicks == 1)
        let surfacePoint = CGPoint(x: 300, y: 120)
        _ = view.receive(try event(.leftMouseDown, surfacePoint)); _ = view.receive(try event(.leftMouseUp, surfacePoint))
        #expect(clicks == 2)
        _ = view.receive(headerDown); _ = view.receive(try event(.leftMouseDragged, CGPoint(x: 70, y: 215))); _ = view.receive(headerUp)
        #expect(clicks == 2); #expect(lifts == 0)
    }
    @Test func measuredCollapsedHeightsKeepDragTargetsAligned() {
        let layout = PanelLayout.standard(for: .desktop)
        let cells = PanelDragGeometry.compactCells(layout: layout, width: 488, rowHeights: [layout.rows[0].id: 300, layout.rows[1].id: 150])
        #expect(cells[0].frame.height == 300); #expect(cells[1].frame.minY == 312)
        #expect(cells[3].frame.minY == 474)
        #expect(PanelDragGeometry.target(point: CGPoint(x: 460, y: 320), block: .bootstrap, layout: layout, cells: cells, size: .mini) == .slot(row: layout.rows[1].id, slot: 1))
    }
    @Test func logicalTargetsRemainStableAndScrollSpeedIsBounded() {
        let layout = PanelLayout.standard(for: .desktop), cells = PanelDragGeometry.compactCells(layout: layout, width: 488)
        #expect(cells[1].frame.width == 238); #expect(cells[1].frame.height == 112)
        #expect(PanelDragGeometry.target(point: CGPoint(x: 300, y: 160), block: .ci, layout: layout, cells: cells) == .slot(row: layout.rows[1].id, slot: 1))
        #expect(PanelDragGeometry.target(point: CGPoint(x: 20, y: 100), block: .ci, layout: layout, cells: cells) == .boundary(before: layout.rows[1].id))
        #expect(PanelDragGeometry.target(point: CGPoint(x: -1, y: 10), block: .ci, layout: layout, cells: cells) == nil)
        #expect(PanelDragGeometry.scrollSpeed(y: 24, height: 600) == -200)
        #expect(PanelDragGeometry.scrollSpeed(y: 576, height: 600) == 200)
        #expect(PanelDragGeometry.scrollSpeed(y: 300, height: 600) == 0)
        #expect(PanelDragGeometry.scrollSpeed(y: 650, height: 600) == 400)
    }
}
