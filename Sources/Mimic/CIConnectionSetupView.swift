//
//  CIConnectionSetupView.swift
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import SwiftUI

/// An unconfigured tile opens the credential fields directly, including from Mini and Full.
struct CIConnectionSetupView: View {
    let full: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text(full ? "ci.setup.title" : "ci.setup.compactTitle"))
                .mimicFont(.body, weight: .semibold).fixedSize(horizontal: false, vertical: true)
            if full {
                Text(text("ci.setup.detail")).mimicFont(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(text("ci.setup.addToken"), action: openSettings)
                .buttonStyle(MimicAuxiliaryButtonStyle(primary: true))
                .accessibilityIdentifier("ci.setup.addToken")
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelControlRegion())
            .accessibilityIdentifier("ci.setup")
    }
}
