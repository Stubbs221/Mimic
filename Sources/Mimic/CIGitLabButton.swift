//
//  CIGitLabButton.swift
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import AppKit
import SwiftUI

/// Official GitLab mark, preserving the press-kit silhouette in the surrounding control color.
/// Source: https://about.gitlab.com/images/press/gitlab-logo-500-rgb.svg
struct GitLabMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 164, size.height / 156)
            let transform = CGAffineTransform(translationX: -108, y: -112)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (size.width - 164 * scale) / 2, y: (size.height - 156 * scale) / 2))
            context.fill(Self.layer0().applying(transform), with: .foreground)
        }.accessibilityHidden(true)
    }

    private static func layer0() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 265.26416, y: 174.37243))
        path.addLine(to: CGPoint(x: 265.05076, y: 173.81421))
        path.addLine(to: CGPoint(x: 243.85177, y: 118.50513))
        path.addCurve(to: CGPoint(x: 241.67478, y: 115.87824), control1: CGPoint(x: 243.42817, y: 117.42154), control2: CGPoint(x: 242.66635, y: 116.50871))
        path.addCurve(to: CGPoint(x: 238.35173, y: 115.0081), control1: CGPoint(x: 240.68641, y: 115.24451), control2: CGPoint(x: 239.52729, y: 114.94571))
        path.addCurve(to: CGPoint(x: 235.14364, y: 116.22631), control1: CGPoint(x: 237.18283, y: 115.07049), control2: CGPoint(x: 236.05978, y: 115.49735))
        path.addCurve(to: CGPoint(x: 233.26871, y: 119.07977), control1: CGPoint(x: 234.23407, y: 116.96185), control2: CGPoint(x: 233.57735, y: 117.95678))
        path.addLine(to: CGPoint(x: 218.95544, y: 162.88639))
        path.addLine(to: CGPoint(x: 161.04579, y: 162.88639))
        path.addLine(to: CGPoint(x: 146.73252, y: 119.07977))
        path.addCurve(to: CGPoint(x: 144.85759, y: 116.22631), control1: CGPoint(x: 146.42388, y: 117.95678), control2: CGPoint(x: 145.76716, y: 116.96186))
        path.addCurve(to: CGPoint(x: 141.6495, y: 115.0081), control1: CGPoint(x: 143.94145, y: 115.49736), control2: CGPoint(x: 142.81848, y: 115.07049))
        path.addCurve(to: CGPoint(x: 138.32653, y: 115.87824), control1: CGPoint(x: 140.47402, y: 114.94571), control2: CGPoint(x: 139.31482, y: 115.24451))
        path.addCurve(to: CGPoint(x: 136.14946, y: 118.50513), control1: CGPoint(x: 137.33487, y: 116.50871), control2: CGPoint(x: 136.57305, y: 117.42154))
        path.addLine(to: CGPoint(x: 114.95055, y: 173.8175))
        path.addLine(to: CGPoint(x: 114.73707, y: 174.37243))
        path.addCurve(to: CGPoint(x: 127.79598, y: 219.86025), control1: CGPoint(x: 108.45549, y: 190.75764), control2: CGPoint(x: 113.80778, y: 209.28046))
        path.addCurve(to: CGPoint(x: 127.8715, y: 219.91607), control1: CGPoint(x: 127.82219, y: 219.87666), control2: CGPoint(x: 127.8452, y: 219.89636))
        path.addLine(to: CGPoint(x: 128.05869, y: 220.05726))
        path.addLine(to: CGPoint(x: 160.34963, y: 244.23118))
        path.addLine(to: CGPoint(x: 176.32114, y: 256.32142))
        path.addLine(to: CGPoint(x: 186.04065, y: 263.67013))
        path.addCurve(to: CGPoint(x: 193.96067, y: 263.67013), control1: CGPoint(x: 188.38182, y: 265.44329), control2: CGPoint(x: 191.61942, y: 265.44329))
        path.addLine(to: CGPoint(x: 203.6801, y: 256.32142))
        path.addLine(to: CGPoint(x: 219.64832, y: 244.23118))
        path.addLine(to: CGPoint(x: 252.12974, y: 219.91607))
        path.addCurve(to: CGPoint(x: 252.21512, y: 219.85039), control1: CGPoint(x: 252.15932, y: 219.89308), control2: CGPoint(x: 252.18562, y: 219.87338))
        path.addCurve(to: CGPoint(x: 265.26417, y: 174.37243), control1: CGPoint(x: 266.19346, y: 209.27062), control2: CGPoint(x: 271.54247, y: 190.75435))
        path.closeSubpath()
        return path
    }

}

/// This independent control never forwards its click to a run's disclosure action.
struct CIGitLabButton: View {
    let url: URL
    @Environment(\.mimicTextScale) private var textScale
    var body: some View {
        Button {
            guard ["http", "https"].contains(self.url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(self.url)
        } label: {
            GitLabMark().foregroundStyle(.secondary).frame(width: 18 * self.textScale, height: 18 * self.textScale).frame(width: 28 * self.textScale, height: 28 * self.textScale)
        }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets()))
            .background(PanelControlRegion())
            .mimicHelp(text("ci.open.gitlab"))
            .accessibilityLabel(text("ci.open.gitlab"))
            .accessibilityIdentifier("ci.gitlab")
    }
}
