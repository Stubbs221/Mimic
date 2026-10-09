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
        let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { _ in .init(block: .ci) }, click: { _ in }, lift: { _, _, _, _ in }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
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
    /// Real compact Bootstrap controls must keep their mouse events without launching a task.
    @Test func compactBootstrapControlsKeepPressesInBothLayouts() async throws {
        let suite = "BootstrapPress-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        model.aiUsage.stop()
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let project = ProjectContext(path: directory.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        func markers(in node: NSView) -> [PanelControlRegion.MarkerView] {
            (node as? PanelControlRegion.MarkerView).map { [$0] } ?? node.subviews.flatMap { markers(in: $0) }
        }
        for (mode, width) in [(BootstrapCardMode.mini, CGFloat(214)), (.full, 464)] {
            for state in ["ready", "running", "blocked"] {
                let running = state != "ready"
                model.records = []; model.launchState = .idle
                if running {
                    var record = TaskRecord(action: .bootstrap, project: project); record.status = .running
                    model.records = [record]
                    if state == "blocked" { record.status = .queued; model.records = [record]; model.launchState = .blockedByXcode(record.id) }
                }
                for appearance in [PanelAppearance.legacy, .tileGrid] {
                    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let root = NSHostingView(rootView: BootstrapCard(model: model, mode: mode).environment(\.mimicPanelAppearance, appearance).frame(width: width, height: 160, alignment: .topLeading))
                    window.contentView = root
                    var clicks = 0
                    let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { _ in .init(block: .bootstrap) }, click: { _ in clicks += 1 }, lift: { _, _, _, _ in }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
                    let view = PanelDragBridge.TrackingView(callbacks: bridge)
                    view.frame = root.bounds; root.addSubview(view); window.orderFront(nil)
                    defer { view.stop(); window.close() }
                    try await Task.sleep(for: .milliseconds(50)); root.layoutSubtreeIfNeeded()
                    let controls = markers(in: root).filter { $0.bounds.height > 0 && $0.bounds.height <= 32 }
                    #expect(controls.count == (state == "running" ? 1 : 2), "\(mode), \(state), \(appearance)")
                    for control in controls {
                        let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                            #expect(view.receive(event) === event)
                        }
                    }
                    #expect(clicks == 0)
                }
            }
        }
    }
    @Test func nativeBridgeLeavesSwiftUILaunchButtonUntouched() async throws {
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: CILaunchButton(kind: .uiTests, action: {}).frame(width: 400, height: 240))
        window.contentView = root
        let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { _ in .init(block: .ci) }, click: { _ in }, lift: { _, _, _, _ in }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
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
    @Test func tallHeaderOwnsItsWholeButtonButNotAdjacentControls() async throws {
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: VStack {
            Button {} label: { Text("Длинный заголовок\\nВторая строка").frame(width: 360, height: 80) }
                .buttonStyle(.plain).background(PanelDragHeaderRegion())
            Button("Отдельное действие") {}.background(PanelControlRegion())
        }.frame(width: 400, height: 180))
        window.contentView = root
        var clicks = 0
        let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { _ in .init(block: .utils) }, click: { _ in clicks += 1 }, lift: { _, _, _, _ in }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
        let view = PanelDragBridge.TrackingView(callbacks: bridge); view.frame = root.bounds; root.addSubview(view)
        window.orderFront(nil); root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        defer { view.stop(); window.close() }
        func marker<T: NSView>(_ type: T.Type, in node: NSView) -> T? {
            if let result = node as? T { return result }
            return node.subviews.compactMap { marker(type, in: $0) }.first
        }
        let header = try #require(marker(PanelDragHeaderRegion.MarkerView.self, in: root))
        let control = try #require(marker(PanelControlRegion.MarkerView.self, in: root))
        let headerPoint = header.convert(CGPoint(x: header.bounds.midX, y: header.bounds.maxY - 4), to: nil)
        let controlPoint = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let headerEvent = try #require(NSEvent.mouseEvent(with: type, location: headerPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            #expect(view.receive(headerEvent) == nil)
            let controlEvent = try #require(NSEvent.mouseEvent(with: type, location: controlPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
            #expect(view.receive(controlEvent) === controlEvent)
        }
        #expect(clicks == 1)
    }
    /// Every card shares a protected body and an explicit draggable disclosure, including new catalogue entries.
    @Test func everyCardProtectsHostedContentAndKeepsHeaderDragging() async throws {
        let suite = "CardInput-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        model.aiUsage.stop()
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        func markers<T: NSView>(_ type: T.Type, in node: NSView) -> [T] {
            (node as? T).map { [$0] } ?? node.subviews.flatMap { markers(type, in: $0) }
        }
        for block in PanelBlockKind.catalog(for: .desktop) {
            for presentation in ["mini", "full", "expanded", "editing"] {
                let width: CGFloat = presentation == "mini" ? 214 : 464
                let row = PanelLayoutRow(id: UUID(), slots: presentation == "mini" ? [block, nil] : [block])
                model.panelLayout.begin()
                model.panelLayout.edit { $0 = PanelLayout(rows: [row]) }
                if presentation != "editing" { model.panelLayout.finish() }
                model.panelLayout.expanded = presentation == "expanded" ? block : nil
                for appearance in PanelAppearance.allCases {
                    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let grid = PanelGrid(model: model, layout: model.panelLayout)
                    let root = NSHostingView(rootView: grid.card(block, row: row.id).environment(\.mimicPanelAppearance, appearance).frame(width: width))
                    window.contentView = root
                    var clicks = 0, lifts = 0
                    let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { _ in .init(block: block) }, click: { _ in clicks += 1 }, lift: { _, _, _, _ in lifts += 1 }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
                    let view = PanelDragBridge.TrackingView(callbacks: bridge)
                    view.frame = root.bounds; root.addSubview(view); window.orderFront(nil)
                    defer { view.stop(); window.close() }
                    try await Task.sleep(for: .milliseconds(30)); root.layoutSubtreeIfNeeded()
                    let header = try #require(markers(PanelDragHeaderRegion.MarkerView.self, in: root).first)
                    let regions = markers(PanelControlRegion.MarkerView.self, in: root)
                    let surface = try #require(presentation == "editing" ? regions.first { $0.bounds.width < 60 && $0.bounds.height > 0 } : regions.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
                    let headerPoint = header.convert(CGPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil)
                    let bodyY = presentation == "editing" ? surface.bounds.midY : surface.isFlipped ? surface.bounds.maxY - 2 : surface.bounds.minY + 2
                    let bodyPoint = surface.convert(CGPoint(x: surface.bounds.midX, y: bodyY), to: nil)
                    #expect(!PanelDragHeaderRegion.MarkerView.contains(bodyPoint, in: root), "\(block), \(presentation), \(appearance)")
                    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    }
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                        let input = try event(type, bodyPoint)
                        #expect(view.receive(input) === input, "\(block), \(presentation), \(appearance)")
                    }
                    #expect(clicks == 0 && lifts == 0)
                    #expect(view.receive(try event(.leftMouseDown, headerPoint)) == nil)
                    #expect(view.receive(try event(.leftMouseUp, headerPoint)) == nil)
                    #expect(clicks == 1)
                }
            }
        }
    }
    @Test func stationaryLiftStartsHalfSecondDwellAndAllowsFiftyPoints() {
        var resize = PanelDragResize(size: .mini, pointer: .zero)
        let changed1 = resize.update(zone: .center, pointer: .zero, time: 10); #expect(!changed1)
        #expect(resize.pending == .center)
        let changed2 = resize.update(zone: .center, pointer: CGPoint(x: 30, y: 40), time: 10.499); #expect(!changed2)
        #expect(resize.progress > 0.99)
        let changed3 = resize.update(zone: .center, pointer: CGPoint(x: 30, y: 40), time: 10.5); #expect(changed3)
        #expect(resize.size == .full && resize.pending == nil)
        let changed4 = resize.update(zone: .right, pointer: .zero, time: 11); #expect(!changed4)
        let changed5 = resize.update(zone: .right, pointer: CGPoint(x: 50.1, y: 0), time: 11.49); #expect(!changed5)
        #expect(resize.progress == 0)
        let changed6 = resize.update(zone: .right, pointer: CGPoint(x: 50.1, y: 0), time: 11.989); #expect(!changed6)
        let changed7 = resize.update(zone: .right, pointer: CGPoint(x: 50.1, y: 0), time: 11.99); #expect(changed7)
        #expect(resize.size == .mini)
    }
    @Test func changingZonesOrLeavingNeverAccumulatesDwell() {
        var resize = PanelDragResize(size: .full, pointer: .zero)
        let changed8 = resize.update(zone: .left, pointer: .zero, time: 0); #expect(!changed8)
        let changed9 = resize.update(zone: .right, pointer: .zero, time: 0.4); #expect(!changed9)
        let changed10 = resize.update(zone: nil, pointer: .zero, time: 0.8); #expect(!changed10)
        #expect(resize.pending == nil && resize.progress == 0)
        let changed11 = resize.update(zone: .right, pointer: .zero, time: 1); #expect(!changed11)
        let changed12 = resize.update(zone: .right, pointer: .zero, time: 1.499); #expect(!changed12)
        let changed13 = resize.update(zone: .right, pointer: .zero, time: 1.5); #expect(changed13)
        #expect(PanelDragResize.Zone.resolve(x: 30, width: 100) == .left)
        #expect(PanelDragResize.Zone.resolve(x: 70, width: 100) == .right)
        #expect(PanelDragResize.Zone.resolve(x: 30.1, width: 100) == .center)
        #expect(PanelDragResize.Zone.resolve(x: -1, width: 100) == nil)
    }
    @Test func continuousTravelResetsDwellAndMorphRetargetsPresentedSize() {
        var resize = PanelDragResize(size: .mini, pointer: .zero)
        for tick in 0..<10 {
            let changed14 = resize.update(zone: .center, pointer: CGPoint(x: tick * 30, y: 0), time: Double(tick) * 0.2); #expect(!changed14)
        }
        #expect(resize.size == .mini)
        let morph = PanelDragMorph(from: CGSize(width: 488, height: 160), to: CGSize(width: 238, height: 160), started: 1, duration: 0.2)
        #expect(morph.scale(at: 1).width == 488.0 / 238)
        #expect(abs(morph.scale(at: 1.2).width - 1) < 0.000001)
        let current = morph.scale(at: 1.1)
        let reverse = PanelDragMorph(from: CGSize(width: 238 * current.width, height: 160), to: CGSize(width: 488, height: 160), started: 1.1, duration: 0.2)
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
        gesture.move(to: CGPoint(x: 12, y: 0)); #expect(gesture.phase == .waiting)
        gesture.move(to: CGPoint(x: 12.1, y: 0)); let movedActivation = gesture.activate(time: 1, pressureStage: 2); #expect(!movedActivation)
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
        let bridge = PanelDragBridge(cancellationID: 0, enabled: true, candidate: { point in .init(block: .utils) }, click: { _ in clicks += 1 }, lift: { _, _, _, _ in lifts += 1 }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {})
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
        // Expanded hosted content must retain presses even when accessibility exposes no control.
        let content = PanelControlRegion.MarkerView(frame: CGRect(x: 200, y: 40, width: 180, height: 140))
        root.addSubview(content)
        let contentDown = try event(.leftMouseDown, surfacePoint), contentUp = try event(.leftMouseUp, surfacePoint)
        #expect(view.receive(contentDown) === contentDown)
        #expect(view.receive(contentUp) === contentUp)
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
        #expect(cells[1].frame.width == 238); #expect(cells[1].frame.height == 160)
        #expect(PanelDragGeometry.target(point: CGPoint(x: 300, y: 200), block: .ci, layout: layout, cells: cells) == .slot(row: layout.rows[1].id, slot: 1))
        #expect(PanelDragGeometry.target(point: CGPoint(x: 20, y: 100), block: .ci, layout: layout, cells: cells) == .boundary(before: layout.rows[1].id))
        #expect(PanelDragGeometry.target(point: CGPoint(x: -1, y: 10), block: .ci, layout: layout, cells: cells) == nil)
        #expect(PanelDragGeometry.scrollSpeed(y: 24, height: 600) == -200)
        #expect(PanelDragGeometry.scrollSpeed(y: 576, height: 600) == 200)
        #expect(PanelDragGeometry.scrollSpeed(y: 300, height: 600) == 0)
        #expect(PanelDragGeometry.scrollSpeed(y: 650, height: 600) == 400)
    }
    @Test func currentPlaceholderRetainsTargetAfterReflowAndResolvesNewSize() throws {
        var layout = PanelLayout.standard(for: .desktop)
        let target = PanelInsertionTarget.slot(row: layout.rows[2].id, slot: 1)
        try layout.insert(.utils, at: target)
        let cells = PanelDragGeometry.compactCells(layout: layout, width: 488)
        let source = try #require(cells.first { $0.row == layout.rows[2].id && $0.slot == 1 })
        let point = CGPoint(x: source.frame.minX - 11, y: source.frame.midY)
        #expect(PanelDragGeometry.retainedTarget(point: point, block: .utils, layout: layout, cells: cells, current: target, size: .mini, resized: false) == target)
        let full = PanelDragGeometry.retainedTarget(point: point, block: .utils, layout: layout, cells: cells, current: target, size: .full, resized: true)
        #expect(full == .boundary(before: source.row))
        try layout.insert(.utils, at: full!, size: .full)
        let resized = PanelDragGeometry.compactCells(layout: layout, width: 488)
        let row = try #require(layout.rows.first { $0.blocks.contains(.utils) })
        #expect(resized.first { $0.row == row.id }?.frame.width == 488)
    }
    @Test func unchangedGeometryDoesNotPublishPerPointerFrame() async {
        let store = PanelFrameStore()
        let frames = ["utils": CGRect(x: 0, y: 172, width: 238, height: 160)]
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        for _ in 0..<100 { store.record(frames) }
        #expect(store.logical == frames)
        await Task.yield()
        #expect(store.snapshot == frames && publications == 1)
        for _ in 0..<100 { store.record(frames) }
        await Task.yield()
        #expect(publications == 1)
        withExtendedLifetime(observation) {}
    }
    @Test func geometryEventsCarryCommittedFramesForStationaryDragReactions() async {
        let store = PanelFrameStore()
        let first = ["utils": CGRect(x: 0, y: 172, width: 238, height: 160)]
        let resized = ["utils": CGRect(x: 0, y: 172, width: 488, height: 160)]
        var events: [PanelFrameStore.Change] = []
        let observation = store.changes.sink { change in
            #expect(store.snapshot == change.next && store.logical == change.next)
            events.append(change)
        }
        store.record(first); await Task.yield()
        store.record(resized); await Task.yield()
        #expect(events.count == 2)
        #expect(events.first?.old.isEmpty == true && events.last?.old == first && events.last?.next == resized)
        withExtendedLifetime(observation) {}
    }
}
