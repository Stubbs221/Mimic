//
//  NativeR1IntegrationTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

/// Production views with disposable data. No task is admitted and no simulator is connected.
@Suite(.serialized) @MainActor struct NativeR1IntegrationTests {
    @Test(arguments: [PanelAppearance.windows95, .windowsXP])
    func nativeControlsCancelAndActivateOnRelease(appearance: PanelAppearance) throws {
        let control = NativeRetroControl(frame: CGRect(x: 0, y: 0, width: 100, height: 23))
        control.appearanceChoice = appearance
        var count = 0; control.actionBlock = { count += 1 }
        control.beginPress(); #expect(control.pressed && count == 0)
        control.movePress(inside: false); #expect(!control.pressed)
        control.movePress(inside: true); control.releasePress(inside: true); #expect(count == 1)
        control.beginPress(); control.releasePress(inside: false); #expect(count == 1)
        func key(_ code: UInt16, type: NSEvent.EventType, repeated: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, characters: code == 49 ? " " : "\r",
                                         charactersIgnoringModifiers: code == 49 ? " " : "\r", isARepeat: repeated, keyCode: code))
        }
        control.keyDown(with: try key(49, type: .keyDown)); #expect(count == 1 && control.pressed)
        control.keyDown(with: try key(49, type: .keyDown, repeated: true)); #expect(count == 1)
        control.keyUp(with: try key(49, type: .keyUp)); #expect(count == 2 && !control.pressed)
        control.keyDown(with: try key(36, type: .keyDown)); #expect(count == 3)
        control.keyDown(with: try key(49, type: .keyDown)); control.keyDown(with: try key(53, type: .keyDown))
        control.keyUp(with: try key(49, type: .keyUp)); #expect(count == 3)
        control.beginPress(); control.isEnabled = false; control.releasePress(inside: true)
        #expect(count == 3 && !control.pressed && !control.accessibilityPerformPress())
        control.isEnabled = true; control.beginPress(); _ = control.resignFirstResponder(); control.releasePress(inside: true)
        #expect(count == 3)
        control.beginPress(); control.appearanceChoice = appearance == .windows95 ? .windowsXP : .windows95
        control.releasePress(inside: true); #expect(count == 3)
        let policy = MimicMotionPolicy(source: .pointer, reduceMotion: false, retro: true)
        #expect(!policy.moves && policy.duration(.geometry) == 0 && policy.duration(.feedback) == 0 && policy.duration(.progress) == 0)
    }
    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    }
    /// Measures draw submission of the retained production view, not OS-presented frames or app cold start.
    @Test func panelDrawSubmissionMeasurements() async throws {
        let suite = "NativeR1Timing-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        model.aiUsage.stop(); model.motionSettings.reduceMotionOverride = true
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        model.projects = [.init(path: directory.path, branch: "feature/native-r1")]; model.selectedProjectPath = directory.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: directory)
        var results: [[String: Any]] = []
        for appearance in PanelAppearance.allCases {
            model.appearance.select(appearance)
            let start = ProcessInfo.processInfo.systemUptime
            let host = NSHostingView(rootView: MimicPanel(model: model).frame(height: 720).modifier(MimicAppearanceRoot(store: model.appearance)))
            let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: appearance.panelWidth, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let initial = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try await settle(host)
            var warm: [Double] = []
            for _ in 0..<20 {
                window.orderOut(nil); try await Task.sleep(for: .milliseconds(20))
                let start = ProcessInfo.processInfo.systemUptime
                window.orderFront(nil); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                warm.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            let ordered = warm.sorted()
            results.append(["appearance": appearance.rawValue, "initialHostAndDrawSubmissionMS": initial,
                            "warmSamplesMS": warm, "warmMedianMS": ordered[10], "warmP95MS": ordered[18]])
            window.contentView = nil; window.close()
        }
        let report: [String: Any] = ["author": "Василий Маслов", "date": "13.10.2026", "configuration": "Debug native production views, disposable model, no tasks, 20 retained warm opens/theme",
                                    "scope": "Draw submission; not presented frame, cold app startup, or live workload. Initial samples share one process/font cache.", "results": results]
        let path = ProcessInfo.processInfo.environment["MIMIC_R1_MEASUREMENTS_PATH"] ?? "/private/tmp/MimicNativeR1Integration-20261013/measurements.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
    @Test func sharedSelectionRetainsTerminalDraftAndBothLayouts() async throws {
        let suite = "NativeR1-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        model.aiUsage.stop(); model.motionSettings.reduceMotionOverride = true
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        model.projects = [.init(path: directory.path, branch: "feature/infrastructure/dependency-registry-bootstrap-diagnostics")]
        model.selectedProjectPath = directory.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: directory)
        model.generatorName = "СохранённыйЧерновик"
        var record = TaskRecord(action: .bootstrap, project: model.project!)
        record.status = .succeeded; record.exitCode = 0; model.records = [record]
        let terminal = model.bootstrapTerminal(for: record), screen = terminal.view()
        screen.feed(text: "SAFE FIXTURE OUTPUT\r\nDependencies ready\r\n")
        let saved = model.panelLayout.saved
        let codex = model.panelLayout.store.load(.codex)
        let store = PanelFrameStore()
        let host = NSHostingView(rootView: PanelGrid(model: model, layout: model.panelLayout, frameStore: store)
            .frame(width: 488).modifier(MimicAppearanceRoot(store: model.appearance)))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 488, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        for choice in [PanelAppearance.windows95, .windowsXP, .legacy, .tileGrid] {
            model.panelLayout.beginDrag(.utils)
            model.appearance.select(choice)
            try await settle(host)
            #expect(model.appearance.selection == choice && model.codexAppearance.value.selection.rawValue == choice.rawValue)
            #expect(model.panelLayout.dragging == nil)
            #expect(model.panelLayout.saved == saved && model.panelLayout.draft == nil && model.panelLayout.store.load(.codex) == codex)
            #expect(model.generatorName == "СохранённыйЧерновик")
            #expect(model.bootstrapTerminal(for: record) === terminal && terminal.view() === screen)
            #expect(screen.window === window)
            #expect(String(decoding: screen.getTerminal().getBufferAsData(), as: UTF8.self).contains("SAFE"))
            #expect(store.logical.values.allSatisfy { $0.width.isFinite && $0.height.isFinite && $0.width > 0 })
        }
        #expect(PanelDesignTokens.shared.metrics["dragHoldMS"] == 180)
        #expect(PanelDesignTokens.shared.metrics["dragResizeMS"] == 250)
        model.panelLayout.begin(); let draft = model.panelLayout.draft
        model.appearance.select(.windowsXP); try await settle(host)
        #expect(model.panelLayout.draft == draft && model.panelLayout.saved == saved && model.panelLayout.store.load(.codex) == codex)
    }

    @Test func scrollbarTracksRealOverflowAndViewport() throws {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 800)); scroll.documentView = document
        let bar = NativeRetroScrollbar(scroll: scroll); scroll.addSubview(bar); bar.refresh()
        #expect(!bar.isHidden && bar.frame.width == 17 && bar.thumb.height >= 17)
        let top = bar.thumb.minY
        #expect(bar.accessibilityPerformIncrement())
        #expect(scroll.contentView.bounds.minY > 0 && bar.thumb.minY > top)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 700)); scroll.reflectScrolledClipView(scroll.contentView); bar.refresh()
        #expect(abs(bar.thumb.maxY - (bar.bounds.height - 17)) < 1)
        document.setFrameSize(CGSize(width: 200, height: 50)); bar.refresh()
        #expect(bar.isHidden)
    }

    @Test func nativeFieldEditorSelectionAndCompositionSurviveSharedThemeChange() async throws {
        _ = NSApplication.shared
        let suite = "NativeR1Editor-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let shared = CodexPanelAppearanceStore(directory: directory, previous: .tileGrid)
        let store = PanelAppearanceStore(defaults: defaults); store.connect(to: shared)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let host = NSHostingView(rootView: NativeR1EditorFixture().modifier(MimicAppearanceRoot(store: store)).frame(width: 440, height: 120))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 440, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        // XCTest's background application cannot become key; the production resolver uses NSApp.keyWindow.
        let continuity = NativeAppearanceContinuity(store: store, shared: shared, editingWindow: { window })
        defer { withExtendedLifetime(continuity) {} }
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        func field(_ view: NSView) -> NSTextField? {
            if let text = view as? NSTextField, text.isEditable { return text }
            return view.subviews.lazy.compactMap { field($0) }.first
        }
        let input = try #require(field(host)); window.makeFirstResponder(input)
        let editor = try #require(input.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 4))
        try shared.select(.windowsXP, expectedRevision: shared.value.revision)
        try await settle(host)
        #expect(window.firstResponder === editor && editor.selectedRange() == NSRange(location: 2, length: 4))
        #expect(field(host) === input)
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 2))
        let marked = editor.markedRange()
        #expect(editor.hasMarkedText())
        #expect(editor.isFieldEditor)
        try shared.select(.windows95, expectedRevision: shared.value.revision)
        try await settle(host)
        #expect(shared.value.selection == .windows95 && store.selection == .windowsXP)
        #expect(window.firstResponder === editor && editor.hasMarkedText() && editor.markedRange() == marked)
        editor.unmarkText(); try await settle(host)
        #expect(store.selection == .windows95 && field(host) === input && window.firstResponder === editor)
    }

    @Test func productionRetroPanelsRenderAtRealWidths() async throws {
        let suite = "NativeR1Render-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        model.aiUsage.stop(); model.motionSettings.reduceMotionOverride = true
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        model.projects = [.init(path: directory.appendingPathComponent("MobilePlatformInfrastructureCheckout").path, branch: "feature/infrastructure/dependency-registry-bootstrap-diagnostics")]
        model.selectedProjectPath = model.projects[0].path
        model.activeProfile = try Profile11Fixture.snapshot(directory: directory)
        let output = URL(fileURLWithPath: "/private/tmp/MimicNativeR1Integration-20261013/renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [PanelAppearance.windows95, .windowsXP, .tileGrid, .legacy] {
            model.appearance.select(appearance)
            for state in ["home", "expanded", "settings", "large"] {
                model.panelLayout.expanded = state == "expanded" ? .bootstrap : nil
                if state == "settings" { model.openSettings(group: .appearance, source: .keyboard) }
                else { model.returnHome(source: .keyboard) }
                let host = NSHostingView(rootView: MimicPanel(model: model).frame(height: 820)
                    .modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.mimicTextScale, state == "large" ? 1.4 : 1))
                let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: appearance.panelWidth, height: 820), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                try await settle(host)
                #expect(abs(host.fittingSize.width - appearance.panelWidth) < 1 && host.fittingSize.height.isFinite)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(appearance.rawValue + "-" + state + ".png"))
                window.contentView = nil; window.close()
            }
        }
    }
}

private struct NativeR1EditorFixture: View {
    @State private var value = "СохранённыйЧерновик"
    var body: some View { TextField("Имя", text: $value).textFieldStyle(.roundedBorder).mimicFont(.body).padding(16) }
}
