//
//  MimicIntegrationViews.swift
//  Mimic
//
//  Created by Василий Маслов on 04.10.2026.
import SwiftUI
import MimicCore

struct JenkinsSettingsView: View {
    @ObservedObject var settings: JenkinsSettings
    var framed = true
    var body: some View {
        SettingsFormContainer(framed: self.framed) {
            CIConnectionForm(service: "Jenkins", connected: self.settings.connection != nil,
                             checking: self.settings.checking, verified: self.settings.verified,
                             error: self.settings.error.map { text($0.localizationKey) },
                             check: self.settings.check, save: self.settings.save, disconnect: self.settings.disconnect,
                             identifier: "jenkins") {
                SettingsField(title: text("settings.field.server")) {
                    TextField(text("ci.server"), text: self.$settings.address).textFieldStyle(.roundedBorder)
                        .mimicFont(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("jenkins.address")
                }
                SettingsField(title: text("jenkins.username")) {
                    TextField(text("settings.jenkins.username.placeholder"), text: self.$settings.username).accessibilityIdentifier("jenkins.username")
                }
                Text(text("jenkins.username.help")).mimicFont(.caption).foregroundStyle(.secondary)
                SettingsField(title: text("jenkins.token")) {
                    SecureField(text(self.settings.connection == nil ? "settings.token.placeholder" : "ci.token.replace"), text: self.$settings.enteredToken)
                        .accessibilityIdentifier("jenkins.token")
                }
                Text(text("settings.jenkins.token.detail")).mimicFont(.caption).foregroundStyle(.secondary)
            } credential: {
                if let connection = self.settings.connection {
                    CICredentialAccessView(session: self.settings.credentialSession, id: connection.id, service: "Jenkins", alwaysShow: true) {
                        await self.settings.requestCredentialAccess()
                    }
                }
            }
        }
    }
}

struct MimicIntegrationSettingsView: View {
    @ObservedObject var integration: MimicIntegration
    var framed = true
    var body: some View {
        SettingsFormContainer(framed: self.framed) {
            VStack(alignment: .leading, spacing: 8) {
                Label(text("mcp.settings"), systemImage: "bubble.left.and.bubble.right").mimicFont(.heading)
                Text(text("mcp.settings.detail")).mimicFont(.caption).foregroundStyle(.secondary)
                Button(text("mcp.connect")) { self.integration.exportPlugin() }.accessibilityIdentifier("mcp.connect").disabled(self.integration.connecting)
                if self.integration.connecting { ProgressView().controlSize(.small).accessibilityLabel(text("mcp.connect")) }
                if !self.integration.connectionMessage.isEmpty { Text(self.integration.connectionMessage).mimicFont(.caption).textSelection(.enabled) }
            }
        }
    }
}
