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

    static func image(marker: Marker = .none) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(self.outline)
            context.fillPath()
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
