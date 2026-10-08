// Created by Василий Маслов on 02.10.2026.
import SwiftUI
import MimicCore

struct BootstrapIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var inControlBar = false
    var body: some View {
        Group {
            if self.inControlBar {
                Button(action: self.action) { self.symbolView.frame(width: 32, height: 32) }
                    .buttonStyle(RowButtonStyle(contentInsets: EdgeInsets()))
            } else {
                Button(action: self.action) { self.symbolView.frame(width: 24, height: 24) }
                    .buttonStyle(MimicButtonStyle(icon: true))
            }
        }.help(self.label).accessibilityLabel(self.label)
    }

    private var symbolView: some View {
        Image(systemName: self.symbol).font(.system(size: 13, weight: .semibold)).contentShape(Circle())
    }
}

/// Execution stays pinned to the request, independently of the selected checkout.
struct QuickBootstrapView: View {
    @ObservedObject
    var model: TaskCoordinator
    let showMimic: () -> Void
    var framed = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let activity = model.quickBootstrapActivity {
                let record = activity.record(in: self.model.records)
                MimicChrome { HStack(spacing: MimicMetrics.medium) {
                    Text(text("quick.bootstrap." + record.options.platform.rawValue)).mimicFont(.heading).allowsHitTesting(false)
                    Spacer(minLength: 0)
                    BootstrapIconButton(symbol: "terminal", label: text("terminal.show"), action: { self.model.showHistory(id: record.id, focusTerminal: true) }, inControlBar: true)
                        .disabled(!self.model.records.contains { $0.id == record.id })
                    if activity.error == nil, record.status == .queued || record.status == .running {
                        BootstrapIconButton(symbol: "stop.fill", label: text("stop"), action: { self.model.cancelQuickBootstrap(id: record.id) }, inControlBar: true)
                    }
                } }
                HStack {
                    BootstrapStateText(model: self.model, record: record)
                    Spacer(minLength: 4)
                    MimicActivityClock(running: record.status == .running && record.startedAt != nil) { _ in
                        Text(record.startedAt == nil ? "" : duration(record)).font(MimicMetrics.secondary.monospacedDigit()).foregroundStyle(.secondary)
                    }.mimicImmediate()
                }.allowsHitTesting(false)
                if let error = activity.error {
                    Text(error).mimicFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).mimicStatus(error).allowsHitTesting(false)
                } else if activity.isPreparing(in: self.model.records) {
                    BootstrapFillBar(value: 0)
                } else if record.status == .queued {
                    BootstrapPreparationView(model: self.model, record: record, showCancel: false, showState: false)
                    BootstrapFillBar(value: 0)
                } else if record.status == .running {
                    BootstrapExecutionProgress(model: self.model, record: record, compact: true, showState: false).allowsHitTesting(false)
                } else if let error = record.error {
                    Text(error).mimicFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).mimicStatus(error).allowsHitTesting(false)
                }
            }
        }.padding(MimicMetrics.cardInsets).frame(width: MimicMetrics.cardWidth).fixedSize(horizontal: false, vertical: true)
            .mimicFont(.body).tint(.indigo).buttonStyle(MimicButtonStyle())
            .background(CardMouseSurface(open: self.showMimic))
            .modifier(QuickBootstrapFrame(framed: self.framed))
            .accessibilityIdentifier("bootstrap.quick.activity")
    }
}

private struct QuickBootstrapFrame: ViewModifier {
    let framed: Bool
    func body(content: Content) -> some View {
        if self.framed { content.modifier(MimicCardBackground()) }
        else { content }
    }
}

/// Background tracking excludes controls. Native window dragging never invokes the click action.
struct CardMouseSurface: NSViewRepresentable {
    let open: () -> Void
    var label = text("quick.toolbox")
    func makeNSView(context: Context) -> MouseSurface { MouseSurface(open: self.open, label: self.label) }
    func updateNSView(_ view: MouseSurface, context: Context) { view.open = self.open; view.setAccessibilityLabel(self.label) }
    final class MouseSurface: NSView {
        var open: () -> Void
        init(open: @escaping () -> Void, label: String) { self.open = open; super.init(frame: .zero); setAccessibilityLabel(label); setAccessibilityRole(.button) }
        required init?(coder: NSCoder) { nil }
        override func accessibilityPerformPress() -> Bool { self.open(); return true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let point = event.locationInWindow
            // Commit to one action before handing event tracking to AppKit.
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let distance = hypot(next.locationInWindow.x - point.x, next.locationInWindow.y - point.y)
                if distance >= 4 {
                    if next.type == .leftMouseDragged {
                        (window as? PersistentBootstrapPanel)?.beginDrag?()
                        window.performDrag(with: event)
                    }
                    return
                }
                if next.type == .leftMouseUp {
                    if self.bounds.contains(self.convert(next.locationInWindow, from: nil)) { self.open() }
                    return
                }
            }
        }
    }
}

/// Equal, evidence-based segments; zero has no visible fill and only real progress values are interpolated.
struct BootstrapFillBar: View {
    let value: Double
    var color: Color = .indigo
    var body: some View {
        MimicProgressBar(value: self.value, color: self.color, label: text("bootstrap.progress"))
    }
}

/// Shared internal track: unknown evidence stays neutral, and progress changes only the fill transform.
struct MimicProgressBar: View {
    let value: Double?
    let color: Color
    let label: String
    @Environment(\.colorSchemeContrast)
    private var contrast
    private var motion = MimicMotion()
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule().fill(self.color).frame(width: proxy.size.width)
                    .scaleEffect(x: min(1, max(0, self.value ?? 0)), y: 1, anchor: .leading)
                    .animation(self.motion.policy(.automatic).animation(.progress), value: self.value)
                Capsule().stroke(Color.primary.opacity(self.contrast == .increased ? 0.6 : 0.15), lineWidth: 0.5)
            }
        }.frame(height: 6).accessibilityElement().accessibilityLabel(self.label)
            .accessibilityValue(self.value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? text("ci.progress.unavailable"))

    }
}
