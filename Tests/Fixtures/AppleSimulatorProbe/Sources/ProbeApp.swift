//
//  ProbeApp.swift
//  MimicAppleFixture
//
//  Created by Василий Маслов on 04.10.2026.
import SwiftUI

/// Disposable app with deterministic controls for the native Apple interaction acceptance gate.
@main struct ProbeApp: App {
    var body: some Scene { WindowGroup { ProbeScreen() } }
}
private struct ProbeScreen: View {
    @State private var text = ""
    @State private var count = 0
    var body: some View {
        NavigationStack {
            Form {
                Section("probe.input") {
                    TextField("probe.placeholder", text: self.$text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("probe.text-input")
                    Text(self.text).accessibilityIdentifier("probe.entered-text")
                    Button("probe.clear") { self.text = "" }
                        .accessibilityIdentifier("probe.clear")
                }
                Section("probe.actions") {
                    Button("probe.increment") { self.count += 1 }
                        .accessibilityIdentifier("probe.increment")
                    Text(String(format: NSLocalizedString("probe.count", comment: ""), self.count))
                        .accessibilityIdentifier("probe.counter")
                }
                Section("probe.scroll") {
                    ForEach(0..<40, id: \.self) { index in
                        Text(String(format: NSLocalizedString("probe.row", comment: ""), index))
                            .accessibilityIdentifier("probe.row.\(index)")
                    }
                }
            }
            .navigationTitle("probe.title")
        }
    }
}
