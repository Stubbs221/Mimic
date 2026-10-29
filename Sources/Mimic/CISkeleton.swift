//
//  CISkeleton.swift
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import SwiftUI

/// Placeholder motion runs only while a visible region has no usable data.
struct CISkeleton: View {
    var presented = true
    private var accessibility = MimicAccessibility()
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !self.presented || self.accessibility.reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3) { index in
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.12))
                            .overlay {
                                if !self.accessibility.reduceMotion, self.presented {
                                    LinearGradient(colors: [.clear, .primary.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: geometry.size.width / 2)
                                        .offset(x: geometry.size.width * (phase * 2 - 1))
                                }
                            }.clipped()
                    }.frame(height: index == 0 ? 14 : 10).padding(.trailing, index == 1 ? 48 : 0)
                }
            }.padding(.vertical, 8)
        }.accessibilityElement(children: .ignore).accessibilityLabel(text("ci.loading"))
    }
}
