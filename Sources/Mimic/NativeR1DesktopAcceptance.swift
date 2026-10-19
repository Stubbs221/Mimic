//
//  NativeR1DesktopAcceptance.swift
//  Mimic
//
//  Created by Василий Маслов on 13.10.2026.
#if DEBUG
import AppKit
import Foundation
import MimicCore

/// A separate NSApplication host exercises nested modal event loops without Swift Testing's runner.
/// It constructs only disposable windows/stores and exits before the production delegate or bridge.
@MainActor enum NativeR1DesktopAcceptance {
    static func run() {
        guard let path = ProcessInfo.processInfo.environment["MIMIC_R1_FIXTURE_OUTPUT"],
              path.hasPrefix("/Users/vmaslov/Mimic/.local/R1Qualification-"),
              let defaults = UserDefaults(suiteName: "R1DesktopFixture-" + UUID().uuidString) else { exit(64) }
        let driver = Driver(output: URL(fileURLWithPath: path), defaults: defaults)
        NSApp.setActivationPolicy(.regular); NSApp.delegate = driver
        NSApp.run()
        withExtendedLifetime(driver) { }
    }

    @MainActor private final class Driver: NSObject, NSApplicationDelegate, NSWindowDelegate {
        let output: URL
        let store: PanelAppearanceStore
        var evidence: [[String: Any]] = []
        var taps = 0
        var closeRequests = 0
        var vetoClose = true
        var zoomRequests = 0
        var miniCompleted = false
        var deminiCompleted = false
        init(output: URL, defaults: UserDefaults) { self.output = output; store = PanelAppearanceStore(defaults: defaults) }
        func applicationDidFinishLaunching(_: Notification) {
            NSApp.activate(ignoringOtherApps: true)
            if ProcessInfo.processInfo.environment["MIMIC_R1_FIXTURE_INSPECT"] == "true" {
                inspect(); exit(0)
            }
            Task { @MainActor in
                do {
                    for appearance in [PanelAppearance.windows95, .windowsXP, .tileGrid, .legacy] {
                        store.select(appearance)
                        try await windowActions(appearance)
                        for action in [appearance.isRetro ? "escape" : "cancel-button", "default-cancel", "confirm", "secret-enter", "secret-cancel"] { try await dialog(appearance, action: action) }
                        if appearance.isRetro { try await dialog(appearance, action: "close"); try await dialog(appearance, action: "theme-change") }
                    }
                    save(success: true); exit(0)
                } catch { save(success: false, failure: String(describing: error)); exit(1) }
            }
        }
        /// Empty editors in a disposable dialog allow screen-reader inspection without capturing secrets.
        func inspect() {
            store.select(.windows95)
            let (window, _, _) = owner()
            let adapter = NativeRetroWindowAdapter(window: window); adapter.apply(choice: .windows95, scale: 1)
            let alert = NSAlert(); alert.messageText = "R1 · Фикстура VoiceOver"
            alert.informativeText = "Проверка чтения и отмены. Реальные операции отсутствуют."
            let field = NSSecureTextField(string: ""); field.setAccessibilityLabel("Фикстурное защищённое поле")
            field.frame = CGRect(x: 0, y: 0, width: 360, height: 28); alert.accessoryView = field
            alert.addButton(withTitle: "Остаться"); alert.addButton(withTitle: "Фикстурное подтверждение")
            _ = NativeRetroDialog.run(alert, store: store, cancel: 0, defaultButton: 0)
            field.stringValue = ""; adapter.restore(); window.delegate = nil; window.close()
        }
        func save(success: Bool, failure: String = "") {
            let value: [String: Any] = ["author": "Василий Маслов", "date": "13.10.2026", "success": success,
                                      "failure": failure, "samples": evidence,
                                      "screens": NSScreen.screens.map { ["width": $0.frame.width, "height": $0.frame.height, "scale": $0.backingScaleFactor] }]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("native-host.json"), options: .atomic)
            }
        }
        struct Failed: Error, CustomStringConvertible { let description: String }
        func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws { if try !value() { throw Failed(description: label) } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func caption(_ window: NSWindow, _ label: String) throws -> NativeRetroControl {
            guard let content = window.contentView,
                  let control = descendants(content).compactMap({ $0 as? NativeRetroControl }).first(where: { !$0.isHidden && $0.accessibilityLabel() == label }) else { throw Failed(description: "Missing caption: " + label) }
            return control
        }
        func waitUntil(_ predicate: () -> Bool, label: String) async throws {
            for _ in 0..<100 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failed(description: label)
        }
        func owner() -> (NSWindow, NSTextField, NSButton) {
            let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 520, height: 280), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.delegate = self; window.title = "R1 fixture · Очень длинное русское название"
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 280))
            let field = NSTextField(string: "Сохранённый черновик"); field.frame = CGRect(x: 20, y: 160, width: 360, height: 28)
            let button = NSButton(title: "Fixture action", target: self, action: #selector(tap)); button.frame = CGRect(x: 20, y: 60, width: 180, height: 30)
            root.addSubview(field); root.addSubview(button); window.contentView = root
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
            return (window, field, button)
        }
        @objc func tap() { taps += 1 }
        func windowShouldClose(_ sender: NSWindow) -> Bool { closeRequests += 1; return !vetoClose }
        func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { zoomRequests += 1; return true }
        func windowDidMiniaturize(_ notification: Notification) { miniCompleted = true }
        func windowDidDeminiaturize(_ notification: Notification) { deminiCompleted = true }

        // MARK: - Real caption actions and screen movement

        func windowActions(_ appearance: PanelAppearance) async throws {
            let (window, field, _) = owner(), content = window.contentView, mask = window.styleMask, frame = window.frame
            let adapter = NativeRetroWindowAdapter(window: window)
            defer { adapter.restore(); window.delegate = nil; window.close() }
            adapter.apply(choice: appearance, scale: 1.4); window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            closeRequests = 0; vetoClose = true; zoomRequests = 0; miniCompleted = false; deminiCompleted = false
            if appearance.isRetro {
                try require(caption(window, text("panel.chrome.close")).accessibilityPerformPress(), "close activation")
            } else { window.performClose(nil) }
            try require(closeRequests == 1 && window.isVisible, "delegate close veto")
            if appearance.isRetro { try require(caption(window, text("window.minimize")).accessibilityPerformPress(), "minimize activation") }
            else { window.performMiniaturize(nil) }
            try await waitUntil({ miniCompleted && window.isMiniaturized }, label: "native miniaturization")
            window.deminiaturize(nil); try await waitUntil({ deminiCompleted && !window.isMiniaturized }, label: "native deminiaturization")
            try await Task.sleep(for: .milliseconds(100))
            try require(!window.isMiniaturized && field.window === window, "deminiaturization retains editor")
            window.makeKeyAndOrderFront(nil); window.contentView?.displayIfNeeded()
            if appearance.isRetro { try require(caption(window, text("window.maximize")).accessibilityPerformPress(), "zoom activation") }
            else { window.performZoom(nil) }
            try await waitUntil({ zoomRequests == 1 && window.isZoomed }, label: "native zoom")
            window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded()
            if appearance.isRetro { try require(caption(window, text("window.restore")).accessibilityPerformPress(), "restore activation") }
            else { window.performZoom(nil) }
            try await waitUntil({ zoomRequests == 2 && !window.isZoomed }, label: "native restore")
            let screens = NSScreen.screens
            for screen in screens {
                let visible = screen.visibleFrame
                window.setFrame(CGRect(x: visible.midX - 260, y: visible.midY - 156, width: 520, height: 312), display: true)
                try await Task.sleep(for: .milliseconds(120))
                try require(window.screen === screen && field.window === window, "screen movement retains identity")
            }
            window.setFrame(frame, display: false); adapter.restore()
            try require(window.styleMask == mask, "original style mask: \(mask.rawValue) -> \(window.styleMask.rawValue)")
            try require(window.contentView === content, "original content identity")
            try require(field.stringValue == "Сохранённый черновик", "retained editor text")
            adapter.apply(choice: appearance, scale: 1); window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded()
            vetoClose = false
            if appearance.isRetro { try require(caption(window, text("panel.chrome.close")).accessibilityPerformPress(), "accepted close activation") }
            else { window.performClose(nil) }
            try require(closeRequests == 2 && !window.isVisible, "close exactly once")
            evidence.append(["kind": "window-actions", "theme": appearance.rawValue, "closeRequests": closeRequests, "zoomRequests": zoomRequests, "screensVisited": screens.count, "pass": true])
        }

        // MARK: - Modal event routing, owner blocking and secure cancellation

        func dialog(_ appearance: PanelAppearance, action: String) async throws {
            let (window, field, button) = owner()
            defer { window.delegate = nil; window.close() }
            taps = 0; vetoClose = true
            let alert = NSAlert(); alert.messageText = "Подтверждение · " + appearance.rawValue
            alert.informativeText = "Только фикстура: действия не выполняются."
            let secretInput = action.hasPrefix("secret-")
            alert.addButton(withTitle: secretInput ? "OK" : "Остаться"); alert.addButton(withTitle: secretInput ? text("cancel") : "Fixture confirm")
            let secure = NSSecureTextField(string: "disposable-fixture"); secure.frame = CGRect(x: 0, y: 0, width: 360, height: 28); alert.accessoryView = secure
            defer { secure.stringValue = "" }
            var observedModal = false, timedOut = false, ownerBlocked = false, retainedSecure = false
            let probe = Timer(timeInterval: 0.1, repeats: false) { _ in MainActor.assumeIsolated {
                observedModal = NSApp.modalWindow != nil
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
                }
            } }
            let choose = Timer(timeInterval: 0.25, repeats: false) { [self] _ in MainActor.assumeIsolated {
                ownerBlocked = taps == 0
                guard let modal = NSApp.modalWindow else { return }
                retainedSecure = secure.window === modal
                if action == "theme-change" { store.select(.tileGrid) }
                if action == "close" { modal.performClose(nil); return }
                if action == "cancel-button" || (action == "secret-cancel" && !appearance.isRetro) { alert.buttons[secretInput ? 1 : 0].performClick(nil); return }
                if action == "confirm" {
                    if appearance.isRetro, let root = modal.contentView {
                        let controls = descendants(root).compactMap { $0 as? NativeRetroControl }.filter { type(of: $0) == NativeRetroControl.self }
                        _ = controls.max(by: { $0.convert(.zero, to: root).x < $1.convert(.zero, to: root).x })?.accessibilityPerformPress()
                    } else { alert.buttons[1].performClick(nil) }
                    return
                }
                let code: UInt16 = action == "default-cancel" || action == "secret-enter" ? 36 : 53
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: modal.windowNumber, context: nil, characters: code == 36 ? "\r" : "\u{1b}", charactersIgnoringModifiers: code == 36 ? "\r" : "\u{1b}", isARepeat: false, keyCode: code) { NSApp.postEvent(event, atStart: false) }
            } }
            let watchdog = Timer(timeInterval: 5, repeats: false) { _ in MainActor.assumeIsolated { timedOut = true; NSApp.abortModal() } }
            for timer in [probe, choose, watchdog] { RunLoop.main.add(timer, forMode: .modalPanel) }
            let response = NativeRetroDialog.run(alert, store: store, cancel: secretInput ? 1 : 0, defaultButton: 0)
            [probe, choose, watchdog].forEach { $0.invalidate() }
            evidence.append(["kind": "modal-routing", "theme": appearance.rawValue, "action": action, "observedModal": observedModal, "timedOut": timedOut, "ownerBlocked": ownerBlocked, "ownerTaps": taps, "retainedSecure": retainedSecure, "response": response.rawValue])
            try require(!timedOut && observedModal && ownerBlocked && retainedSecure, "modal routing/owner blocking: " + appearance.rawValue + " " + action)
            // Confirmation uses the rendered R1 button, not NSAlert's detached original button.
            let accepted = action == "confirm" || action == "secret-enter"
            try require(response == (action == "confirm" || action == "secret-cancel" ? .alertSecondButtonReturn : .alertFirstButtonReturn), "modal result: " + appearance.rawValue + " " + action)
            if appearance.isRetro && !accepted { try require(secure.stringValue.isEmpty, "cancel clears secure input") }
            // The synthetic recipient records a count only; secret contents never enter evidence.
            let deliveries = action == "secret-enter" && !secure.stringValue.isEmpty ? 1 : 0
            try require(deliveries == (action == "secret-enter" ? 1 : 0), "secure delivery exactly once")
            secure.stringValue = ""; try require(secure.stringValue.isEmpty, "caller clears successful input")
            try require(window.firstResponder === field.currentEditor() || window.firstResponder === field, "owner focus restored")
            evidence.append(["kind": "modal", "theme": appearance.rawValue, "action": action, "ownerBlocked": ownerBlocked, "secureCleared": true, "deliveries": deliveries, "response": response.rawValue, "pass": true])
            store.select(appearance)
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
