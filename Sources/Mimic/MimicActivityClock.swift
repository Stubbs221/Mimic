//
//  MimicActivityClock.swift
//  Mimic
//
//  Created by Василий Маслов on 08.10.2026.
import SwiftUI

private struct MimicPresentationVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Retained forms and terminals keep their identity while presentation clocks are suspended.
    var mimicPresentationVisible: Bool {
        get { self[MimicPresentationVisibilityKey.self] }
        set { self[MimicPresentationVisibilityKey.self] = newValue }
    }
}

/// Monitoring and execution own their lifecycle independently from these local text refreshes.
struct MimicActivityClock<Content: View>: View {
    let running: Bool
    @ViewBuilder var content: (Date) -> Content
    @Environment(\.mimicPresentationVisible) private var visible
    var body: some View {
        if running && visible {
            TimelineView(.periodic(from: .now, by: 1)) { content($0.date) }
        } else {
            content(.now)
        }
    }
}
