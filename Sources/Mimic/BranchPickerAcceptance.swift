//
//  BranchPickerAcceptance.swift
//  Mimic
//
//  Created by Василий Маслов on 16.10.2026.
#if DEBUG
import AppKit
import Combine
import Foundation
import SwiftUI
import MimicCore

/// A separate regular window exercises the production picker with a disposable
/// Git repository. It never constructs the production delegate or native bridge.
@MainActor enum BranchPickerAcceptance {
    static func run() {
        let driver = Driver()
        NSApp.setActivationPolicy(.regular); NSApp.delegate = driver
        NSApp.run(); withExtendedLifetime(driver) { }
    }

    @MainActor private final class Driver: NSObject, NSApplicationDelegate {
        private var window: NSWindow?
        private var model: TaskCoordinator?
        private var observer: AnyCancellable?
        private let root = URL(fileURLWithPath: "/private/tmp/MimicBranchPicker-" + UUID().uuidString)
        private let suite = "MimicBranchPicker-" + UUID().uuidString

        func applicationDidFinishLaunching(_: Notification) {
            do {
                let defaults = UserDefaults(suiteName: suite)!
                let checkout = root.appendingPathComponent("repo")
                try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
                for args in [["init", "-b", "source"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"], ["branch", "develop"], ["remote", "add", "origin", root.appendingPathComponent("remote.git").path], ["update-ref", "refs/remotes/origin/feature/IOS-21161", "HEAD"]] {
                    guard EnvironmentInspector.capture("/usr/bin/git", args, directory: checkout.path).0 == 0 else { exit(1) }
                }
                let project = try EnvironmentInspector.project(path: checkout.path)
                var services = SimulatorPanelServices()
                services.catalog = { _ in .init(devices: [], developer: "/fixture/Developer") }
                let model = TaskCoordinator(directory: root.appendingPathComponent("storage"), simulatorServices: services, defaults: defaults, inspectProject: { ($0, [], GitSummary(porcelain: "")) })
                self.model = model; model.aiUsage.stop(); model.appearance.select(.tileGrid)
                model.projects = [project]; model.selectedProjectPath = project.path
                model.gitSummary = GitSummary(porcelain: ""); model.expandedSection = .branches; model.loadBranches()
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 560, height: 660), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Mimic · Branch picker fixture"; window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: MimicPanel(model: model).frame(height: 660).modifier(MimicAppearanceRoot(store: model.appearance)))
                self.window = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                observer = model.branchSwitch.$operations.sink { operations in
                    let last = operations.last
                    let result: [String: Any] = ["checkout": checkout.path, "phase": last?.phase.rawValue ?? "idle", "error": last?.error ?? "", "target": last?.target ?? ""]
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                        try? data.write(to: self.root.appendingPathComponent("result.json"), options: .atomic)
                    }
                }
                FileHandle.standardOutput.write(Data((root.path + "\n").utf8))
            } catch { exit(1) }
        }
        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
        func applicationWillTerminate(_: Notification) {
            observer?.cancel(); model?.records = []; model?.stopAndExit()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }
}
#endif
