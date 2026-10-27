//
//  NativeR1ControlsTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 13.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

/// Native interaction fixtures never start a profile action or expose a real credential.
@Suite(.serialized) @MainActor struct NativeR1ControlsTests {
    private func window(_ content: NSView, width: CGFloat = 440, height: CGFloat = 300) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.orderFront(nil); return window
    }
    private func key(_ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown, repeated: Bool = false, window: Int = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: code))
    }
    private func settle(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func renderPopup(_ panel: NSPanel, name: String) throws {
        let content = try #require(panel.contentView); content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        let output = URL(fileURLWithPath: "/private/tmp/MimicNativeR1Controls-20261013/renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds)); content.cacheDisplay(in: content.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

    @Test(arguments: [PanelAppearance.windows95, .windowsXP])
    func checkboxHasNativeValueAndOneActivation(appearance: PanelAppearance) throws {
        let check = NativeRetroCheckboxControl(frame: .init(x: 0, y: 0, width: 200, height: 23)); check.appearanceChoice = appearance
        var calls = 0; check.actionBlock = { calls += 1; check.checked.toggle() }
        #expect(check.accessibilityRole() == .checkBox)
        check.beginPress(); check.movePress(inside: false); check.movePress(inside: true); check.releasePress(inside: true)
        #expect(check.checked && calls == 1)
        #expect((check.accessibilityValue() as? NSNumber)?.boolValue == true)
        check.keyDown(with: try key(49)); check.keyDown(with: try key(49, repeated: true)); #expect(calls == 1)
        check.keyUp(with: try key(49, type: .keyUp)); #expect(!check.checked && calls == 2)
        check.keyDown(with: try key(49)); check.keyDown(with: try key(53)); check.keyUp(with: try key(49, type: .keyUp)); #expect(calls == 2)
        check.beginPress(); check.isEnabled = false; check.releasePress(inside: true); #expect(calls == 2)
        check.isEnabled = true; check.keyDown(with: try key(36)); #expect(calls == 3)
        check.beginPress(); check.appearanceChoice = appearance == .windows95 ? .windowsXP : .windows95; check.releasePress(inside: true); #expect(calls == 3)
    }

    @Test(arguments: [PanelAppearance.windows95, .windowsXP])
    func selectionHighlightIsProvisionalAndCancellationDoesNotCommit(appearance: PanelAppearance) throws {
        let selection = NativeRetroSelectionControl(frame: .init(x: 0, y: 0, width: 250, height: 23)); selection.appearanceChoice = appearance
        selection.titles = ["Alpha", "Локализация", "SwiftFormat"]; selection.selectedIndex = 0
        #expect(selection.accessibilityValue() as? String == "Alpha")
        var commits: [Int] = []; selection.commit = { commits.append($0) }
        let window = window(selection); defer { selection.closePopup(); window.contentView = nil; window.close() }
        selection.openPopup(keyboard: true); #expect(selection.popup != nil)
        try renderPopup(try #require(selection.popup), name: "selection-popup-" + appearance.rawValue)
        selection.handlePopupKey(try key(125)); #expect(selection.highlightedIndex == 1 && commits.isEmpty)
        selection.handlePopupKey(try key(53)); #expect(selection.popup == nil && commits.isEmpty)
        selection.openPopup(keyboard: true); selection.handlePopupKey(try key(1, characters: "Sw")); #expect(selection.highlightedIndex == 2)
        selection.handlePopupKey(try key(36)); #expect(commits == [2] && selection.popup == nil)
        selection.openPopup(keyboard: true); selection.handlePopupKey(try key(49)); #expect(commits == [2])
        selection.keyUp(with: try key(49, type: .keyUp)); #expect(commits == [2, 0])
        selection.openPopup(keyboard: true); NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(selection.popup == nil && commits == [2, 0])
        selection.titles = ["Same name", "Same name"]; selection.optionIdentities = [AnyHashable("a"), AnyHashable("b")]
        selection.openPopup(keyboard: true); selection.optionIdentities = [AnyHashable("b"), AnyHashable("a")]
        #expect(selection.popup == nil && commits == [2, 0])
        selection.titles = []; selection.openPopup(keyboard: true); #expect(selection.popup == nil)
    }

    @Test func tooltipDelayKeyboardPriorityAndStaleCancellation() async throws {
        let root = NSView(frame: .init(x: 0, y: 0, width: 400, height: 180))
        let parent = NativeRetroHelpAnchor(frame: root.bounds); parent.choice = .windowsXP; parent.message = "Card help"
        let child = NativeRetroHelpAnchor(frame: .init(x: 30, y: 30, width: 150, height: 23)); child.choice = .windowsXP; child.message = "Child explanation: длинное русское пояснение, которое должно переноситься внутри экрана."
        let control = NativeRetroControl(frame: child.frame); root.addSubview(control); root.addSubview(parent); root.addSubview(child)
        let window = window(root); defer { NativeRetroHelpCoordinator.shared.hide(); window.contentView = nil; window.close() }
        let help = NativeRetroHelpCoordinator.shared
        window.makeFirstResponder(control); #expect(help.keyboardAnchor(window: window) === child)
        #expect(help.handleEvent(try key(44, characters: "/", flags: .command, window: window.windowNumber)) == nil && help.panel != nil)
        help.hide(); #expect(help.handleEvent(try key(44, characters: "ю", flags: .command, window: window.windowNumber)) == nil && help.panel != nil)
        #expect(help.handleEvent(try key(48, characters: "\t", window: window.windowNumber)) != nil && help.panel == nil)
        help.schedule(child, keyboard: false); #expect(help.panel == nil)
        try await Task.sleep(for: .milliseconds(300)); #expect(help.panel == nil)
        let revision = help.generation; help.cancel(anchor: child); help.show(generation: revision, keyboard: false); #expect(help.panel == nil)
        help.schedule(child, keyboard: false); try await Task.sleep(for: .milliseconds(560)); #expect(help.panel != nil)
        help.hide(); help.schedule(child, keyboard: true); let panel = try #require(help.panel)
        #expect(panel.alphaValue == 1 && panel.ignoresMouseEvents)
        try renderPopup(panel, name: "tooltip-windowsXP")
        if let screen = window.screen ?? NSScreen.main { #expect(screen.visibleFrame.contains(panel.frame)) }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window); #expect(help.panel == nil)
        help.reducedMotion = { true }; help.schedule(child, keyboard: false); help.show(generation: help.generation, keyboard: false)
        #expect(help.panel?.alphaValue == 1); help.hide(); help.reducedMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        help.schedule(child, keyboard: false); child.choice = .tileGrid; help.show(generation: help.generation, keyboard: false); #expect(help.panel == nil)
    }

    @Test func retainedPlainSecureAndMultilineEditorsSurviveFourThemes() async throws {
        let suite = "R1Controls-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let shared = CodexPanelAppearanceStore(directory: directory, previous: .tileGrid), store = PanelAppearanceStore(defaults: defaults); store.connect(to: shared)
        let state = R1ControlsState()
        let host = R1LayoutCountingHost(rootView: R1ControlsFixture(state: state).modifier(MimicAppearanceRoot(store: store)).frame(width: 440, height: 300))
        let window = window(host)
        let continuity = NativeAppearanceContinuity(store: store, shared: shared, editingWindow: { window })
        defer { withExtendedLifetime(continuity) {}; window.contentView = nil; window.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try await settle(host)
        let fields = descendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        let plain = try #require(fields.first { !($0 is NSSecureTextField) }), secure = try #require(fields.first { $0 is NSSecureTextField })
        let multiline = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor })
        window.makeFirstResponder(plain); let editor = try #require(plain.currentEditor() as? NSTextView)
        editor.setSelectedRange(.init(location: 2, length: 4))
        for appearance in PanelAppearance.allCases {
            try shared.select(try #require(CodexPanelAppearance(rawValue: appearance.rawValue)), expectedRevision: shared.value.revision); try await settle(host)
            #expect(descendants(host).contains { $0 === plain } && descendants(host).contains { $0 === secure } && descendants(host).contains { $0 === multiline })
            #expect(window.firstResponder === editor && editor.selectedRange() == NSRange(location: 2, length: 4))
            #expect(state.name == "СохранённыйЧерновик🧩" && state.secret == "fixture-only" && state.note == "Многострочный\nчерновик")
            if appearance.isRetro { #expect(!plain.isBezeled && plain.backgroundColor == .white) }
            else { #expect(plain.isBezeled) }
            let originals = descendants(host).compactMap { $0 as? NSPopUpButton }
            #expect(!originals.isEmpty)
            #expect(originals.allSatisfy { $0.isHidden == appearance.isRetro })
        }
        editor.insertText("Прямой ввод", replacementRange: editor.selectedRange()); try await settle(host)
        #expect(state.name.contains("Прямой ввод"))
        let help = NativeRetroHelpCoordinator.shared
        #expect(help.keyboardAnchor(window: window)?.message == "Сохранённый черновик")
        editor.setMarkedText("かな", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: 0, length: 2))
        let marked = editor.markedRange(); try shared.select(.windows95, expectedRevision: shared.value.revision); try await settle(host)
        #expect(editor.hasMarkedText() && editor.markedRange() == marked && store.selection == .windowsXP)
        if let anchor = help.keyboardAnchor(window: window) {
            help.schedule(anchor, keyboard: true)
            #expect(help.handleEvent(try key(53, window: window.windowNumber)) != nil && editor.hasMarkedText())
        }
        editor.unmarkText(); try await settle(host); #expect(store.selection == .windows95)
        window.makeFirstResponder(secure); let secureEditor = try #require(secure.currentEditor() as? NSTextView)
        secureEditor.setSelectedRange(.init(location: 2, length: 3))
        try shared.select(.windowsXP, expectedRevision: shared.value.revision); try await settle(host)
        #expect(secure.currentEditor() === secureEditor && secureEditor.selectedRange() == NSRange(location: 2, length: 3) && state.secret == "fixture-only")
        try shared.select(.windows95, expectedRevision: shared.value.revision); try await settle(host)
        window.makeFirstResponder(multiline); multiline.setMarkedText("かな", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: 0, length: 2))
        try shared.select(.windowsXP, expectedRevision: shared.value.revision); try await settle(host)
        #expect(multiline.hasMarkedText() && store.selection == .windows95)
        multiline.unmarkText(); try await settle(host); #expect(store.selection == .windowsXP)
        let selector = try #require(descendants(host).compactMap { $0 as? NativeRetroSelectionControl }.first)
        selector.openPopup(keyboard: true); selector.highlight(1); #expect(state.choice == "one")
        selector.confirm(1); try await settle(host); #expect(state.choice == "two")
        selector.openPopup(keyboard: true); try shared.select(.windows95, expectedRevision: shared.value.revision); try await settle(host)
        #expect(selector.popup == nil && state.choice == "two")
        let count = host.layoutCount; try await Task.sleep(for: .milliseconds(600)); #expect(host.layoutCount - count < 10)
    }

    @Test func controlsRenderAtBothScalesAndLargeText() async throws {
        let output = URL(fileURLWithPath: "/private/tmp/MimicNativeR1Controls-20261013/renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [PanelAppearance.tileGrid, .legacy, .windows95, .windowsXP] {
            for scale in [CGFloat(1), 1.4] {
                let host = NSHostingView(rootView: R1ControlsFixture(state: R1ControlsState()).environment(\.mimicPanelAppearance, appearance).environment(\.mimicTextScale, scale).foregroundStyle(appearance.isRetro ? Color.black : Color.primary).frame(width: 440, height: 300).padding(16).background(Color(nsColor: appearance.isRetro ? NativeRetro.color("surface", appearance: appearance) : .windowBackgroundColor)))
                let window = window(host, width: 472, height: 332); defer { window.contentView = nil; window.close() }
                try await settle(host)
                for backing in [1, 2] {
                    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * backing, pixelsHigh: Int(host.bounds.height) * backing, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                    rep.size = host.bounds.size; host.cacheDisplay(in: host.bounds, to: rep)
                    try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("controls-\(appearance.rawValue)-\(scale)-\(backing)x.png"))
                }
            }
        }
    }

    @Test func settingsCheckboxKeepsTheExistingRowComposition() async throws {
        let output = URL(fileURLWithPath: "/private/tmp/MimicNativeR1Controls-20261013/renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [PanelAppearance.windows95, .windowsXP] {
            let host = NSHostingView(rootView: SettingsSwitch(title: "Системные уведомления", isOn: .constant(true), identifier: "fixture.notifications").environment(\.mimicPanelAppearance, appearance).frame(width: 440, height: 60).padding(16).background(Color(nsColor: NativeRetro.color("surface", appearance: appearance))))
            let window = window(host, width: 472, height: 92); defer { window.contentView = nil; window.close() }
            try await settle(host)
            let checkbox = try #require(descendants(host).compactMap { $0 as? NativeRetroCheckboxControl }.first)
            #expect(checkbox.bounds.width <= 20)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("settings-switch-\(appearance.rawValue).png"))
        }
    }

    /// The same production forms are rendered with temporary profiles, never discovered by xcodebuild.
    @Test func productionFormsRenderWithoutStartingActions() async throws {
        let suite = "R1ProductionForms-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        model.aiUsage.stop(); model.motionSettings.reduceMotionOverride = true
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.projects = [.init(path: root.path, branch: "feature/platform/dependency-registry")]; model.selectedProjectPath = root.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: root); model.generatorName = "МодульПлатёжногоПрофиляРазработчика"
        let output = URL(fileURLWithPath: "/private/tmp/MimicNativeR1Controls-20261013/renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [PanelAppearance.windows95, .windowsXP, .tileGrid, .legacy] {
            model.appearance.select(appearance)
            for scale in [CGFloat(1), 1.4] {
                let pages: [(String, AnyView)] = [
                    ("ai-settings", AnyView(AIIntegrationsSettingsView(model: model, settings: model.aiSettings, usage: model.aiUsage, analysis: model.analysis))),
                    ("ci-settings", AnyView(VStack { CISettingsView(settings: model.ciSettings, hasCheckout: true, framed: true); JenkinsSettingsView(settings: model.jenkinsSettings, framed: true) })),
                    ("build", AnyView(BuildConfigurationView(model: model, builds: model.builds))),
                    ("generator", AnyView(ToolContent(model: model, action: .generation)))
                ]
                for (name, content) in pages {
                    let host = NSHostingView(rootView: content.mimicFont(.body).buttonStyle(MimicButtonStyle()).padding(16).frame(width: appearance.panelWidth).modifier(MimicAppearanceRoot(store: model.appearance)).environment(\.mimicTextScale, scale).background(Color(nsColor: appearance.isRetro ? NativeRetro.color("surface", appearance: appearance) : .windowBackgroundColor)))
                    let window = window(host, width: appearance.panelWidth, height: 900)
                    try await settle(host)
                    let height = max(200, host.fittingSize.height); window.setContentSize(CGSize(width: appearance.panelWidth, height: height)); host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.width <= appearance.panelWidth + 1)
                    for backing in [1, 2] {
                        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * backing, pixelsHigh: Int(host.bounds.height) * backing, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                        rep.size = host.bounds.size; host.cacheDisplay(in: host.bounds, to: rep)
                        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(appearance.rawValue)-\(scale)-\(backing)x.png"))
                    }
                    window.contentView = nil; window.close()
                    #expect(model.records.isEmpty && model.builds.records.isEmpty)
                }
            }
        }
    }
}

