//
//  ProbeApp.swift
//  MimicAppleFixture
//
//  Created by Василий Маслов on 04.10.2026.
import SwiftUI
import UIKit

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
                Section("Video acceptance") {
                    VideoProbeAnimation()
                }
                KeyboardProbeSection()
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

// MARK: - Continuous video acceptance fixture

/// A deterministic sixty-Hz timeline changes pixels without mutating the keyboard fixture's state.
private struct VideoProbeAnimation: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let phase = seconds.truncatingRemainder(dividingBy: 2) / 2
            VStack(alignment: .leading, spacing: 6) {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.indigo.opacity(0.16)))
                    let x = phase * max(0, size.width - 24)
                    let y = (sin(seconds * .pi) + 1) * max(0, size.height - 24) / 2
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 24, height: 24)), with: .color(.orange))
                    context.fill(Path(CGRect(x: x, y: 0, width: 3, height: size.height)), with: .color(.blue))
                }
                .frame(height: 64)
                Text("Frame \(Int(seconds * 60) % 100_000)")
                    .font(.caption.monospacedDigit())
            }
        }
        .accessibilityIdentifier("probe.video-animation")
    }
}

// MARK: - Observable keyboard acceptance fixture

/// Reports the real UIKit selection and submit callback, so control characters alone cannot pass the gate.
private struct KeyboardProbeSection: View {
    @State private var report = ""
    @State private var command = 0
    var body: some View {
        Section("Keyboard acceptance") {
            KeyboardProbeField(report: self.$report, command: self.command)
                .frame(height: 38)
            Text(self.report).accessibilityIdentifier("probe.keyboard-state")
            Button("keyboard.reset-end") { self.command = (self.command / 10 + 1) * 10 + 1 }
            Button("keyboard.reset-middle") { self.command = (self.command / 10 + 1) * 10 + 2 }
            Button("keyboard.clear") { self.command = (self.command / 10 + 1) * 10 + 3 }
        }
    }
}

private struct KeyboardProbeField: UIViewRepresentable {
    @Binding var report: String
    let command: Int
    func makeCoordinator() -> Coordinator { Coordinator(report: self.$report) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.accessibilityIdentifier = "probe.keyboard-field"
        field.placeholder = "Keyboard probe"
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        let owner = context.coordinator
        owner.report = self.$report
        guard owner.command != self.command else { return }
        owner.command = self.command
        field.text = self.command % 10 == 3 ? "" : "А😀Б"
        field.becomeFirstResponder()
        let offset = self.command % 10 == 2 ? 1 : (field.text ?? "").utf16.count
        if let position = field.position(from: field.beginningOfDocument, offset: offset) {
            field.selectedTextRange = field.textRange(from: position, to: position)
        }
        // SwiftUI is updating the representable; publish only after that transaction completes.
        DispatchQueue.main.async { owner.changed(field) }
    }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var report: Binding<String>
        var command = -1
        private var returns = 0
        init(report: Binding<String>) { self.report = report }
        @objc func changed(_ field: UITextField) {
            let selected = field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) } ?? -1
            let scalars = (field.text ?? "").unicodeScalars.map { String($0.value, radix: 16, uppercase: true) }.joined(separator: ",")
            self.report.wrappedValue = "SCALARS=\(scalars);CURSOR=\(selected);RETURNS=\(self.returns)"
        }
        func textFieldDidChangeSelection(_ textField: UITextField) { self.changed(textField) }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            self.returns += 1
            self.changed(textField)
            return false
        }
    }
}
