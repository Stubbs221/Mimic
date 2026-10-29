//
//  StatusIcon.swift
//  Mimic
//
//  Created by Василий Маслов on 02.10.2026.
import AppKit

/// A hollow Mimic face with two eyes and fangs, drawn as a vector template for the menu bar.
@MainActor
enum StatusIcon {
    enum Marker: CaseIterable { case none, paused, failed }

    /// Zero preserves the original mark; one opens the approved double-chew chest fully.
    static func image(marker: Marker = .none, openness: CGFloat = 0) -> NSImage {
        let amount = openness.isFinite ? min(1, max(0, openness)) : 0
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            if amount == 0 {
                context.addPath(self.outline)
                context.fillPath()
            } else { self.drawChest(in: context, openness: amount) }
            if marker != .none {
                // A transparent halo separates the status marker from the face contour.
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: 14.5, y: 0, width: 5.5, height: 5.5))
                context.setBlendMode(.normal)
                if marker == .failed {
                    context.fillEllipse(in: CGRect(x: 15.5, y: 1, width: 3.5, height: 3.5))
                } else {
                    context.fill(CGRect(x: 15.5, y: 1, width: 1.25, height: 3.5))
                    context.fill(CGRect(x: 17.75, y: 1, width: 1.25, height: 3.5))
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = text("app.name")
        return image
    }

    // MARK: - Working chest

    /// A clear lid cuts the fangs out of the mouth band, keeping template pixels transparent in both themes.
    private static func drawChest(in context: CGContext, openness: CGFloat) {
        let lift = 1.5 * openness, drop = 0.3 * openness
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1.35); context.setLineCap(.round); context.setLineJoin(.round)
        let base = CGMutablePath()
        base.move(to: CGPoint(x: 3, y: 10 - drop))
        base.addLine(to: CGPoint(x: 3, y: 7 - drop))
        base.addCurve(to: CGPoint(x: 7, y: 3 - drop), control1: CGPoint(x: 3, y: 4.791 - drop), control2: CGPoint(x: 4.791, y: 3 - drop))
        base.addLine(to: CGPoint(x: 13, y: 3 - drop))
        base.addCurve(to: CGPoint(x: 17, y: 7 - drop), control1: CGPoint(x: 15.209, y: 3 - drop), control2: CGPoint(x: 17, y: 4.791 - drop))
        base.addLine(to: CGPoint(x: 17, y: 10 - drop))
        context.addPath(base); context.strokePath()
        context.fill(CGRect(x: 3, y: 10 - drop, width: 14, height: lift + drop))

        let lid = CGMutablePath()
        lid.move(to: CGPoint(x: 3, y: 10 + lift)); lid.addLine(to: CGPoint(x: 3, y: 13 + lift))
        lid.addCurve(to: CGPoint(x: 7, y: 17 + lift), control1: CGPoint(x: 3, y: 15.209 + lift), control2: CGPoint(x: 4.791, y: 17 + lift))
        lid.addLine(to: CGPoint(x: 13, y: 17 + lift))
        lid.addCurve(to: CGPoint(x: 17, y: 13 + lift), control1: CGPoint(x: 15.209, y: 17 + lift), control2: CGPoint(x: 17, y: 15.209 + lift))
        for point in [CGPoint(x: 17, y: 10), CGPoint(x: 14, y: 10), CGPoint(x: 12.5, y: 7.5), CGPoint(x: 11, y: 10), CGPoint(x: 9, y: 10), CGPoint(x: 7.5, y: 7.5), CGPoint(x: 6, y: 10)] {
            lid.addLine(to: CGPoint(x: point.x, y: point.y + lift))
        }
        lid.closeSubpath()
        context.saveGState(); context.setBlendMode(.clear); context.addPath(lid); context.fillPath(); context.restoreGState()
        context.addPath(lid); context.strokePath()

        context.saveGState(); context.setAlpha(1 - openness)
        for x in [CGFloat(6.85), 13.15] { context.fillEllipse(in: CGRect(x: x - 0.85, y: 12.5 + lift, width: 1.7, height: 1.7)) }
        context.restoreGState()
        context.saveGState(); context.setAlpha(openness); context.setLineWidth(1.3)
        for x in [CGFloat(6.85), 13.15] {
            context.move(to: CGPoint(x: x - 1.05, y: 13.2 + lift))
            context.addLine(to: CGPoint(x: x, y: 14.2 + lift))
            context.addLine(to: CGPoint(x: x + 1.05, y: 13.2 + lift))
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: - Resting mark

    /// Filled stroke outlines keep the interior transparent at every display scale.
    static var outline: CGPath {
        let face = CGMutablePath()
        face.addRoundedRect(in: CGRect(x: 3, y: 3, width: 14, height: 14), cornerWidth: 4, cornerHeight: 4)

        let mouth = CGMutablePath()
        mouth.addLines(between: [
            CGPoint(x: 4, y: 10), CGPoint(x: 6, y: 10),
            CGPoint(x: 7.5, y: 7.5), CGPoint(x: 9, y: 10),
            CGPoint(x: 11, y: 10), CGPoint(x: 12.5, y: 7.5),
            CGPoint(x: 14, y: 10), CGPoint(x: 16, y: 10)
        ])

        let path = CGMutablePath()
        for stroke in [face, mouth] {
            path.addPath(stroke.copy(strokingWithWidth: 1.35, lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
        path.addEllipse(in: CGRect(x: 6, y: 12.5, width: 1.7, height: 1.7))
        path.addEllipse(in: CGRect(x: 12.3, y: 12.5, width: 1.7, height: 1.7))
        return path
    }
}
