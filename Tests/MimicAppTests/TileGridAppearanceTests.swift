// Created by Василий Маслов on 08.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct TileGridAppearanceTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @Test func olderHelpersAndPublicActionResultsReceiveNoAppearance() async throws {
        let suite = "TileGridMetadata-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults), integration = MimicIntegration(model: model, defaults: defaults)
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        for method in ["open_panel", "get_state"] {
            let old = try await integration.handle(.init(method: method, threadID: "fixture"))
            #expect(old.object?["appearance"] == nil)
            let current = try await integration.handle(.init(method: method, threadID: "fixture", presentationMetadataVersion: 1))
            #expect(current["appearance"].string == "tileGrid")
        }
        let task = TaskRecord(action: .format, project: .init(path: root.path))
        model.records = [task]
        let cancelled = try await integration.handle(.init(method: "cancel_local_task", parameters: ["taskID": .string(task.id.uuidString)], presentationMetadataVersion: 1))
        #expect(cancelled.object?["appearance"] == nil && model.records.first?.status == .cancelled)
    }
    @Test func liveAppearanceRetainsNativeFormTerminalSelectionAndLayoutDraft() async throws {
        let suite = "TileGridRetention-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path, branch: "feature/длинная-ветка-🧩")
        model.projects = [project]; model.selectedProjectPath = project.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        let device = SimulatorDevice(id: UUID(), name: "iPhone Fixture", runtime: "iOS 27", state: "Booted")
        model.installSimulatorPreview([device]); model.selectSimulator(device)
        var task = TaskRecord(action: .bootstrap, project: project); task.status = .running
        model.records = [task]; model.selectedTaskID = task.id; model.generatorName = "СохранённыйЧерновик"
        let session = model.bootstrapTerminal(for: task), terminal = session.view()
        terminal.feed(text: "SAFE FIXTURE OUTPUT\r\n")
        model.panelLayout.begin(); model.panelLayout.edit { $0.remove(.ci) }
        let draft = model.panelLayout.draft
        let host = NSHostingView(rootView: VStack {
            BootstrapCard(model: model, mode: .expanded)
            GeneratorForm(model: model)
        }.frame(width: 560).modifier(MimicAppearanceRoot(store: model.appearance)))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 560, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let field = try #require(descendants(host).compactMap { $0 as? NSTextField }.first { $0.stringValue == model.generatorName })
        window.makeFirstResponder(field); let responder = window.firstResponder
        for appearance in [PanelAppearance.legacy, .tileGrid, .legacy, .tileGrid] {
            model.appearance.select(appearance)
            try await Task.sleep(for: .milliseconds(70)); host.layoutSubtreeIfNeeded()
            #expect(descendants(host).contains { $0 === field })
            #expect(window.firstResponder === responder)
            #expect(model.bootstrapTerminal(for: task) === session && session.view() === terminal)
            #expect(String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("SAFE FIXTURE OUTPUT"))
            #expect(model.generatorName == "СохранённыйЧерновик" && model.panelLayout.draft == draft)
            #expect(model.selectedTaskID == task.id && model.selectedSimulator?.id == device.id)
            #expect(model.records.map(\.id) == [task.id] && model.records.first?.status == .running)
        }
    }

    /// Real controls and local display fixtures, without tasks, network admission or builds.
    @Test func renderBothAppearancesAndAllSettingsGroups() async throws {
        let suite = "TileGridRenders-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.projects = [.init(path: root.path, branch: "feature/Tile-Grid-🧩", commit: "fixture-sha")]; model.selectedProjectPath = root.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        model.installSimulatorPreview((1...4).map { .init(id: UUID(), name: "iPhone \($0)", runtime: "iOS 27", state: "Booted") })
        model.motionSettings.reduceMotionOverride = true
        let output = URL(fileURLWithPath: "/private/tmp/MimicTileGrid-20261008/native")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in PanelAppearance.allCases {
            model.appearance.select(appearance)
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: MimicPanel(model: model).frame(height: 900).modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: appearance.panelWidth, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); window.contentView = host; window.orderFront(nil)
                defer { window.close() }
                for page in ["home", "application", "aiIntegrations", "ci", "environment"] {
                    if page == "home" { model.returnHome() } else { model.openSettings(group: SettingsGroup(rawValue: page)!) }
                    try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    #expect(abs(host.bounds.width - appearance.panelWidth) < 1)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(appearance.rawValue)-\(scheme == .dark ? "dark" : "light")-\(page).png"))
                }
            }
        }
    }

    @Test func renderAuxiliarySurfacesAndExistingForms() async throws {
        let suite = "TileGridAuxiliary-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.installBootstrapPreview()
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        model.generatorName = "ДлинныйЧерновикФормы🧩"
        let setup = MimicSetupModel(model: model, defaults: defaults, home: root, system: AppearanceSystemFixture(), codex: nil)
        let menu = NSMenu(); menu.autoenablesItems = false
        for title in ["Bootstrap iOS", "Bootstrap tvOS", "Полная очистка", "Derived Data", "Карта интерфейса", "Настройка Mimic", "Завершить Mimic"] { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        menu.items[2].isEnabled = false
        let scale: CGFloat = ProcessInfo.processInfo.environment["MIMIC_TEXT_SCALE"] == "2" ? 2 : 1
        let output = URL(fileURLWithPath: "/private/tmp/MimicTileGrid-20261008/native/" + (scale == 2 ? "auxiliary-large" : "auxiliary"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in PanelAppearance.allCases {
            if scale == 2 && appearance == .legacy { continue }
            model.appearance.select(appearance)
            for scheme in [ColorScheme.light, .dark] {
                var pages: [(String, AnyView, CGFloat)] = [
                    ("express", AnyView(ExpressMenuView(menu: menu, invoke: { _ in }, dismiss: {})), 320),
                    ("always-on", AnyView(QuickBootstrapView(model: model, showMimic: {})), 320),
                    ("history", AnyView(TaskHistoryContent(model: model).padding(16)), appearance.panelWidth),
                    ("build-configuration", AnyView(BuildConfigurationView(model: model, builds: model.builds).padding(16)), appearance.panelWidth)
                ]
                for action in [MimicAction.generation, .localization, .proto, .format, .fullCleanup, .derivedDataCleanup] {
                    pages.append((action.rawValue, AnyView(ToolContent(model: model, action: action).padding(16)), appearance.panelWidth))
                }
                for step in 0...5 { pages.append(("onboarding-\(step)", AnyView(MimicSetupView(setup: setup, model: model, uninstallMode: false, close: {})), 620)) }
                for (name, content, width) in pages {
                    if name.hasPrefix("onboarding-"), let step = Int(name.suffix(1)) { setup.step = step }
                    let canvas = appearance == .tileGrid ? MimicTheme.native("paper", dark: scheme == .dark) : NSColor.windowBackgroundColor
                    let host = NSHostingView(rootView: content.mimicFont(.body).buttonStyle(MimicButtonStyle()).frame(width: width).background(Color(nsColor: canvas)).modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.colorScheme, scheme).environment(\.mimicTextScale, scale))
                    let size = CGSize(width: width, height: max(200, host.fittingSize.height))
                    let window = NSWindow(contentRect: .init(origin: .init(x: -10000, y: -10000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); window.contentView = host; window.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
                    window.setContentSize(.init(width: width, height: max(200, host.fittingSize.height))); host.layoutSubtreeIfNeeded()
                    #expect(abs(host.fittingSize.width - width) < 1)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(appearance.rawValue)-\(scheme == .dark ? "dark" : "light")-\(name).png"))
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    @Test func systemOptionsReflectAuthorizationAndPreserveExistingOwnership() async throws {
        let suite = "TileGridOptions-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let system = AppearanceSystemFixture(), options = MimicSystemOptions(defaults: defaults, system: system)
        system.loginStatus = "setup.enabled"; system.notificationResult = "setup.denied"
        await options.refresh()
        #expect(options.login == "setup.enabled" && options.notifications == "setup.denied" && system.notificationRequests == 0)
        await options.setLogin(true)
        #expect(!defaults.bool(forKey: "setupOwnsLogin"))
        system.rejectLogin = true
        await options.setLogin(false)
        #expect(options.error == "setup.login.failed" && options.login == "setup.enabled")
        await options.setNotifications(true)
        #expect(options.error == "setup.denied" && !defaults.bool(forKey: "setupNotifications"))
        system.notificationResult = "setup.enabled"
        await options.setNotifications(true)
        #expect(options.notifications == "setup.enabled" && defaults.bool(forKey: "setupNotifications"))
        await options.setNotifications(false)
        #expect(options.notifications == "setup.disabled" && !defaults.bool(forKey: "setupNotifications"))
    }

    @Test func nativeLargeTextScalesTypographyAndKeepsPanelWidth() async throws {
        let suite = "TileGridLargeText-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.projects = [.init(path: root.path, branch: "feature/очень-длинная-ветка-開発-🧩-TileGrid")]; model.selectedProjectPath = root.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        model.motionSettings.reduceMotionOverride = true
        let normal = NSHostingView(rootView: Text("Tile Grid").mimicFont(.body).modifier(MimicAppearanceRoot(store: model.appearance)))
        let large = NSHostingView(rootView: Text("Tile Grid").mimicFont(.body).modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.mimicTextScale, 2))
        #expect(large.fittingSize.height > normal.fittingSize.height * 1.5)
        let host = NSHostingView(rootView: MimicPanel(model: model).frame(height: 1400).modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.mimicTextScale, 2))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 560, height: 1400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 560)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/MimicTileGrid-20261008/native/large-text.png"))
    }
}

@MainActor private final class AppearanceSystemFixture: MimicSetupSystem {
    var loginStatus = "setup.disabled"
    var notificationResult = "setup.disabled"
    var rejectLogin = false
    var notificationRequests = 0
    func setLogin(enabled: Bool) async throws {
        if rejectLogin { throw MimicBridgeError.unavailable }
        loginStatus = enabled ? "setup.enabled" : "setup.disabled"
    }
    func notificationStatus() async -> String { notificationResult }
    func notifications(enabled: Bool) async -> String { notificationRequests += 1; return enabled ? notificationResult : "setup.disabled" }
}
