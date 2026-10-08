//
//  MimicSetup.swift
//  Mimic
//
//  Created by Василий Маслов on 04.10.2026.
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import MimicCore
import UserNotifications

@MainActor protocol MimicSetupSystem {
    var loginStatus: String { get }
    func setLogin(enabled: Bool) async throws
    func notifications(enabled: Bool) async -> String
    func notificationStatus() async -> String
}
extension MimicSetupSystem {
    func notificationStatus() async -> String { "setup.disabled" }
}
@MainActor struct NativeMimicSetupSystem: MimicSetupSystem {
    var loginStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: "setup.enabled"
        case .requiresApproval: "setup.approval"
        default: "setup.disabled"
        }
    }
    func setLogin(enabled: Bool) async throws {
        if enabled { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
        else if SMAppService.mainApp.status != .notRegistered { try await SMAppService.mainApp.unregister() }
    }
    func notificationStatus() async -> String {
        guard Bundle.main.bundleIdentifier != nil else { return "setup.failed" }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "setup.enabled"
        case .denied: return "setup.denied"
        default: return "setup.disabled"
        }
    }
    func notifications(enabled: Bool) async -> String {
        guard enabled else { return "setup.disabled" }
        guard Bundle.main.bundleIdentifier != nil else { return "setup.failed" }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            return allowed ? "setup.enabled" : "setup.denied"
        } catch { return "setup.failed" }
    }
}

/// One session per window. Existing CI models own validation and credentials throughout setup.
@MainActor final class MimicSetupModel: ObservableObject {
    @Published var step = 0
    @Published var autoOpen = true
    @Published var login = true
    @Published var notify = true
    @Published private(set) var working = false { didSet { self.model.setupBusy = self.working } }
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var finished = false
    let model: TaskCoordinator
    private let defaults: UserDefaults
    private let home: URL
    private let system: any MimicSetupSystem
    private let codex: URL?
    private let app: URL
    init(model: TaskCoordinator, defaults: UserDefaults = .standard, home: URL = MimicSetupRules.codexHome(), system: any MimicSetupSystem = NativeMimicSetupSystem(), codex: URL? = MimicPluginInstaller.findCodex(), app: URL = Bundle.main.bundleURL) {
        self.model = model; self.defaults = defaults; self.home = home; self.system = system; self.codex = codex; self.app = app
        self.login = defaults.object(forKey: "setupLoginChoice") as? Bool ?? true
        self.notify = defaults.object(forKey: "setupNotificationChoice") as? Bool ?? true
        if let path = model.project?.path, let choices = defaults.dictionary(forKey: "setupAutoOpen") as? [String: Bool] { self.autoOpen = choices[path] ?? true }
    }
    func selectionChanged() {
        let choices = self.defaults.dictionary(forKey: "setupAutoOpen") as? [String: Bool] ?? [:]
        self.autoOpen = choices[self.model.selectedProjectPath] ?? true
    }
    var canContinue: Bool {
        guard !self.model.admissionsClosed, !self.working, !self.model.ciSettings.checking, !self.model.jenkinsSettings.checking else { return false }
        switch self.step {
        case 0: return self.model.hasCompatibleProfile && self.model.project != nil && !self.model.checking && !self.model.switchingBranch
        case 2: return self.model.ciSettings.connection != nil && self.model.ciSettings.enteredToken.isEmpty && self.model.ciSettings.error == nil && !self.model.ciSettings.verified && self.model.ciSettings.address == self.model.ciSettings.connection?.baseURL.absoluteString && self.model.ciSettings.projectPath == self.model.ciSettings.connection?.projectPath
        case 3: return self.model.jenkinsSettings.connection != nil && self.model.jenkinsSettings.enteredToken.isEmpty && self.model.jenkinsSettings.error == nil && self.model.jenkinsSettings.username == self.model.jenkinsSettings.connection?.username
        default: return true
        }
    }
    func next(skip: Bool = false) {
        guard self.step != 0 || self.canContinue else { return }
        guard skip ? !self.working && !self.model.ciSettings.checking && !self.model.jenkinsSettings.checking : self.canContinue else { return }
        if self.step == 2 { self.statuses["setup.gitlab"] = skip ? "setup.skipped" : "setup.connected"; if skip { self.model.ciSettings.enteredToken = ""; self.model.ciSettings.invalidate() } }
        if self.step == 3 { self.statuses["setup.jenkins"] = skip ? "setup.skipped" : "setup.connected"; if skip { self.model.jenkinsSettings.enteredToken = "" } }
        self.step = min(self.step + 1, 5)
    }
    func connect() async {
        guard !self.model.admissionsClosed, !self.working else { return }; self.working = true; defer { self.working = false }
        guard let codex else { self.statuses["setup.codex"] = "setup.codex.missing"; return }
        do {
            let root = try MimicPluginExporter.export(app: self.app, readme: text("mcp.install.instructions"), description: text("mcp.plugin.description"), shortDescription: text("mcp.plugin.shortDescription"))
            try await MimicPluginInstaller.install(marketplace: root, codex: codex)
            self.statuses["setup.codex"] = "setup.connected"
        } catch { self.statuses["setup.codex"] = "setup.codex.failed" }
    }
    func apply() async {
        guard !self.model.admissionsClosed, !self.working, let path = self.model.project?.path else { return }
        self.working = true; defer { self.working = false }
        do {
            try MimicSetupRules.update(project: path, enabled: self.autoOpen, home: self.home)
            var choices = self.defaults.dictionary(forKey: "setupAutoOpen") as? [String: Bool] ?? [:]
            choices[path] = self.autoOpen; self.defaults.set(choices, forKey: "setupAutoOpen")
            self.statuses["setup.autoOpen"] = self.autoOpen ? "setup.enabled" : "setup.disabled"
        } catch { self.statuses["setup.autoOpen"] = "setup.rules.failed" }
        self.defaults.set(self.login, forKey: "setupLoginChoice")
        do {
            let previouslyRegistered = self.system.loginStatus == "setup.enabled" || self.system.loginStatus == "setup.approval"
            try await self.system.setLogin(enabled: self.login)
            if self.login && !previouslyRegistered { self.defaults.set(true, forKey: "setupOwnsLogin") }
            if !self.login { self.defaults.set(false, forKey: "setupOwnsLogin") }
            self.statuses["setup.login"] = self.system.loginStatus
        } catch { self.statuses["setup.login"] = "setup.login.failed" }
        self.defaults.set(self.notify, forKey: "setupNotificationChoice")
        let notificationStatus = await self.system.notifications(enabled: self.notify)
        self.defaults.set(self.notify && notificationStatus == "setup.enabled", forKey: "setupNotifications")
        self.statuses["setup.notify"] = notificationStatus
        self.statuses["setup.codex"] = self.statuses["setup.codex"] ?? "setup.skipped"
        self.step = 5; self.finished = true
    }
    /// Keeps credentials and history; partial failures remain visible and retryable.
    func uninstall() async {
        guard !self.model.admissionsClosed, !self.working else { return }; self.working = true; defer { self.working = false }
        if let codex {
            do { try await MimicPluginInstaller.uninstall(codex: codex); self.statuses["setup.codex"] = "setup.disabled" }
            catch { self.statuses["setup.codex"] = "setup.codex.removeFailed" }
        } else { self.statuses["setup.codex"] = "setup.codex.missing" }
        var choices = self.defaults.dictionary(forKey: "setupAutoOpen") as? [String: Bool] ?? [:]
        // Also cover the pilot rule when it has not yet been migrated by this wizard.
        let paths = Set(choices.keys).union(self.model.project.map { [$0.path] } ?? [])
        var failed = false
        for path in paths {
            do { try MimicSetupRules.update(project: path, enabled: false, home: self.home); choices[path] = nil }
            catch { failed = true }
        }
        self.defaults.set(choices, forKey: "setupAutoOpen")
        self.statuses["setup.autoOpen"] = failed ? "setup.rules.failed" : "setup.disabled"
        if self.defaults.bool(forKey: "setupOwnsLogin") {
            do { try await self.system.setLogin(enabled: false); self.defaults.set(false, forKey: "setupOwnsLogin"); self.statuses["setup.login"] = self.system.loginStatus }
            catch { self.statuses["setup.login"] = "setup.login.failed" }
        }
        self.step = 5; self.finished = true
    }
    var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return "Mimic \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n" + self.statuses.keys.sorted().map { text($0) + ": " + text(self.statuses[$0] ?? "setup.skipped") }.joined(separator: "\n")
    }
}

