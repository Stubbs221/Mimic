// Created by Василий Маслов on 06.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct PanelGridTests {
    @Test func resizePreviewSameTargetSaveCancelDraftAndConflictAreTransactional() throws {
        let suite = "PanelDragResize-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PanelLayoutController(defaults: defaults), origin = controller.saved
        let target = PanelInsertionTarget.boundary(before: origin.rows[1].id)
        controller.beginDrag(.bootstrap)
        controller.previewDrag(at: target, size: .full, miniSlot: 1)
        controller.previewDrag(at: target, size: .mini, miniSlot: 1)
        #expect(controller.layout.rows.first?.slots == [nil, .bootstrap]); #expect(controller.saved == origin)
        controller.previewDrag(at: nil, size: .mini, miniSlot: 1)
        #expect(controller.layout.size(of: .bootstrap) == .mini)
        controller.previewDrag(at: target, size: .mini, miniSlot: 1)
        controller.previewDrag(at: target, size: .full, miniSlot: 1)
        #expect(controller.layout == origin)
        controller.finishDrag(); #expect(controller.saved.revision == 0)
        controller.beginDrag(.bootstrap); controller.previewDrag(at: target, size: .mini, miniSlot: 1); controller.finishDrag()
        #expect(controller.saved.size(of: .bootstrap) == .mini); #expect(controller.saved.revision == 1)
        let saved = controller.saved
        controller.begin(); controller.beginDrag(.bootstrap); controller.previewDrag(at: target, size: .full); controller.finishDrag()
        #expect(controller.saved == saved); #expect(controller.draft?.size(of: .bootstrap) == .full)
        controller.cancel(); #expect(controller.layout == saved)
        controller.beginDrag(.bootstrap); controller.previewDrag(at: target, size: .full); controller.cancelDrag()
        #expect(controller.layout == saved)
        controller.beginDrag(.bootstrap); controller.previewDrag(at: target, size: .full)
        var other = saved; other.remove(.ci)
        let latest = try controller.store.save(other, for: .desktop, expectedRevision: saved.revision)
        controller.finishDrag(); #expect(controller.saved == latest); #expect(!controller.message.isEmpty)
    }
    @Test func directReorderCancelSaveDraftAndConflictAreSeparateTransactions() throws {
        let suite = "PanelDirectDrag-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PanelLayoutController(defaults: defaults), original = controller.saved
        controller.expanded = .builds
        controller.beginDrag(.utils); controller.previewDrag(at: .slot(row: original.rows[2].id, slot: 1))
        #expect(controller.layout.rows != original.rows); #expect(controller.saved == original)
        #expect(controller.expanded == .builds); #expect(controller.cancelDrag()); #expect(controller.layout == original)
        controller.beginDrag(.utils); controller.previewDrag(at: .slot(row: original.rows[1].id, slot: 0)); controller.finishDrag()
        #expect(controller.saved.revision == 0)
        controller.beginDrag(.utils); controller.previewDrag(at: .slot(row: original.rows[2].id, slot: 1)); controller.finishDrag()
        #expect(controller.saved.revision == 1); #expect(controller.dragging == nil)
        let saved = controller.saved
        controller.begin(); controller.beginDrag(.ci); controller.previewDrag(at: .boundary(before: nil)); controller.finishDrag()
        #expect(controller.saved == saved); #expect(controller.draft?.rows != saved.rows)
        controller.cancel(); #expect(controller.layout == saved)
        controller.beginDrag(.builds); controller.previewDrag(at: .boundary(before: nil))
        var other = saved; other.remove(.ci)
        let latest = try controller.store.save(other, for: .desktop, expectedRevision: saved.revision)
        controller.finishDrag(); #expect(controller.saved == latest); #expect(!controller.message.isEmpty)
    }
    @Test func nativeEditingCancelSaveAndHiddenToolDoNotOwnExecution() throws {
        let suite = "PanelGrid-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = TaskCoordinator(directory: root, defaults: defaults), controller = model.panelLayout
        var running = TaskRecord(action: .format, project: .init(path: root.path)); running.status = .running; model.records = [running]
        model.generatorName = "СохранённыйЧерновик"; controller.open(.builds)
        let original = controller.saved
        controller.begin(); controller.edit { $0.remove(.builds); try $0.resize(.utils, to: .full) }
        #expect(!controller.layout.blocks.contains(.builds)); #expect(model.records[0].status == .running)
        controller.cancel(); #expect(controller.saved == original); #expect(model.generatorName == "СохранённыйЧерновик")
        model.generatorKind = .module; model.generatorName = "ДругойЧерновик"; model.generatorKind = .ui
        #expect(model.generatorName == "СохранённыйЧерновик")
        controller.begin(); controller.edit { $0.remove(.builds) }; controller.finish(); controller.open(.builds)
        #expect(!controller.saved.blocks.contains(.builds)); #expect(controller.expanded == .builds)
        #expect(PanelLayoutStore(defaults: defaults).load(.codex).blocks.contains(.builds))
        #expect(model.records[0].status == .running)
        model.records = []; model.stopAndExit()
    }
    @Test func nativeGridRendersAtAcceptedWidthsWithRightExpansion() async throws {
        let suite = "PanelGridRender-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.motionSettings.reduceMotionOverride = true
        for width in [360.0, 440.0, 480.0, 520.0] {
            for scheme in [ColorScheme.light, .dark] {
                model.panelLayout.expanded = .utils
                let renderer = ImageRenderer(content: PanelGrid(model: model, layout: model.panelLayout).padding(12).frame(width: width).environment(\.colorScheme, scheme))
                renderer.scale = 1
                let image = try #require(renderer.nsImage)
                #expect(abs(image.size.width - width) < 1); #expect(image.size.height.isFinite && image.size.height > 100)
            }
        }
        model.panelLayout.expanded = nil
        // Cache a real offscreen hosting view: ImageRenderer substitutes placeholders for AppKit controls.
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: PanelGrid(model: model, layout: model.panelLayout).padding(16).frame(width: 520).environment(\.colorScheme, scheme).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 520, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/Mimic-drag-native-520-" + (scheme == .dark ? "dark" : "light") + ".png"))
        }
    }
}
