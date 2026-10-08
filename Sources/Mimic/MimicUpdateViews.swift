//
//  MimicUpdateViews.swift
//  Mimic
//
//  Created by Василий Маслов on 06.10.2026.
import SwiftUI
import MimicCore

struct MimicUpdateSettings: View {
    @ObservedObject var updater: MimicUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(text("update.title"), value: MimicVersion.version).mimicFont(.heading)
            SettingsSwitch(title: text("update.automatic"), detail: text("update.explanation"),
                           isOn: self.$updater.automatic, identifier: "settings.updates.automatic")
                .disabled(self.updater.state == .unavailable || self.updater.state == .installing)
            Text(self.updater.status).mimicFont(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.updates.status")
            if let progress = self.updater.progress { ProgressView(value: progress).accessibilityLabel(self.updater.status) }
            MimicActionLayout {
                Button(text("update.check")) { self.updater.check() }.disabled(!self.updater.canCheck)
                if self.updater.state == .available {
                    Button(text("update.install")) { self.updater.installAvailable() }
                }
                if self.updater.state == .waiting { Button(text("update.defer")) { self.updater.deferInstallation() } }
            }
        }.accessibilityIdentifier("settings.updates")
    }
}

struct MimicUpdateNotice: View {
    @ObservedObject var updater: MimicUpdater
    var body: some View {
        if [.downloading, .extracting, .waiting, .preparing, .installing, .failed].contains(self.updater.state) {
            HStack(spacing: MimicMetrics.small) {
                Image(systemName: self.updater.state == .failed ? "exclamationmark.triangle" : "arrow.down.circle")
                Text(self.updater.status).mimicFont(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, MimicMetrics.documentInset).padding(.vertical, MimicMetrics.small)
                .accessibilityIdentifier("updates.notice")
        }
    }
}