struct MimicSetupView: View {
    private var theme = MimicTheme()
    @ObservedObject var setup: MimicSetupModel
    @ObservedObject var model: TaskCoordinator
    let uninstallMode: Bool
    let close: () -> Void
    @State private var confirming = false
    private let steps = ["setup.project", "setup.codex", "setup.gitlab", "setup.jenkins", "setup.options", "setup.summary"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(text("setup.title")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(text(self.steps[self.setup.step])).font(.headline).accessibilityIdentifier("setup.step")
            if model.appearance.selection == .tileGrid {
                HStack(spacing: 5) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, key in
                        VStack(spacing: 5) {
                            Capsule().fill(index <= setup.step ? Color(nsColor: MimicTheme.adaptive("accent")) : Color(nsColor: MimicTheme.adaptive("line"))).frame(height: 3)
                            Text(text(key)).font(.system(size: 10)).lineLimit(2)
                        }.accessibilityHidden(true)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if self.uninstallMode && !self.setup.finished {
                        Text(text("setup.uninstall.detail"))
                        Button(text("setup.uninstall")) { self.confirming = true }.disabled(self.setup.working).accessibilityIdentifier("setup.uninstall")
                    } else {
                        switch self.setup.step {
                        case 0:
                            ProfileSection(model: self.model)
                            Text(text("setup.project.detail"))
                            Text(self.model.project?.path ?? text("setup.project.none")).textSelection(.enabled)
                            Button(text("project.add")) { self.model.chooseProject() }.disabled(self.model.checking || self.model.switchingBranch)
                            if !self.model.message.isEmpty { Text(self.model.message).foregroundStyle(.orange) }
                        case 1:
                            Text(text("setup.codex.detail"))
                            Button(text("mcp.connect")) { Task { await self.setup.connect() } }.disabled(self.setup.working).accessibilityIdentifier("setup.connect")
                            self.status("setup.codex")
                        case 2: CISettingsView(settings: self.model.ciSettings, hasCheckout: self.model.project != nil)
                        case 3: JenkinsSettingsView(settings: self.model.jenkinsSettings)
                        case 4:
                            Toggle(text("setup.autoOpen"), isOn: self.$setup.autoOpen).accessibilityIdentifier("setup.autoOpen")
                            Text(text("setup.autoOpen.detail")).font(.callout).foregroundStyle(.secondary)
                            Toggle(text("setup.login"), isOn: self.$setup.login).accessibilityIdentifier("setup.login")
                            Toggle(text("setup.notify"), isOn: self.$setup.notify).accessibilityIdentifier("setup.notify")
                            Text(text("setup.options.detail")).font(.callout).foregroundStyle(.secondary)
                        default:
                            Text(text("setup.summary.detail"))
                            ForEach(self.setup.statuses.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading, spacing: 4) { Text(text(key)).bold(); self.status(key) }
                            }
                            Text(text("setup.autoOpen.notRun")).font(.callout).foregroundStyle(.secondary)
                            Button(text("setup.copyReport")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.setup.report, forType: .string) }
                            Button(text("setup.systemSettings")) { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    if self.setup.working || self.model.ciSettings.checking || self.model.jenkinsSettings.checking { ProgressView().accessibilityLabel(text("setup.working")) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if !self.uninstallMode && self.setup.step > 0 { Button(text("setup.back")) { self.setup.step -= 1 }.disabled(self.setup.working || self.model.ciSettings.checking || self.model.jenkinsSettings.checking) }
                Spacer()
                if self.uninstallMode || self.setup.step == 5 { Button(text("setup.close"), action: self.close).disabled(self.setup.working) }
                else {
                    if (1...3).contains(self.setup.step) { Button(text("setup.skip")) { self.setup.next(skip: true) }.disabled(self.setup.working || self.model.ciSettings.checking || self.model.jenkinsSettings.checking) }
                    Button(text(self.setup.step == 4 ? "setup.apply" : "setup.next")) {
                        if self.setup.step == 4 { Task { await self.setup.apply() } } else { self.setup.next() }
                    }.disabled(!self.setup.canContinue).keyboardShortcut(.defaultAction).accessibilityIdentifier("setup.next")
                }
            }
        }.padding(24).frame(minWidth: 560, minHeight: 520).disabled(self.model.updateReserved)
            .buttonStyle(MimicAuxiliaryButtonStyle())
            .onChange(of: self.model.selectedProjectPath) { _, _ in self.setup.selectionChanged() }
            .background(model.appearance.selection == .tileGrid ? Color(nsColor: MimicTheme.adaptive("paper")) : Color(nsColor: .windowBackgroundColor))
            .modifier(MimicAppearanceRoot(store: model.appearance))
            .confirmationDialog(text("setup.uninstall"), isPresented: self.$confirming) {
                Button(text("setup.uninstall"), role: .destructive) { Task { await self.setup.uninstall() } }
            } message: { Text(text("setup.uninstall.detail")) }
    }
    private func status(_ key: String) -> some View {
        Text(text(self.setup.statuses[key] ?? "setup.skipped")).textSelection(.enabled).accessibilityIdentifier("setup.status." + key)
    }
}

/// Observes transitions only; historical results are never re-notified when the app starts.
@MainActor final class MimicTaskNotifications {
    private let defaults: UserDefaults
    private var previous: [UUID: TaskStatus] = [:]
    private var remote: [UUID: String] = [:]
    private let deliver: (@MainActor (UUID, Bool) -> Void)?
    init(defaults: UserDefaults = .standard, deliver: (@MainActor (UUID, Bool) -> Void)? = nil) { self.defaults = defaults; self.deliver = deliver }
    func update(records: [TaskRecord], runs: [RemoteTestRun]) {
        for record in records {
            if let old = self.previous[record.id], old != record.status, record.status == .succeeded || record.status == .failed {
                self.send(id: record.id, success: record.status == .succeeded)
            }
        }
        for run in runs {
            if let old = self.remote[run.id], old != run.status, run.status == "SUCCESS" || run.status == "FAILURE" || run.status == "success" || run.status == "failed" {
                self.send(id: run.id, success: run.status == "SUCCESS" || run.status == "success")
            }
        }
        self.previous = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.status) })
        self.remote = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0.status) })
    }
    private func send(id: UUID, success: Bool) {
        guard self.defaults.bool(forKey: "setupNotifications") else { return }
        if let deliver { deliver(id, success); return }
        let content = UNMutableNotificationContent(); content.title = text("app.name")
        content.body = text(success ? "setup.notification.success" : "setup.notification.failure"); content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)) { _ in }
    }
}
