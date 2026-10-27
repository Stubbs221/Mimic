//
//  ScrollEdge.swift
//  Mimic
//
//  Created by Василий Маслов on 23.10.2026.
import AppKit
import SwiftUI

/// The approved B edge samples the existing native content, including terminal views.
/// Its mask changes only with geometry; scrolling never copies the document.
struct MimicScrollEdge: NSViewRepresentable {
    enum Direction { case top, bottom }
    static let depth: CGFloat = 24

    let direction: Direction
    let color: Color

    func makeNSView(context: Context) -> NativeScrollEdge {
        NativeScrollEdge(direction: direction, color: NSColor(color))
    }

    func updateNSView(_ view: NativeScrollEdge, context: Context) {
        view.update(direction: direction, color: NSColor(color))
    }
}

/// A noninteractive backdrop filter keeps native editors and simulator content live.
final class NativeScrollEdge: NSView {
    private var direction: MimicScrollEdge.Direction
    private var color: NSColor
    private let backdrop = NSVisualEffectView()
    private let tintView = NSView()
    private let tint = CAGradientLayer()
    private var maskSize = CGSize.zero

    init(direction: MimicScrollEdge.Direction, color: NSColor) {
        self.direction = direction
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        backdrop.material = .headerView
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        addSubview(backdrop)
        // A sibling view keeps paper above AppKit's material even when its backing
        // layers are rebuilt after attaching the effect to a window.
        tintView.layer = tint
        tintView.wantsLayer = true
        addSubview(tintView)
        setAccessibilityElement(false)
        updateTint()
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func update(direction: MimicScrollEdge.Direction, color: NSColor) {
        guard self.direction != direction || !self.color.isEqual(color) else { return }
        if self.direction != direction { maskSize = .zero }
        self.direction = direction
        self.color = color
        updateTint()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        tintView.frame = bounds
        CATransaction.commit()
        guard bounds.width > 0, bounds.height > 0, maskSize != bounds.size else { return }
        maskSize = bounds.size
        let direction = self.direction
        // Keep SwiftUI and embedded native views in the system compositor. Core Image
        // backgroundFilters force in-process rendering and can blank a hosting view.
        backdrop.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            let colors = (0...16).map { index -> NSColor in
                let fraction = direction == .top ? CGFloat(index) / 16 : 1 - CGFloat(index) / 16
                return .black.withAlphaComponent(fraction * fraction * (3 - 2 * fraction))
            }
            NSGradient(colors: colors)?.draw(in: rect, angle: 90)
            return true
        }
    }

    private func updateTint() {
        let stops = (0...16).map { CGFloat($0) / 16 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.startPoint = CGPoint(x: 0.5, y: 0)
        tint.endPoint = CGPoint(x: 0.5, y: 1)
        tint.locations = stops.map { NSNumber(value: Double($0)) }
        tint.colors = stops.map { position in
            let fraction = direction == .top ? position : 1 - position
            return color.withAlphaComponent(fraction * fraction * (3 - 2 * fraction)).cgColor
        }
        CATransaction.commit()
    }
}
