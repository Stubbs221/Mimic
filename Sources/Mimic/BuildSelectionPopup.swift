//
//  BuildSelectionPopup.swift
//  Mimic
//
//  Created by Василий Маслов on 23.10.2026.
import AppKit
import SwiftUI

/// A native popup whose width follows the form column rather than the selected title's intrinsic width.
struct BuildSelectionPopup: NSViewRepresentable {
    let title: String
    @Binding var selection: String
    let options: [MimicSelectionOption<String>]
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.mimicTextScale) private var textScale
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let view = NSPopUpButton(frame: .zero, pullsDown: false)
        view.bezelStyle = .roundRect; view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.target = context.coordinator; view.action = #selector(Coordinator.choose(_:))
        view.lineBreakMode = .byTruncatingTail; view.setAccessibilityLabel(title)
        return view
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection; context.coordinator.values = options.map(\.value)
        if view.itemTitles != options.map(\.title) { view.removeAllItems(); view.addItems(withTitles: options.map(\.title)) }
        view.selectItem(at: options.firstIndex { $0.value == selection } ?? 0)
        view.font = .systemFont(ofSize: (height > 28 ? 13 : 11) * textScale)
        view.isEnabled = enabled; view.toolTip = options.first { $0.value == selection }?.title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: height * textScale)
    }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<String>
        var values: [String] = []
        init(selection: Binding<String>) { self.selection = selection }
        @objc func choose(_ sender: NSPopUpButton) {
            guard values.indices.contains(sender.indexOfSelectedItem) else { return }
            selection.wrappedValue = values[sender.indexOfSelectedItem]
        }
    }
}
