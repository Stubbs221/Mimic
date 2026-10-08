// Created by Василий Маслов on 06.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct PanelGridTests {
    // MARK: - Approved B2 tile management

    @Test func directRemovalAddAndEscapePreserveExecutionDraftsAndCodexLayout() throws {
        let suite = "PanelB2Placement-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults), layout = model.panelLayout
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var task = TaskRecord(action: .bootstrap, project: .init(path: root.path)); task.status = .running
        model.records = [task]; model.selectedTaskID = task.id; model.generatorName = "СохранённыйЧерновик"
        let terminal = model.bootstrapTerminal(for: task), codex = layout.store.load(.codex), original = layout.saved
        layout.toggleRemoval(); layout.beginDrag(.bootstrap)
        #expect(layout.removing && layout.dragging == nil)
        #expect(layout.cancelPresentation() && !layout.removing && layout.saved == original)
        #expect(!layout.cancelPresentation() && !layout.remove(.bootstrap))
        layout.toggleRemoval(); #expect(layout.remove(.bootstrap))
        #expect(!layout.removing && !layout.saved.blocks.contains(.bootstrap) && layout.saved.revision == original.revision + 1)
        #expect(layout.availableBlocks.contains(.bootstrap))
        #expect(model.records.first?.status == .running && model.selectedTaskID == task.id)
        #expect(model.generatorName == "СохранённыйЧерновик" && model.bootstrapTerminal(for: task) === terminal)
        #expect(layout.store.load(.codex) == codex)
        layout.toggleCatalog(); #expect(layout.catalogVisible && layout.add(.bootstrap) && !layout.catalogVisible)
        let restored = layout.saved
        #expect(restored.blocks.contains(.bootstrap) && restored.revision == original.revision + 2)
        #expect(!layout.add(.bootstrap) && layout.saved == restored)
        #expect(PanelLayoutController(defaults: defaults).saved == restored)
        for block in restored.blocks { layout.toggleRemoval(); #expect(layout.remove(block)) }
        layout.toggleRemoval(); #expect(layout.saved.blocks.isEmpty && !layout.removing)
        #expect(Set(layout.availableBlocks) == Set(PanelBlockKind.catalog(for: .desktop)))
    }

    @Test func directTileSelectionsRejectStaleRevisionAndRetainNewerLayout() throws {
        let suite = "PanelB2Conflict-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PanelLayoutController(defaults: defaults), second = PanelLayoutController(defaults: defaults)
        second.toggleRemoval(); #expect(second.remove(.ci))
        first.toggleRemoval(); #expect(!first.remove(.bootstrap))
        #expect(first.saved == second.saved && first.saved.blocks.contains(.bootstrap) && !first.message.isEmpty)
        #expect(first.cancelPresentation())
        first.toggleCatalog(); second.toggleCatalog(); #expect(second.add(.ci))
        #expect(!first.add(.ci) && first.saved == second.saved && !first.message.isEmpty)
    }

    /// Real native snapshots exercise bounded chrome and overlays with disposable data and no admitted work.
    @Test func b2ChromeRendersLongBranchEmptyCatalogRemovalAndLargeText() async throws {
        let suite = "PanelB2Renders-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).appendingPathComponent("ios3")
        let model = TaskCoordinator(directory: root, defaults: defaults), layout = model.panelLayout
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        model.projects = [.init(path: root.path, branch: "feature/vmaslov/IOS-20658-another-one-svpk-nav-issue")]; model.selectedProjectPath = root.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        model.appearance.select(.tileGrid); model.motionSettings.reduceMotionOverride = true; model.aiUsage.stop()
        let output = URL(fileURLWithPath: "/private/tmp/MimicChromeB2-native")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let initialBlocks = Set(layout.saved.blocks)
        for state in ["idle", "draft", "active", "removal", "catalog-all", "branch", "catalog", "empty", "large", "extra-large", "diagnostics-large", "catalog-large", "branch-large", "unavailable"] {
            layout.cancelPresentation(); layout.cancel(); model.expandedSection = nil; model.records = []
            model.frameDiagnostics.enabled = state == "diagnostics-large"
            if state == "branch" {
                for block in layout.saved.blocks where !initialBlocks.contains(block) { layout.toggleRemoval(); #expect(layout.remove(block)) }
            }
            var scale: CGFloat = 1
            if state == "draft" { layout.begin() }
            if state == "active" {
                var task = TaskRecord(action: .bootstrap, project: model.project!); task.status = .running; task.startedAt = Date().addingTimeInterval(-72); model.records = [task]
            }
            if state == "removal" { layout.toggleRemoval() }
            if state == "catalog-all" { for block in layout.availableBlocks { #expect(layout.add(block)) }; layout.toggleCatalog(); #expect(layout.availableBlocks.isEmpty) }
            if state == "branch" { model.expandedSection = .branches }
            if state == "catalog" { layout.toggleRemoval(); #expect(layout.remove(.ci)); layout.toggleCatalog() }
            if state == "empty" { for block in layout.saved.blocks { layout.toggleRemoval(); #expect(layout.remove(block)) } }
            if state == "large" || state == "extra-large" || state == "diagnostics-large" {
                for block in layout.availableBlocks { #expect(layout.add(block)) }
                scale = state == "large" ? 1.4 : 2
            }
            if state == "catalog-large" { scale = 2; layout.toggleRemoval(); #expect(layout.remove(.ci)); layout.toggleCatalog() }
            if state == "branch-large" { scale = 2; model.expandedSection = .branches }
            if state == "branch" || state == "branch-large" {
                model.localBranches = [LocalBranch(name: model.project!.branch)] + (1...40).map { LocalBranch(name: "feature/разработка-очень-длинного-названия-ветки-\($0)") }
            }
            if state == "unavailable" { model.projects = []; model.selectedProjectPath = "" }
            #expect(MimicFooter(model: model).hasActivity == (state == "active"))
            for scheme in [ColorScheme.light, .dark] {
                // Closing each real window dismisses its transient mode; reopen it for the next theme.
                if state == "removal", !layout.removing { layout.toggleRemoval() }
                if state.hasPrefix("catalog"), !layout.catalogVisible { layout.toggleCatalog() }
                let host = NSHostingView(rootView: MimicPanel(model: model).frame(height: 820).modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.colorScheme, scheme).environment(\.mimicTextScale, scale))
                let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 560, height: 820), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); window.contentView = host; window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                #expect(layout.catalogVisible == state.hasPrefix("catalog"))
                #expect(layout.removing == (state == "removal"))
                #expect(abs(host.fittingSize.width - 560) < 1)
                let header = NSHostingView(rootView: TileGridIdentity(model: model).frame(width: 528).modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.mimicTextScale, scale))
                #expect(abs(header.fittingSize.width - 528) < 1 && header.fittingSize.height <= max(32, 24 * scale) + 1)
                let footer = NSHostingView(rootView: MimicFooter(model: model).frame(width: 560).modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.mimicTextScale, scale))
                #expect(footer.fittingSize.width == 560 && footer.fittingSize.height < (state == "active" ? 100 : 85))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(state + (scheme == .dark ? "-dark.png" : "-light.png")))
                window.contentView = nil; window.close()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

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
