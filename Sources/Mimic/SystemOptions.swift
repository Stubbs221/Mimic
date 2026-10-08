// Created by Василий Маслов on 08.10.2026.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// Regular settings use the wizard's existing service and preference keys.
@MainActor final class MimicSystemOptions: ObservableObject {
    @Published private(set) var login = "setup.disabled"
    @Published private(set) var notifications = "setup.disabled"
    @Published private(set) var working = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let system: any MimicSetupSystem
    init(defaults: UserDefaults, system: any MimicSetupSystem = NativeMimicSetupSystem()) {
        self.defaults = defaults; self.system = system; self.login = system.loginStatus
    }
    func refresh() async {
        login = system.loginStatus
        let authorization = await system.notificationStatus()
        notifications = defaults.bool(forKey: "setupNotifications") ? authorization : authorization == "setup.denied" ? authorization : "setup.disabled"
    }
    func setLogin(_ enabled: Bool) async {
        guard !working else { return }; working = true; error = nil
        defer { working = false }
        do {
            let wasRegistered = login == "setup.enabled" || login == "setup.approval"
            try await system.setLogin(enabled: enabled)
            defaults.set(enabled, forKey: "setupLoginChoice")
            if !enabled || !wasRegistered { defaults.set(enabled, forKey: "setupOwnsLogin") }
        } catch { self.error = "setup.login.failed" }
        await refresh()
    }
    func setNotifications(_ enabled: Bool) async {
        guard !working else { return }; working = true; error = nil
        defer { working = false }
        let status = await system.notifications(enabled: enabled)
        defaults.set(enabled, forKey: "setupNotificationChoice")
        defaults.set(enabled && status == "setup.enabled", forKey: "setupNotifications")
        if enabled && status != "setup.enabled" { error = status }
        await refresh()
    }
}

struct MimicSystemOptionsView: View {
    @ObservedObject var options: MimicSystemOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSwitch(title: text("setup.login"), detail: text(options.login),
                           isOn: Binding(get: { options.login == "setup.enabled" || options.login == "setup.approval" }, set: { enabled in Task { await options.setLogin(enabled) } }),
                           identifier: "settings.login")
            SettingsSwitch(title: text("setup.notify"), detail: text(options.notifications),
                           isOn: Binding(get: { options.notifications == "setup.enabled" }, set: { enabled in Task { await options.setNotifications(enabled) } }),
                           identifier: "settings.notifications")
            if let error = options.error { Text(text(error)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if options.login == "setup.approval" || options.notifications == "setup.denied" {
                Button(text("setup.systemSettings")) {
                    if options.login == "setup.approval" { SMAppService.openSystemSettingsLoginItems() }
                    else if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            }
        }.toggleStyle(.switch).disabled(options.working)
            .task { await options.refresh() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in Task { await options.refresh() } }
    }
}
