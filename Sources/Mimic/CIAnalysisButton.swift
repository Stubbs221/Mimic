//
//  CIAnalysisButton.swift
//  Mimic
//
//  Created by Василий Маслов on 28.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Opens the captured CI request in Codex; native CI analysis never launches an AI CLI.
struct CIAnalysisButton: View {
    let model: TaskCoordinator
    let summary: CICompactSummary
    @State private var presented = false
    @State private var snapshot: CIAnalysisSnapshot?
    @State private var copied = false
    @State private var lastOpenedAt: Date?
    @State private var failure: String?
    @Environment(\.mimicTextScale) private var textScale
    private var theme = MimicTheme()

    var body: some View {
        Button {
            guard self.lastOpenedAt.map({ Date().timeIntervalSince($0) >= 1 }) ?? true else { return }
            self.lastOpenedAt = Date()
            do {
                let snapshot = try self.model.ciAnalysisSnapshot(self.summary)
                self.snapshot = snapshot; self.failure = nil
                let result = CIAnalysisHandoff.open(snapshot)
                self.copied = result.copied; self.presented = !result.opened
            } catch { self.snapshot = nil; self.failure = text("ci.analysis.unavailable"); self.presented = true }
        } label: {
            HStack(spacing: 4 * self.textScale) {
                CIAnalysisSparkles().frame(width: 14 * self.textScale, height: 14 * self.textScale)
                Text(text("ci.analysis.action")).mimicFont(.caption, weight: .semibold).fixedSize()
            }.foregroundStyle(self.theme.color("accent"))
                .frame(width: (self.textScale > 1 ? 78 : 84) * self.textScale, height: 28 * self.textScale)
                .background(self.theme.color("accent").opacity(0.12), in: RoundedRectangle(cornerRadius: self.theme.retro ? 0 : 10))
        }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets()))
            .background(PanelControlRegion()).mimicHelp(text("ci.analysis.codex.help"))
            .accessibilityLabel(text("ci.analysis.codex.help") + " · " + (self.summary.displayID ?? self.summary.id))
            .accessibilityIdentifier("ci.analysis")
            .popover(isPresented: self.$presented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text("ci.analysis.title")).mimicFont(.heading)
                    if let snapshot = self.snapshot {
                        Text((snapshot.summary.displayID ?? snapshot.summary.id) + " · " + snapshot.summary.branch)
                            .mimicFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(text("ci.analysis.codex.unavailable")).foregroundStyle(.orange)
                        if self.copied { Text(text("ai.copied")).foregroundStyle(.secondary) }
                        HStack(spacing: 8) {
                            Button(text("ai.copy.request")) { self.copied = CIAnalysisHandoff.copy(snapshot) }
                                .buttonStyle(BootstrapControlStyle()).accessibilityIdentifier("ci.analysis.copy")
                            Button(text("ci.analysis.codex.open")) {
                                let result = CIAnalysisHandoff.open(snapshot)
                                self.copied = result.copied; self.presented = !result.opened
                            }.buttonStyle(BootstrapControlStyle(primary: true)).accessibilityIdentifier("ci.analysis.openCodex")
                        }
                    } else if let failure { Text(failure).foregroundStyle(.orange) }
                }.mimicFont(.body).padding(16).frame(width: 360, alignment: .leading)
                    .accessibilityIdentifier("ci.analysis.popover")
            }
    }
}

/// The two editable sparkles in the approved design, drawn in the current application accent.
struct CIAnalysisSparkles: Shape {
    func path(in rect: CGRect) -> Path {
        var main = Path()
        main.addLines([CGPoint(x: 10, y: 5), CGPoint(x: 12.4, y: 11.6), CGPoint(x: 19, y: 14), CGPoint(x: 12.4, y: 16.4), CGPoint(x: 10, y: 23), CGPoint(x: 7.6, y: 16.4), CGPoint(x: 1, y: 14), CGPoint(x: 7.6, y: 11.6)])
        main.closeSubpath()
        var path = main.strokedPath(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        var small = Path()
        small.addLines([CGPoint(x: 19, y: 1), CGPoint(x: 20.1, y: 4), CGPoint(x: 23, y: 5), CGPoint(x: 20.1, y: 6.1), CGPoint(x: 19, y: 9), CGPoint(x: 17.9, y: 6.1), CGPoint(x: 15, y: 5), CGPoint(x: 17.9, y: 4)])
        small.closeSubpath(); path.addPath(small)
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

/// Clipboard and URL carry the same sanitized immutable request. Opening a draft is not proof of sending it.
@MainActor enum CIAnalysisHandoff {
    static func copy(_ snapshot: CIAnalysisSnapshot, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(snapshot.prompt(fragment: snapshot.text, comment: ""), forType: .string)
    }
    static func open(_ snapshot: CIAnalysisSnapshot, pasteboard: NSPasteboard = .general, openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> (copied: Bool, opened: Bool) {
        let copied = self.copy(snapshot, pasteboard: pasteboard)
        let opened = snapshot.newChatURL.map(openURL) ?? false
        return (copied, opened)
    }
}

extension TaskCoordinator {
    /// Capture the authoritative run in its original account scope, independently of desktop selection.
    func ciAnalysisSnapshot(_ requested: CICompactSummary) throws -> CIAnalysisSnapshot {
        guard let state = self.ciMonitor.state(for: requested),
              let entry = state.inspectPersonalEntry(requested.id, viewer: "native.analysis"),
              var summary = state.compactSummary(for: entry), summary.identity == requested.identity,
              summary.canAnalyze else { throw CIError.notFound }
        summary.checkout = requested.checkout
        let snapshot = CIAnalysisSnapshot(summary: summary, connection: state.context?.connection)
        try CIAnalysisSnapshotStore(root: self.builds.artifactRoot).save(snapshot)
        return snapshot
    }
}
