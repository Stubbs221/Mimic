// Created by Василий Маслов on 03.10.2026.
import SwiftUI

/// Shared role for actions in readable content; glass is never applied to the content itself.
struct BootstrapControlStyle: PrimitiveButtonStyle {
    var primary = false
    var selected = false
    var fillsWidth = false
    func makeBody(configuration: Configuration) -> some View {
        if self.fillsWidth {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label.font(MimicMetrics.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 24)
            }.buttonStyle(.borderedProminent).tint(.indigo).controlSize(.regular)
                .buttonBorderShape(.roundedRectangle(radius: 8))
        } else {
            Button(configuration).buttonStyle(MimicButtonStyle(primary: self.primary, selected: self.selected, height: 32))
        }
    }
}