// MARK: - Shared retained fixture

@MainActor private final class R1ControlsState: ObservableObject {
    @Published var name = "СохранённыйЧерновик🧩"
    @Published var secret = "fixture-only"
    @Published var note = "Многострочный\nчерновик"
    @Published var choice = "one"
    @Published var checked = true
}
private struct R1ControlsFixture: View {
    @ObservedObject var state: R1ControlsState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Имя", text: $state.name).textFieldStyle(.roundedBorder).mimicInput().mimicHelp("Сохранённый черновик")
            SecureField("Токен", text: $state.secret).textFieldStyle(.roundedBorder).mimicInput()
            TextEditor(text: $state.note).frame(height: 80).mimicInput()
            Picker("Схема", selection: $state.choice) { Text("ОченьДлиннаяКонфигурацияПроектаДляРазработчика").tag("one"); Text("Release").tag("two") }
                .mimicSelection("Схема", selection: $state.choice, options: [.init("ОченьДлиннаяКонфигурацияПроектаДляРазработчика", "one"), .init("Release", "two")])
            Toggle("Сохранить параметры проекта", isOn: $state.checked).toggleStyle(MimicCheckboxStyle()).mimicHelp("Настройки сохраняются независимо от оформления")
        }
    }
}
private final class R1LayoutCountingHost<Content: View>: NSHostingView<Content> {
    var layoutCount = 0
    override func layout() { layoutCount += 1; super.layout() }
}
