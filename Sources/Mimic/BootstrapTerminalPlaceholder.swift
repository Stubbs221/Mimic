// Created by Василий Маслов on 08.10.2026.
import SwiftUI
import MimicCore

/// Presentation only: examples never enter the task's replay or terminal buffer.
enum BootstrapTerminalPlaceholderState {
    case idle, queued, running, unavailable

    static func resolve(status: TaskStatus?, hasOutput: Bool) -> Self? {
        guard !hasOutput else { return nil }
        switch status {
        case nil: return .idle
        case .queued: return .queued
        case .running: return .running
        default: return .unavailable
        }
    }

    var message: String? {
        switch self {
        case .idle: return nil
        case .queued: return text("bootstrap.terminal.queued")
        case .running: return text("bootstrap.terminal.waiting")
        case .unavailable: return text("bootstrap.terminal.unavailable")
        }
    }
    var showsExample: Bool { self == .idle || self == .unavailable }
}

struct BootstrapTerminalPlaceholder: View {
    let state: BootstrapTerminalPlaceholderState
    let platform: BootstrapPlatform
    @Environment(\.mimicTextScale) private var textScale
    @Environment(\.colorSchemeContrast) private var contrast
    private var theme = MimicTheme()

    var body: some View {
        ViewThatFits(in: .vertical) {
            self.content(rows: 3, header: true)
            self.content(rows: 1, header: true)
            self.content(rows: 0, header: true)
            self.content(rows: 0, header: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .foregroundStyle(theme.tiled ? theme.color("terminalText") : Color(nsColor: BootstrapTerminalTheme.foreground))
        .background(theme.tiled ? theme.color("terminal") : Color(nsColor: BootstrapTerminalTheme.background))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([state.showsExample ? text("bootstrap.terminal.example") : nil, state.message].compactMap { $0 }.joined(separator: ". "))
        .accessibilityIdentifier("bootstrap.terminal.placeholder")
    }

    private func content(rows: Int, header: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8 * textScale) {
            if state.showsExample, header {
                Text("BOOTSTRAP / TERMINAL · " + text("bootstrap.terminal.example"))
                    .font(.system(size: 10 * textScale, weight: .semibold)).lineSpacing(2 * textScale)
                    .opacity(contrast == .increased ? 1 : 0.8)
            }
            if state.showsExample, rows > 0 {
                Text((rows == 3 ? ["$ mimic bootstrap " + platform.rawValue, "✓ Dependencies ready", "› Waiting for launch"] : ["$ mimic bootstrap " + platform.rawValue]).joined(separator: "\n"))
                    .font(.system(size: 11 * textScale, design: .monospaced)).lineSpacing(4 * textScale)
                    .opacity(contrast == .increased ? 1 : 0.7).accessibilityHidden(true)
            }
            if let message = state.message {
                Text(message).font(.system(size: 10 * textScale)).lineSpacing(2 * textScale)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// Observe the first byte directly, even when the coordinator's task metadata does not change.
struct BootstrapTaskTerminal: View {
    let model: TaskCoordinator
    let record: TaskRecord
    let visible: Bool
    let fontSize: CGFloat
    @ObservedObject var session: BootstrapTerminalSession

    var body: some View {
        let placeholder = BootstrapTerminalPlaceholderState.resolve(status: record.status, hasOutput: session.hasOutput)
        ZStack {
            BootstrapTerminalContainer(model: model, record: record, visible: visible, fontSize: fontSize)
                .accessibilityHidden(placeholder != nil)
            if let placeholder {
                BootstrapTerminalPlaceholder(state: placeholder, platform: record.options.platform)
            }
        }.transaction { $0.animation = nil }
    }
}
