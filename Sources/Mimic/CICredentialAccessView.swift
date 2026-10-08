//
//  CICredentialAccessView.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import SwiftUI
import MimicCore

/// One native action owns interactive access; ordinary refreshes stay silent.
struct CICredentialAccessView: View {
    @ObservedObject var session: CICredentialSession
    let id: UUID
    let service: String
    var alwaysShow = false
    var openSettings: (() -> Void)? = nil
    let action: () async -> Void

    var body: some View {
        if let failure = self.session.failures[self.id] {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.service + " · " + text(failure.localizationKey)).foregroundStyle(.orange)
                if failure == .missing, let openSettings {
                    Button(text("settings"), action: openSettings)
                } else {
                    Button(text("credentials.allow")) { Task { await self.action() } }
                        .disabled(self.session.granting.contains(self.id))
                }
            }.mimicFont(.caption)
        } else if self.alwaysShow {
            Button(text("credentials.reload")) { Task { await self.action() } }
                .disabled(self.session.granting.contains(self.id))
        }
    }
}
