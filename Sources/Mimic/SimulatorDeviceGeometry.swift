// Created by Василий Маслов on 07.10.2026.
import AppKit
import CoreGraphics
import Foundation
import MimicCore

/// Reads installed device profiles, keyed by the exact type identifier. No model-name heuristics or invented cutouts.
enum SimulatorDeviceGeometry {
    /// Assets remain app-only, bounded and sourced from the exact installed device type.
    static func masks(identifier: String, developer: String) -> BridgeValue {
        for root in roots(developer) {
            let bundles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for bundle in bundles where bundle.pathExtension == "simdevicetype" {
                guard plist(bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String == identifier else { continue }
                let resources = bundle.appendingPathComponent("Contents/Resources")
                guard let name = plist(resources.appendingPathComponent("profile.plist"))?["framebufferMask"] as? String,
                      !name.contains("/"), !name.contains(".."),
                      let pdf = CGPDFDocument(resources.appendingPathComponent(name + ".pdf") as CFURL), let page = pdf.page(at: 1) else { return .null }
                return render(page)
            }
        }
        return .null
    }
    /// The mask clips the existing framebuffer; no sensor-bar overlay is added a second time.
    private static func render(_ page: CGPDFPage) -> BridgeValue {
        let bounds = page.getBoxRect(.mediaBox), scale = min(1, 1024 / max(bounds.width, bounds.height))
        guard bounds.width > 0, bounds.height > 0 else { return .null }
        var result: [String: BridgeValue] = [:]
        for (orientation, angle) in [("portrait", 0.0), ("landscapeLeft", -.pi / 2), ("landscapeRight", .pi / 2), ("portraitUpsideDown", .pi)] {
            let sideways = orientation.hasPrefix("landscape")
            let width = max(1, Int((sideways ? bounds.height : bounds.width) * scale)), height = max(1, Int((sideways ? bounds.width : bounds.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .null }
            context.translateBy(x: Double(width) / 2, y: Double(height) / 2)
            context.rotate(by: angle); context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.midX, y: -bounds.midY); context.drawPDFPage(page)
            guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), data.count <= 64_000 else { return .null }
            result[orientation] = .string(data.base64EncodedString())
        }
        return .object(result)
    }
    private static func roots(_ developer: String) -> [URL] {
        [URL(fileURLWithPath: developer).appendingPathComponent("Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes"), URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")]
    }
    static func profiles(devices: [SimulatorDevice], developer: String) -> BridgeValue {
        let identifiers = Set(devices.compactMap(\.deviceTypeIdentifier))
        var result: [String: BridgeValue] = [:]
        for root in roots(developer) {
            let bundles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for bundle in bundles where bundle.pathExtension == "simdevicetype" {
                guard let info = plist(bundle.appendingPathComponent("Contents/Info.plist")), let id = info["CFBundleIdentifier"] as? String,
                      identifiers.contains(id), result[id] == nil, let name = info["CFBundleName"] as? String else { continue }
                let resources = bundle.appendingPathComponent("Contents/Resources")
                let caps = plist(resources.appendingPathComponent("capabilities.plist"))?["capabilities"] as? [String: Any]
                let display = (caps?["displays"] as? [[String: Any]])?.first { $0["deviceName"] as? String == "primary" }
                var value: [String: BridgeValue] = ["model": .string(name)]
                if let display, let width = display["width"] as? Double, let height = display["height"] as? Double,
                   let scale = display["scale"] as? Double, width > 0, height > 0, scale > 0 {
                    value["width"] = .number(width / scale); value["height"] = .number(height / scale)
                    value["radii"] = .array(["cornerRadiusUL", "cornerRadiusUR", "cornerRadiusLR", "cornerRadiusLL"].map { .number(display[$0] as? Double ?? 0) })
                    value["chromeIdentifier"] = (display["chromeIdentifier"] as? String).map(BridgeValue.string) ?? .null
                    value["maskIdentifier"] = (display["framebufferMaskIdentifier"] as? String).map(BridgeValue.string) ?? .null
                }
                result[id] = .object(value)
            }
        }
        return .object(result)
    }
    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count <= 2_000_000 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
