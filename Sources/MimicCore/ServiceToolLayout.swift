// Created by Василий Маслов on 16.10.2026.
import Foundation

extension PanelLayoutStore {
    /// Service blocks use the existing portable profile identity and one-time introduction behavior.
    public func introduceServiceTools(_ tools: [ServiceTool], profileID: String, checkout: String, surface: PanelSurface) -> PanelLayout {
        var layout = prepareForPresentation(surface)
        for tool in tools {
            let block = tool.block(profileID: profileID)
            let marker = "profilePanel.introduced." + surface.rawValue + ":" + checkout + ":" + block.rawValue
            guard !defaults.bool(forKey: marker) else { continue }
            if !layout.blocks.contains(block) {
                var next = layout
                do { try next.add(block, size: .mini); next.compact(); layout = try save(next, for: surface, expectedRevision: layout.revision) } catch { continue }
            }
            defaults.set(true, forKey: marker)
        }
        return layout
    }
}
