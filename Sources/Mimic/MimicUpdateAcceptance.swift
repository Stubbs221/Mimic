//
//  MimicUpdateAcceptance.swift
//  Mimic
//
//  Created by Василий Маслов on 06.10.2026.
#if DEBUG
import AppKit
import Combine
import Foundation
import MimicCore

/// Disposable app-only update harness. It never opens the user bridge, profiles, Codex or credentials.
@MainActor
enum MimicUpdateAcceptance {
    static func run() {
        let app = Bundle.main.bundleURL
        let root = app.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        guard ["/private/tmp/MimicUpdateAcceptance-", "/tmp/MimicUpdateAcceptance-"].contains(where: root.path.hasPrefix),
              let data = try? Data(contentsOf: root.appendingPathComponent("fixture.plist")),
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let suite = config["suite"], let expected = config["expectedBuild"],
              let defaults = UserDefaults(suiteName: suite) else { exit(64) }
        let delegate = FixtureDelegate(root: root, defaults: defaults, expected: expected)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited); application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) { }
    }

    private final class FixtureDelegate: NSObject, NSApplicationDelegate {
        let root: URL
        let defaults: UserDefaults
        let expected: String
        var model: TaskCoordinator?
        var integration: MimicIntegration?
        var updater: MimicUpdater?
        var observation: AnyCancellable?
        var operation: Task<Void, Never>?
        var events: [String] = []
        init(root: URL, defaults: UserDefaults, expected: String) {
            self.root = root; self.defaults = defaults; self.expected = expected
        }
        func append(_ event: String) {
            self.events.append(event)
            if let data = try? JSONEncoder().encode(self.events) { try? data.write(to: root.appendingPathComponent("events.json"), options: .atomic) }
        }
        func applicationDidFinishLaunching(_: Notification) {
            if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == self.expected {
                let preserved = self.defaults.string(forKey: "fixture.selectedProject") == self.root.path && self.defaults.bool(forKey: "fixture.setting")
                try? Data((preserved ? "installed" : "settings-lost").utf8).write(to: self.root.appendingPathComponent("result"))
                NSApp.terminate(nil); return
            }
            self.defaults.set(self.root.path, forKey: "fixture.selectedProject")
            self.defaults.set(true, forKey: "fixture.setting")
            let model = TaskCoordinator(directory: root.appendingPathComponent("Support"), defaults: self.defaults)
            self.model = model
            model.records = [TaskRecord(action: .format, project: ProjectContext(path: root.path))]
            let integration = MimicIntegration(model: model, defaults: self.defaults)
            self.integration = integration; integration.developmentExit = { NSApp.terminate(nil) }
            let lifecycle = MimicUpdateLifecycle(model: model, defaults: self.defaults)
            integration.prepareUpdateBackup = { try await lifecycle.prepareBackup() }
            let updater = MimicUpdater(integration: integration, lifecycle: lifecycle, defaults: self.defaults)
            self.updater = updater
            self.observation = updater.$state.sink { [weak self] state in self?.append(state.rawValue) }
            updater.start()
            self.operation = Task {
                let deadline = Date().addingTimeInterval(40)
                while Date() < deadline {
                    if updater.state == .waiting && !model.records.isEmpty {
                        self.append("queue-preserved")
                        try? await Task.sleep(for: .milliseconds(300))
                        model.records = []; self.append("queue-finished")
                    }
                    if updater.state == .failed {
                        try? await Task.sleep(for: .milliseconds(500))
                        let retry = updater.canCheck ? ":retry-ready" : ":retry-blocked"
                        try? Data(("failed:" + String(updater.failureCode ?? 0) + retry).utf8).write(to: root.appendingPathComponent("result"))
                        NSApp.terminate(nil); return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? Data("timeout".utf8).write(to: root.appendingPathComponent("result"))
                NSApp.terminate(nil)
            }
        }
        func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
            if self.model?.updateReserved == true {
                guard self.integration?.developmentUpdateReady == true else { self.append("exit-blocked"); return .terminateCancel }
                self.append("idle-exit")
            }
            return .terminateNow
        }
    }
}
#endif
