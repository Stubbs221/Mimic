//
//  NativeR1SurfaceTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

/// Desktop-only fixtures: no live bootstrap, login, permissions, CI or credential writes.
@Suite(.serialized) @MainActor struct NativeR1SurfaceTests {
    private let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_R1_RENDER_OUTPUT"] ?? "/Users/vmaslov/Mimic/.local/R1Qualification-20261013/renders")
    private func window(_ view: NSView, width: CGFloat = 620, height: CGFloat = 600) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Очень длинное русское название вспомогательного окна"; window.contentView = view; window.orderFront(nil); return window
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func key(_ code: UInt16, _ chars: String = "", type: NSEvent.EventType = .keyDown, window: Int = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }
    private func render(_ view: NSView, _ name: String) throws {
        try #require(view.bounds.width > 100 && view.bounds.height >= 40)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for backing in [1, 2] {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(view.bounds.width) * backing), pixelsHigh: max(1, Int(view.bounds.height) * backing), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + "-\(backing)x.png"))
        }
    }

    @Test func windowChromeRetainsEditorsDefersIMEAndRestoresOriginal() async throws {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 300)), plain = NSTextField(string: "Сохранённый черновик"), secure = NSSecureTextField(string: "fixture-only"), note = NSTextView()
        plain.frame = CGRect(x: 20, y: 240, width: 360, height: 25); secure.frame = CGRect(x: 20, y: 190, width: 360, height: 25); note.frame = CGRect(x: 20, y: 20, width: 360, height: 130)
        content.addSubview(plain); content.addSubview(secure); content.addSubview(note)
        let window = window(content, width: 500, height: 300), mask = window.styleMask
        defer { window.contentView = nil; window.close() }
        let adapter = NativeRetroWindowAdapter(window: window)
        for appearance in PanelAppearance.allCases {
            adapter.apply(choice: appearance, scale: 1)
            if appearance.isRetro {
                let controls = descendants(try #require(window.contentView)).compactMap { $0 as? NativeRetroControl }
                #expect(Set(controls.compactMap { $0.accessibilityLabel() }) == Set([text("panel.chrome.close"), text("window.minimize"), text("window.maximize")]))
                #expect(controls.allSatisfy { $0.accessibilityRole() == .button })
                #expect([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { window.standardWindowButton($0)?.isHidden == true })
            }
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(window.contentView!.bounds.width >= 499 && window.contentView!.bounds.height >= 250)
            #expect(plain.window === window && secure.window === window && note.window === window)
            #expect(plain.stringValue == "Сохранённый черновик" && secure.stringValue == "fixture-only")
            #expect((window.contentView === content) == !appearance.isRetro)
            #expect(descendants(try #require(window.contentView)).compactMap { $0 as? NativeRetroControl }.count == (appearance.isRetro ? 3 : 0))
            if appearance.isRetro { try render(try #require(window.contentView), "window-" + appearance.rawValue) }
            else { #expect(window.styleMask == mask && window.standardWindowButton(.closeButton)?.isHidden == false) }
        }
        adapter.restore()
        window.makeFirstResponder(note); note.string = "draft"; note.setSelectedRange(NSRange(location: 2, length: 1))
        note.setMarkedText("構", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(note.hasMarkedText()); adapter.apply(choice: .windowsXP, scale: 1.4)
        #expect(window.contentView === content)
        note.unmarkText(); try await Task.sleep(for: .milliseconds(120))
        #expect(window.contentView !== content && note.window === window)
        adapter.restore(); #expect(window.contentView === content)
    }

    @Test(arguments: [PanelAppearance.windows95, .windowsXP])
    func menuNavigatesSubmenusAndRevalidatesOnce(appearance: PanelAppearance) throws {
        let owner = window(NSView()); defer { owner.close() }
        var calls = 0, enabled = true
        let menu = NativeRetroMenuPresenter()
        let entries: [NativeRetroMenuEntry] = [.init("Unavailable", enabled: { false }), .divider("separator"), .init("Подменю", children: [.init("Запустить", enabled: { enabled }) { calls += 1 }]), .init("SwiftFormat") { calls += 1 }]
        let anchor = CGRect(x: 100, y: 300, width: 60, height: 23)
        menu.show(items: entries, appearance: appearance, scale: 1.4, anchor: anchor, owner: owner, reducedMotion: true, keyboard: true)
        #expect(menu.highlighted == 2 && menu.windows.count == 1)
        #expect(menu.handle(try key(124)) && menu.windows.count == 2)
        enabled = false; #expect(menu.handle(try key(36)) && calls == 0)
        #expect(menu.handle(try key(123)) && menu.windows.count == 1)
        #expect(menu.handle(try key(1, "Sw")) && menu.highlighted == 3)
        try render(try #require(menu.windows.first?.contentView), "menu-" + appearance.rawValue)
        #expect(menu.handle(try key(36)) && calls == 1 && !menu.isPresented)
        #expect(!menu.handle(try key(36)) && calls == 1)
        menu.show(items: entries, appearance: appearance, scale: 1, anchor: anchor, owner: owner, reducedMotion: true, keyboard: true)
        #expect(menu.handle(try key(53)) && !menu.isPresented && calls == 1)
        menu.show(items: [], appearance: appearance, scale: 1, anchor: anchor, owner: owner, reducedMotion: false, keyboard: false); #expect(!menu.isPresented)
    }

    @Test func popupRetainsStateClampsAndClosesOnThemeOrOwnerLoss() throws {
        let anchor = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100)), owner = window(NSView(), width: 400, height: 300)
        owner.contentView?.addSubview(anchor); defer { owner.close() }
        let popup = NativeRetroPopoverController<Text>()
        var closed = 0; popup.dismissed = { closed += 1 }
        popup.update(content: AnyView(Text("Очень длинное русское название\n" + String(repeating: "Строка\n", count: 60))), appearance: .windowsXP, width: 400, anchor: anchor, presented: true)
        let panel = try #require(popup.panel), content = try #require(panel.contentView)
        #expect(NativeRetroPopupRegistry.owns(panel))
        if let available = owner.screen?.visibleFrame { #expect(available.contains(panel.frame)) }
        popup.update(content: AnyView(Text("Обновлённый черновик")), appearance: .windowsXP, width: 400, anchor: anchor, presented: true)
        #expect(popup.panel === panel && closed == 0)
        try render(content, "popup-windowsXP")
        popup.update(content: AnyView(Text("state")), appearance: .windows95, width: 400, anchor: anchor, presented: true)
        #expect(popup.panel == nil && closed == 1)
        popup.update(content: AnyView(Text("state")), appearance: .windows95, width: 400, anchor: anchor, presented: true)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: owner)
        #expect(popup.panel == nil && closed == 2)
        let available = CGRect(x: 0, y: 0, width: 480, height: 320)
        let position = NativeRetroPopoverController<Text>.origin(anchor: CGRect(x: 450, y: 20, width: 20, height: 20), size: CGSize(width: 400, height: 200), available: available)
        #expect(available.contains(CGRect(origin: position, size: CGSize(width: 400, height: 200))))
    }

    @Test func secureDialogCancelClearsAndDefaultIsNotDestructive() throws {
        _ = NSApplication.shared
        let suite = "R1Dialog-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelAppearanceStore(defaults: defaults); store.select(.windowsXP)
        let alert = NSAlert(); alert.messageText = "Подтверждение на безопасной фикстуре"; alert.informativeText = "Enter выбирает отмену; действие требует явного выбора."
        alert.addButton(withTitle: text("cancel")); alert.addButton(withTitle: "Действие")
        let secure = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 360, height: 24)); secure.stringValue = "fixture-only"; alert.accessoryView = secure
        let dialog = NativeRetroDialogSession(alert: alert, store: store, cancel: 0, defaultButton: 0)
        defer { dialog.panel.delegate = nil; dialog.panel.close() }
        dialog.panel.orderFront(nil); dialog.panel.contentView?.layoutSubtreeIfNeeded()
        try render(try #require(dialog.panel.contentView), "secure-dialog-windowsXP")
        #expect(dialog.handleKey(try key(36, "\r", window: dialog.panel.windowNumber)))
        #expect(dialog.result == .alertFirstButtonReturn)
        #expect(secure.stringValue.isEmpty)
        #expect(dialog.handleKey(try key(53, window: dialog.panel.windowNumber)) && dialog.result == .alertFirstButtonReturn)
    }

    @Test func productionAuxiliaryViewsRenderAndIdleWithoutActions() async throws {
        let suite = "R1Auxiliary-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite)); let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults); model.aiUsage.stop(); model.frameDiagnostics.enabled = false; model.motionSettings.reduceMotionOverride = true
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.projects = [.init(path: root.path, branch: "feature/очень-длинная-ветка")]; model.selectedProjectPath = root.path; model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        let setup = MimicSetupModel(model: model, defaults: defaults, home: root, system: R1SetupSystem(), codex: nil)
        for appearance in PanelAppearance.allCases {
            model.appearance.select(appearance)
            var pages: [(String, AnyView)] = [("interface-map", AnyView(InterfaceMapView().mimicWindowChrome())), ("credentials", AnyView(VStack { CISettingsView(settings: model.ciSettings, hasCheckout: true); JenkinsSettingsView(settings: model.jenkinsSettings) }.padding(16).mimicWindowChrome()))]
            for step in 0...5 {
                setup.step = step
                pages.append(("onboarding-\(step)", AnyView(MimicSetupView(setup: setup, model: model, uninstallMode: false, close: {}))))
                // Each step is rendered immediately below, so the shared model cannot advance before layout.
                let page = pages.removeLast(); try await renderPage(page, appearance: appearance, scale: appearance.isRetro ? 1.4 : 1, model: model)
            }
            for page in pages { try await renderPage(page, appearance: appearance, scale: appearance.isRetro ? 1.4 : 1, model: model) }
            #expect(model.records.isEmpty && model.builds.records.isEmpty && !setup.working)
        }
    }
    /// Warm retained opens of each own auxiliary form; output is raw draw submission, not compositor frames.
    @Test func auxiliaryOpenMeasurements() async throws {
        let suite = "R1AuxiliaryTiming-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        model.aiUsage.stop(); model.frameDiagnostics.enabled = false; model.motionSettings.reduceMotionOverride = true
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let setup = MimicSetupModel(model: model, defaults: defaults, home: root, system: R1SetupSystem(), codex: nil)
        var samples: [[String: Any]] = []
        for appearance in PanelAppearance.allCases {
            model.appearance.select(appearance)
            let pages: [(String, AnyView)] = [("onboarding", AnyView(MimicSetupView(setup: setup, model: model, uninstallMode: false, close: {}))),
                ("interface-map", AnyView(InterfaceMapView().mimicWindowChrome())),
                ("credentials", AnyView(VStack { CISettingsView(settings: model.ciSettings, hasCheckout: false); JenkinsSettingsView(settings: model.jenkinsSettings) }.padding(16).mimicWindowChrome()))]
            for (name, page) in pages {
                let host = NSHostingView(rootView: page.modifier(MimicAppearanceRoot(store: model.appearance)))
                let owner = window(host)
                try await Task.sleep(for: .milliseconds(100))
                var warm: [Double] = []
                for _ in 0..<20 {
                    owner.orderOut(nil); try await Task.sleep(for: .milliseconds(20))
                    let start = ProcessInfo.processInfo.systemUptime
                    owner.orderFront(nil); owner.contentView?.layoutSubtreeIfNeeded(); owner.contentView?.displayIfNeeded()
                    warm.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                samples.append(["surface": name, "theme": appearance.rawValue, "warmSamplesMS": warm])
                owner.contentView = nil; owner.close()
            }
        }
        let path = try #require(ProcessInfo.processInfo.environment["MIMIC_R1_AUX_MEASUREMENTS"])
        try JSONSerialization.data(withJSONObject: ["author": "Василий Маслов", "date": "13.10.2026", "samples": samples,
            "scope": "Debug retained own forms, 20 warm opens per surface/theme, no live actions; draw submission only"], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    @Test func aiR1MetersAndDocumentScrollbarGutter() async throws {
        let suite = "R1Visual-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults); model.aiUsage.stop(); model.frameDiagnostics.enabled = false
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.projects = [.init(path: root.path, branch: "fixture")]; model.selectedProjectPath = root.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        let now = Date(timeIntervalSince1970: 1_791_318_600)
        let snapshot = AIUsageSnapshot(provider: .codex, accountID: "fixture", plan: "pro", windows: [.init(period: .weekly, usedPercent: 21, resetsAt: now.addingTimeInterval(604800), duration: 604800)], fetchedAt: now)
        let summary = AICompactProviderSummary(provider: .codex, snapshot: snapshot, error: nil, refreshing: false, now: now)
        for appearance in PanelAppearance.allCases {
            model.appearance.select(appearance)
            let meters = NSHostingView(rootView: AICompactColumns(summaries: [summary], now: now, open: {}).padding(16)
                .background(appearance.isRetro ? Color(nsColor: NativeRetro.color("surface", appearance: appearance)) : Color(nsColor: .windowBackgroundColor))
                .modifier(MimicAppearanceRoot(store: model.appearance)))
            let meterWindow = window(meters, width: 420, height: 180)
            try await Task.sleep(for: .milliseconds(100)); meters.layoutSubtreeIfNeeded()
            let artwork = descendants(meters).compactMap { $0 as? NativeRetroArtwork.ArtworkView }.filter { if case .progress = $0.kind { return true }; return false }
            #expect(appearance.isRetro ? artwork.count == 1 : artwork.isEmpty)
            if appearance.isRetro { #expect(artwork[0].bounds.height == 13); try render(meters, "ai-meter-" + appearance.rawValue) }
            meterWindow.contentView = nil; meterWindow.close()
            let host = NSHostingView(rootView: MimicPanel(model: model).frame(height: 720).modifier(MimicAppearanceRoot(store: model.appearance)))
            let owner = window(host, width: appearance.panelWidth, height: 720)
            try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
            if appearance.isRetro {
                let rail = try #require(descendants(host).compactMap { $0 as? NativeRetroScrollbar }.first { !$0.isHidden })
                let scroll = try #require(rail.scroll)
                let cards = descendants(host).compactMap { $0 as? NativeRetroArtwork.ArtworkView }.filter { $0.kind == .frame && $0.window === owner }
                #expect(!cards.isEmpty)
                let gaps = cards.map { rail.frame.minX - $0.convert($0.bounds, to: scroll).maxX }
                #expect(gaps.allSatisfy { $0 >= 8 })
                print("R1_GUTTER theme=\(appearance.rawValue) minimumGap=\(gaps.min() ?? -1)")
                try render(host, "panel-gutter-" + appearance.rawValue)
            }
            owner.contentView = nil; owner.close()
        }
    }
    @Test func activitiesAIAndWorkPopupsRenderWithoutClients() async throws {
        let suite = "R1Activities-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite)); let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let project = ProjectContext(path: root.path, branch: "feature/очень-длинная-ветка-профиля-и-подписок")
        var build = BuildActivity(project: project, parameters: .init(operation: .test, scheme: "ОченьДлиннаяКонфигурацияПроектаРазработчика"), source: "fixture")
        build.status = .failed; build.phase = "build.phase.failed"; build.startedAt = Date().addingTimeInterval(-123); build.finishedAt = Date(); build.errorCode = "fixture"
        try BuildHistoryStore(directory: root).save([build])
        let model = TaskCoordinator(directory: root, defaults: defaults); model.aiUsage.stop(); model.frameDiagnostics.enabled = false; model.motionSettings.reduceMotionOverride = true
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.installBootstrapPreview(); model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        let pipeline = try JSONDecoder().decode(CIPipeline.self, from: Data(#"{"id":42,"status":"running","sha":"fixture","ref":"feature/ОченьДлиннаяРусскаяВетка","web_url":"https://example.invalid/42"}"#.utf8))
        let connection = GitLabConnection(baseURL: URL(string: "https://example.invalid")!, projectID: 42, projectPath: "fixture/Пример")
        let summary = CICompactSummary(entry: .init(pipeline: pipeline), context: .init(project: project, connection: connection), accountID: nil, checks: nil, updatedAt: nil, stale: true)
        let points = (0..<31).map { AIUsageDailyPoint(date: Date(timeIntervalSince1970: Double($0) * 86400), tokens: $0 * 1000) }, trend = AIUsageTrendPopoverState(points: points)
        for appearance in [PanelAppearance.windows95, .windowsXP] {
            model.appearance.select(appearance); model.builds.overlayWidth = 320
            let pages: [(String, AnyView)] = [
                ("bootstrap-activity", AnyView(QuickBootstrapView(model: model, showMimic: {}))),
                ("ci-activity", AnyView(CIActivitySection(summary: summary, open: {}, hide: {}))),
                ("build-activity", AnyView(BuildOverlayView(builds: model.builds, hide: {}))),
                ("ai-trend", AnyView(AIUsageTrendDetail(appearance: appearance, provider: .codex, state: trend)))
            ]
            for (name, content) in pages {
                let host = NSHostingView(rootView: content.modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.mimicTextScale, 1.4))
                let width: CGFloat = name == "ai-trend" ? 340 : 320
                let window = window(host, width: width, height: max(150, host.fittingSize.height)); defer { window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded(); try render(host, name + "-" + appearance.rawValue)
                #expect(host.fittingSize.width <= width + 1)
            }
            for kind in ["search", "report"] {
                let host = NSHostingView(rootView: WorkCardView(model: model, full: true, fixturePopup: kind).modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.mimicTextScale, 1.4))
                let window = window(host); defer { window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(400)); host.layoutSubtreeIfNeeded()
                let popup = try #require(NSApp.windows.last(where: { NativeRetroPopupRegistry.owns($0) && $0.isVisible }))
                try render(try #require(popup.contentView), "work-\(kind)-\(appearance.rawValue)")
            }
            #expect(model.builds.records.count == 1 && model.builds.active == nil && !model.work.connecting)
        }
    }
    /// The approved task card shares its neighbours' height even with worst-case cached content.
    @Test func work02UsesFixedCompactGeometry() async throws {
        let suite = "Work02Geometry-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.aiUsage.stop()
        var snapshot = WorkContextSnapshot(); snapshot.phase = "ready"
        snapshot.issue = WorkIssue(key: "DEMO-248", title: String(repeating: "Очень длинное название задачи 👩🏽‍💻 王秀英 ", count: 10), status: "В работе", url: "https://example.invalid/DEMO-248")
        for appearance in [PanelAppearance.tileGrid, .legacy, .windows95, .windowsXP] {
            model.appearance.select(appearance)
            for width: CGFloat in [238, 258, 488, 528] {
                let full = width > 258
                let view = WorkCardView(model: model, full: full, fixturePopup: "", snapshot: snapshot)
                    .padding(16).frame(width: width, alignment: .topLeading)
                    .modifier(MimicAppearanceRoot(store: model.appearance))
                let host = NSHostingView(rootView: view), owner = window(host, width: width, height: 160)
                defer { owner.contentView = nil; owner.close() }
                try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height <= 160, "Task content must fit the shared compact height")
                #expect(host.fittingSize.width <= width + 1)
                try render(host, "work02-\(appearance.rawValue)-\(Int(width))")
            }
        }
    }
    private func renderPage(_ page: (String, AnyView), appearance: PanelAppearance, scale: CGFloat, model: TaskCoordinator) async throws {
        let host = R1SurfaceCountingHost(rootView: page.1.modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.mimicTextScale, scale))
        let window = window(host); defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100)); window.contentView?.layoutSubtreeIfNeeded()
        if appearance.isRetro { try render(try #require(window.contentView), "\(page.0)-\(appearance.rawValue)-\(scale)") }
        let start = host.layouts; try await Task.sleep(for: .milliseconds(600))
        let idleLayouts = host.layouts - start
        print("R1_IDLE page=\(page.0) theme=\(appearance.rawValue) textScale=\(scale) intervalMS=600 layouts=\(idleLayouts)")
        #expect(idleLayouts < 10)
    }
}

@MainActor private struct R1SetupSystem: MimicSetupSystem {
    var loginStatus: String { "setup.disabled" }
    func setLogin(enabled: Bool) async throws { Issue.record("Unexpected live setup action") }
    func notifications(enabled: Bool) async -> String { Issue.record("Unexpected permission request"); return "setup.disabled" }
}
private final class R1SurfaceCountingHost<Content: View>: NSHostingView<Content> {
    var layouts = 0
    override func layout() { layouts += 1; super.layout() }
}
