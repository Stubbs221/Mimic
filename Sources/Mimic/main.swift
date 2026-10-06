//
//  main.swift
//  Mimic
//
//  Created by Василий Маслов on 01.10.2026.
import AppKit
import Combine
import SwiftUI
import MimicCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: TaskCoordinator
    private var status: NSStatusItem!
    private var panel: NSPanel!
    private var panelMotion: MimicWindowMotion!
    private var interfaceMapWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var setupObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var iconAppearanceObservation: NSKeyValueObservation?
    private var activityPanel: BootstrapActivityPanel!
    private var buildPanel: BuildActivityPanel!
    private var localClickMonitor: Any?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var allowExit = false
    private var updateLifecycle: MimicUpdateLifecycle?

    init(model: TaskCoordinator = TaskCoordinator()) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        self.model.appIconSettings.activate(dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        self.iconAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.model.appIconSettings.appearanceChanged(dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            }
        }
        let rootMenu = NSMenu()
        let applicationItem = NSMenuItem(title: text("app.name"), action: nil, keyEquivalent: ""); rootMenu.addItem(applicationItem)
        let applicationMenu = NSMenu(); applicationItem.submenu = applicationMenu
        let toggle = NSMenuItem(title: text("menu.toggle"), action: #selector(self.togglePanel), keyEquivalent: "t")
        toggle.keyEquivalentModifierMask = [.command, .shift]; toggle.target = self
        applicationMenu.addItem(toggle)
        let show = NSMenuItem(title: text("tasks"), action: #selector(self.showTasks), keyEquivalent: "1"); show.target = self
        applicationMenu.addItem(show)
        let map = NSMenuItem(title: text("interface.map.title"), action: #selector(self.showInterfaceMap), keyEquivalent: "2"); map.target = self
        applicationMenu.addItem(map)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: text("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem(title: text("edit"), action: nil, keyEquivalent: ""); rootMenu.addItem(editItem)
        let edit = NSMenu(title: text("edit")); editItem.submenu = edit
        edit.addItem(NSMenuItem(title: text("copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: text("paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        NSApp.mainMenu = rootMenu
        self.status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.status.button?.target = self; self.status.button?.action = #selector(self.statusClicked)
        self.status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.status.button?.setAccessibilityLabel(text("app.name"))
        self.panel = MimicPopover(contentRect: NSRect(x: 0, y: 0, width: MimicMetrics.panelWidth, height: 660), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        self.panel.title = text("app.name")
        self.panel.isOpaque = false; self.panel.backgroundColor = .clear; self.panel.hasShadow = true
        self.panel.titleVisibility = .hidden; self.panel.titlebarAppearsTransparent = true; self.panel.isMovable = false
        self.panel.standardWindowButton(.closeButton)?.isHidden = true; self.panel.standardWindowButton(.miniaturizeButton)?.isHidden = true; self.panel.standardWindowButton(.zoomButton)?.isHidden = true
        self.panelMotion = MimicWindowMotion(window: self.panel, settings: self.model.motionSettings)
        #if DEBUG
        if (Bundle.main.bundleIdentifier == "local.vmaslov.MimicGlassPreview" || Bundle.main.bundleIdentifier == "local.vmaslov.MimicRedesignPreview" || Bundle.main.bundleIdentifier == "local.vmaslov.MimicMotionPreview") {
            self.panel.contentView = NSHostingView(rootView: MimicWindowRoot(presentation: self.panelMotion.presentation, settings: self.model.motionSettings) { LiquidGlassPreviewPanel(model: self.model) })
        } else { self.panel.contentView = NSHostingView(rootView: MimicWindowRoot(presentation: self.panelMotion.presentation, settings: self.model.motionSettings) { MimicPanel(model: self.model) }) }
        #else
        self.panel.contentView = NSHostingView(rootView: MimicWindowRoot(presentation: self.panelMotion.presentation, settings: self.model.motionSettings) { MimicPanel(model: self.model) })
        #endif
        self.panel.level = .floating; self.panel.hidesOnDeactivate = false; self.panel.delegate = self
        self.panelMotion.visibilityChanged = { [weak self] in self?.model.panelVisibilityChanged($0) }
        (self.panel as? MimicPopover)?.dismiss = { [weak self] in self?.hidePanels(source: .keyboard) }
        self.buildPanel = BuildActivityPanel(model: self.model)
        self.buildPanel.anchor = { [weak self] in self?.panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame }
        self.activityPanel = BootstrapActivityPanel(model: self.model)
        self.activityPanel.anchor = { [weak self] in
            guard let button = self?.status.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        self.activityPanel.open = { [weak self] in self?.openBesideActivity() }
        self.installClickMonitors()
        self.model.releasePanelFocus = { [weak self] in self?.panel.makeFirstResponder(nil) }
        self.model.showPanel = { [weak self] in
            guard let self else { return }
            self.showMainPanel(source: self.model.navigationSource)
        }
        self.model.showInterfaceMap = { [weak self] in self?.showInterfaceMap() }
        self.model.showSetup = { [weak self] in self?.showSetup() }
        self.model.showQuickActivity = { [weak self] in self?.showQuickActivity() }
        self.model.stateChanged = { [weak self] in self?.updateStatus() }
        self.model.afterStopped = { [weak self] in self?.allowExit = true; NSApp.reply(toApplicationShouldTerminate: true) }
        let integration = MimicIntegration(model: self.model)
        integration.developmentExit = { NSApp.terminate(nil) }
        self.model.integration = integration
        let lifecycle = MimicUpdateLifecycle(model: self.model)
        self.updateLifecycle = lifecycle
        integration.prepareUpdateBackup = { try await lifecycle.prepareBackup() }
        let updater = MimicUpdater(integration: integration, lifecycle: lifecycle)
        self.model.updater = updater
        updater.showSettings = { [weak self] in self?.model.openSettings(group: .application); self?.showMainPanel(source: .current) }
        updater.willRelaunch = { [weak self] in
            UserDefaults.standard.set(self?.panel.isVisible == true, forKey: "mimic.reopenAfterUpdate")
        }
        self.launchObserver = DistributedNotificationCenter.default().addObserver(forName: MimicApplicationLaunch.notification, object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.object as? String, let request = MimicApplicationLaunch(rawValue: value) else { return }
            Task { @MainActor in self?.handleLaunch(request) }
        }
        integration.start()
        self.model.profileRemote.resume()
        self.setupObserver = DistributedNotificationCenter.default().addObserver(forName: .init((Bundle.main.bundleIdentifier ?? "local.vmaslov.Mimic") + ".setup"), object: nil, queue: .main) { [weak self] notification in
            let uninstall = notification.object as? String == "uninstall"
            Task { @MainActor in self?.showSetup(uninstall: uninstall) }
        }
        self.model.aiUsage.start()
        self.updateStatus()
        self.handleLaunch(MimicApplicationLaunch(arguments: CommandLine.arguments))
        if UserDefaults.standard.bool(forKey: "mimic.reopenAfterUpdate") {
            UserDefaults.standard.removeObject(forKey: "mimic.reopenAfterUpdate")
            self.showMainPanel(source: .current)
        }
        integration.refreshInstalledPluginIfNeeded()
        updater.start()
        // These development flags never execute a project command.
    }

    /// Navigation requests are shared by first launch and subsequent invocations.
    private func handleLaunch(_ request: MimicApplicationLaunch) {
        switch request {
        case .panel: self.showMainPanel(source: .current)
        case .tasks: self.showTasks()
        case .setup: self.showSetup()
        case .uninstall: self.showSetup(uninstall: true)
        case .background: break
        }
    }

    private func updateStatus() {
        self.activityPanel?.update()
        self.buildPanel?.update()
        let marker: StatusIcon.Marker = self.model.bootstrapIsBlocked ? .paused : self.model.unreadFailure ? .failed : .none
        if let button = self.status.button {
            let health = text(self.model.bootstrapIsBlocked ? "bootstrap.xcode.waiting" : (self.model.busy || self.model.analysis.isActive) ? "status.running" : self.model.unreadFailure ? "status.failed" : "status.idle")
            AIUsageStatusPresentation.apply(button: button, usage: self.model.aiUsage, marker: marker, health: health)
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { self.togglePanel() }
        return true
    }

    /// Route deactivation through the same visibility owner instead of AppKit ordering out behind it.
    func applicationDidResignActive(_: Notification) { self.hidePanels(source: .automatic) }

    // MARK: - Status item and anchored panels

    @objc
    private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            self.hidePanels()
            guard let button = self.status.button else { return }
            self.quickMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else { self.togglePanel() }
    }

    func quickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for platform in BootstrapPlatform.allCases {
            let item = NSMenuItem(title: text("quick.bootstrap." + platform.rawValue), action: #selector(self.quickBootstrap(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = platform.rawValue; item.isEnabled = self.model.canRequestQuickBootstrap
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for action in [MimicAction.fullCleanup, .derivedDataCleanup] {
            let item = NSMenuItem(title: text(action.titleKey), action: #selector(self.quickCleanup(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action.rawValue; item.isEnabled = self.model.canRequestQuickCleanup
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let map = NSMenuItem(title: text("interface.map.title"), action: #selector(self.showInterfaceMap), keyEquivalent: ""); map.target = self
        menu.addItem(map)
        let setup = NSMenuItem(title: text("setup.title"), action: #selector(self.openSetup), keyEquivalent: ""); setup.target = self; menu.addItem(setup)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: text("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc
    private func quickCleanup(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let action = MimicAction(rawValue: value), action.isCleanup else { return }
        self.model.requestQuickCleanup(action)
    }

    @objc
    private func quickBootstrap(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let platform = BootstrapPlatform(rawValue: value), self.model.canRequestQuickBootstrap else { return }
        self.model.requestQuickBootstrap(platform: platform)
        self.hidePanels()
        self.activityPanel.update(force: true)
    }

    @objc
    private func togglePanel() {
        if self.panelMotion.desiredVisible { self.hidePanels(source: .current) }
        else { self.showMainPanel(source: .current) }
    }

    private func showMainPanel(source: MimicMotionSource) {
        if !self.panel.isVisible {
            if self.activityPanel.window.isVisible {
                self.panel.setFrame(self.activityPanel.adjacentFrame(size: NSSize(width: MimicMetrics.panelWidth, height: 660)), display: true)
            } else {
                guard let button = self.status.button, let window = button.window, let screen = window.screen ?? NSScreen.main else { return }
                let rect = window.convertToScreen(button.convert(button.bounds, to: nil)), visible = screen.visibleFrame
                let height = min(660, visible.height - 20)
                self.panel.setFrame(NSRect(x: min(max(rect.midX - 220, visible.minX), visible.maxX - 440), y: max(visible.minY, rect.minY - height), width: 440, height: height), display: true)
            }
        }
        self.panelMotion.setVisible(true, source: source, key: true)
    }

    private func showQuickActivity() {
        guard self.model.quickBootstrapActivity != nil else { return }
        self.hidePanels(source: .current)
        self.activityPanel.update(force: true)
    }

    private func openBesideActivity() { self.showMainPanel(source: .current) }

    private func hidePanels(source: MimicMotionSource = .current) {
        self.model.panelLayout.cancelDrag()
        AIUsageTrendPopoverController.dismissAll()
        self.model.aiUsage.panelDidClose()
        self.panelMotion.setVisible(false, source: source)
    }

    private func installClickMonitors() {
        // Hosting views may consume cancelOperation; the panel owns Escape even during a fade.
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panelMotion.desiredVisible || self.panelMotion.isTransitioning,
                  event.window === self.panel || NSApp.keyWindow === self.panel || AIUsageTrendPopoverController.owns(event.window) || event.window == nil else { return event }
            if AIUsageTrendPopoverController.handleKey(event) { return nil }
            guard event.keyCode == 53 else { return event }
            if self.model.panelLayout.cancelDrag() { return nil }
            self.hidePanels(source: .keyboard)
            return nil
        }

        self.clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanels(source: .pointer) }
        }
        self.localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel, event.window !== self.activityPanel.window, event.window !== self.status.button?.window, !AIUsageTrendPopoverController.owns(event.window) { self.hidePanels() }
            return event
        }
    }

    /// Reuse one reference window; closing it does not affect tasks or the main panel.
    @objc
    private func showInterfaceMap() {
        if self.interfaceMapWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = text("interface.map.title")
            window.contentView = NSHostingView(rootView: InterfaceMapView())
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 700))
            window.contentMinSize = NSSize(width: 440, height: 420)
            window.center()
            self.interfaceMapWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        self.interfaceMapWindow?.makeKeyAndOrderFront(nil)
    }

    /// Setup is a separately authorized window; a repeated request reuses it.
    private func showSetup(uninstall: Bool = false) {
        guard !self.model.admissionsClosed else { return }
        if self.setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = text("setup.title"); window.contentMinSize = NSSize(width: 560, height: 520); window.center()
            self.setupWindow = window
        }
        if self.setupWindow?.isVisible != true || uninstall {
            let setup = MimicSetupModel(model: self.model)
            self.setupWindow?.contentView = NSHostingView(rootView: MimicSetupView(setup: setup, model: self.model, uninstallMode: uninstall, close: { [weak self] in self?.setupWindow?.close() }))
        }
        NSApp.activate(ignoringOtherApps: true); self.setupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSetup() { self.showSetup() }

    @objc
    private func showTasks() { self.model.showHistory(source: .current) }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        if self.model.updateReserved {
            return self.model.integration?.developmentUpdateReady == true ? .terminateNow : .terminateCancel
        }
        if self.model.updater?.hasPendingInstallation == true {
            self.model.updater?.deferInstallation()
            self.model.message = text("update.quit.deferred")
            return .terminateCancel
        }
        if self.allowExit { return .terminateNow }
        if !self.model.busy && !self.model.requestingBootstrap && self.model.pendingCount == 0 && !self.model.switchingBranch && !self.model.analysis.isActive && self.model.aiSettings.checking == nil {
            if self.model.simulatorScreen.canExit { return .terminateNow }
            DispatchQueue.main.async { self.model.stopAndExit() }
            return .terminateLater
        }
        let alert = NSAlert(); alert.messageText = text("quit.active"); alert.informativeText = text("quit.effects")
        alert.addButton(withTitle: text("stay")); alert.addButton(withTitle: text("stop.quit"))
        if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        // Schedule after returning terminateLater so the reply cannot race the delegate response.
        DispatchQueue.main.async { self.model.stopAndExit() }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        self.model.aiUsage.stop()
        if let setupObserver { DistributedNotificationCenter.default().removeObserver(setupObserver) }
        if let launchObserver { DistributedNotificationCenter.default().removeObserver(launchObserver) }
        self.model.integration?.stop(); self.model.remoteTests.stop()
        self.buildPanel.stop()
        self.panelMotion.stop(); self.activityPanel.stop(); self.model.panelVisibilityChanged(false); self.model.clearDiagnosticsForExit()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

/// Escape dismisses the menu without changing any task's lifetime.
final class MimicPopover: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { self.dismiss?() }
}

// Offline packaging check exits before opening UI, user settings, Keychain or the bridge.
if CommandLine.arguments.contains("--check-resources") {
    let checks: [String: Bool] = [
        "app": MimicResources.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ru") != nil,
        "core": MimicCoreResources.bundle.url(forResource: "pricing_supplement", withExtension: "json") != nil,
        "identity": Bundle.main.bundleIdentifier == "local.vmaslov.Mimic"
    ]
    if let data = try? JSONSerialization.data(withJSONObject: checks, options: .sortedKeys) { FileHandle.standardOutput.write(data + Data([10])) }
    exit(checks.values.allSatisfy { $0 } ? 0 : 1)
}

#if DEBUG
if Bundle.main.bundleIdentifier == "local.vmaslov.MimicUpdateFixture" {
    MimicUpdateAcceptance.run(); exit(0)
}
#endif
let application = NSApplication.shared
// Development deployment refreshes the existing plugin without creating a task owner or UI.
if CommandLine.arguments.contains("--refresh-codex-plugin") {
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            let root = try MimicPluginExporter.export(app: Bundle.main.bundleURL, readme: text("mcp.install.instructions"), description: text("mcp.plugin.description"), shortDescription: text("mcp.plugin.shortDescription"))
            guard let codex = MimicPluginInstaller.findCodex() else { throw MimicBridgeError.unavailable }
            try await MimicPluginInstaller.install(marketplace: root, codex: codex)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((text("mcp.error.export") + "\n").utf8))
            exit(1)
        }
    }
    application.run()
    exit(1)
}
let delegate: AppDelegate
#if DEBUG
if CommandLine.arguments.contains("--simulator-acceptance") {
    Task { await SimulatorAcceptance.run(); application.terminate(nil) }
    application.run(); exit(0)
}

#endif

// Acquire before constructing TaskCoordinator: a losing launch cannot create UI, a queue or a listener.
let instanceLock: MimicInstanceLock
do {
    if let owner = try MimicInstanceLock.acquire() { instanceLock = owner }
    else {
        let launch = MimicApplicationLaunch(arguments: CommandLine.arguments)
        if launch == .background { exit(0) }
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await launch.forward(); exit(0) }
            catch { FileHandle.standardError.write(Data((text("launch.error.unavailable") + "\n").utf8)); exit(1) }
        }
        application.run()
        exit(0)
    }
} catch {
    FileHandle.standardError.write(Data((text("launch.error.lock") + "\n").utf8))
    exit(1)
}

#if DEBUG
if (Bundle.main.bundleIdentifier == "local.vmaslov.MimicGlassPreview" || Bundle.main.bundleIdentifier == "local.vmaslov.MimicRedesignPreview" || Bundle.main.bundleIdentifier == "local.vmaslov.MimicMotionPreview") || Bundle.main.bundleIdentifier == "local.vmaslov.MimicInlinePreview" || CommandLine.arguments.contains("--preview-bootstrap") || Bundle.main.bundleIdentifier == "local.vmaslov.MimicPreview" || Bundle.main.bundleIdentifier == "local.vmaslov.MimicConfigurationPreview" || Bundle.main.bundleIdentifier == "local.vmaslov.MimicResultPreview" {
    let previewModel = TaskCoordinator(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-UI-Preview"), defaults: UserDefaults(suiteName: "Mimic-UI-Preview") ?? .standard)
    if Bundle.main.bundleIdentifier == "local.vmaslov.MimicInlinePreview" || (Bundle.main.bundleIdentifier == "local.vmaslov.MimicGlassPreview" || Bundle.main.bundleIdentifier == "local.vmaslov.MimicRedesignPreview" || Bundle.main.bundleIdentifier == "local.vmaslov.MimicMotionPreview") { previewModel.installInlinePanelPreview() }
    else if Bundle.main.bundleIdentifier == "local.vmaslov.MimicResultPreview" { previewModel.installTaskResultPreview() }
    else { previewModel.installBootstrapPreview(configuration: Bundle.main.bundleIdentifier == "local.vmaslov.MimicConfigurationPreview") }
    delegate = AppDelegate(model: previewModel)
} else { delegate = AppDelegate() }
#else
delegate = AppDelegate()
#endif
application.delegate = delegate
// Keep the weak application delegate alive throughout the event loop.
withExtendedLifetime((delegate, instanceLock)) {
    application.run()
}
