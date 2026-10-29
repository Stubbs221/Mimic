//
//  BootstrapMintRecoveryView.swift
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import SwiftUI
import MimicCore

/// The approved recovery action stays directly available on every native card size.
struct BootstrapMintRecoveryView: View {
    @ObservedObject var model: TaskCoordinator
    var compact = false

    var body: some View {
        if let record = self.model.mintRecoveryRecord {
            let admitted = self.model.records.contains { $0.id == record.id }
            let installing = admitted && [.queued, .running].contains(record.status)
            let admissionError = self.model.quickBootstrapActivity?.error
            let failed = admitted && !installing || admissionError != nil
            VStack(alignment: .leading, spacing: self.compact ? 4 : 8) {
                Label(text(installing ? "bootstrap.mint.installing" : failed ? "bootstrap.mint.failed.title" : "bootstrap.mint.missing"),
                      systemImage: installing ? "arrow.down.circle" : "exclamationmark.triangle")
                    .mimicFont(.caption, weight: .semibold).foregroundStyle(installing ? Color.indigo : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !self.compact {
                    Text(admissionError ?? text(installing ? "bootstrap.mint.continuing" : failed ? "bootstrap.mint.failed" : "bootstrap.mint.explanation"))
                        .mimicFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !installing {
                    Button(text(failed ? "bootstrap.mint.retry" : self.compact ? "bootstrap.mint.install.short" : "bootstrap.mint.install")) {
                        self.model.installMintAndContinue()
                    }.buttonStyle(BootstrapControlStyle(primary: true, fillsWidth: true))
                        .disabled(!self.model.canInstallMint)
                        .accessibilityIdentifier("bootstrap.mint.install").background(PanelControlRegion())
                }
            }.accessibilityIdentifier("bootstrap.mint.recovery")
        }
    }
}
