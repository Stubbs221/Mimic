//
//  SimulatorArtifactReader.swift
//  AppleSimulatorMCP
//
//  Created by Василий Маслов on 05.10.2026.
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import MimicCore
import UniformTypeIdentifiers

/// Geometry comes from Apple's hierarchy. Screenshot pixels only determine image aspect ratio.
public struct SimulatorFrame: Sendable {
    public let sessionID: UUID
    public let revision: UInt64
    public let width: Double
    public let height: Double
    public let jpeg: Data
    public let hierarchy: String
    public let targets: [BridgeValue]
    public let applicationState: String
    public var metadata: BridgeValue {
        .object(["sessionID": .string(sessionID.uuidString), "revision": .number(Double(revision)), "width": .number(width), "height": .number(height), "applicationState": .string(applicationState)])
    }
    public var payload: BridgeValue {
        var result = metadata.object ?? [:]
        result["image"] = .string(jpeg.base64EncodedString()); result["mimeType"] = .string("image/jpeg")
        result["hierarchy"] = .string(hierarchy); result["targets"] = .array(targets)
        return .object(result)
    }
    public func validate(_ action: AppleSimulatorAction) throws {
        func point(_ x: Double, _ y: Double) throws {
            guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < width, y < height else { throw AppleSimulatorError.arguments }
        }
        switch action {
        case let .tap(x, y): try point(x, y)
        case let .swipe(x, y, endX, endY, _): try point(x, y); try point(endX, endY)
        default: break
        }
    }
}

/// Reads only same-session paired Apple artifacts; bounds allocation before decoding or crossing the 1 MiB socket.
public enum SimulatorArtifactReader {
    @concurrent public static func read(_ observation: AppleSimulatorObservation) async throws -> SimulatorFrame {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ActionArtifacts/default/DeviceInteractionSynthesize").resolvingSymlinksInPath()
        let imageName = observation.screenshot.lastPathComponent, hierarchyName = observation.hierarchy.lastPathComponent
        let prefix = "Mimic Simulator " + observation.sessionID.uuidString + "-"
        guard imageName.hasPrefix(prefix), imageName.hasSuffix("-screenshot.png"), hierarchyName == imageName.replacingOccurrences(of: "-screenshot.png", with: "-hierarchy.txt") else { throw AppleSimulatorError.invalidResponse }
        let hierarchyData = try file(observation.hierarchy, root: root, maximum: 128 * 1024)
        guard let hierarchy = String(data: hierarchyData, encoding: .utf8), let geometry = try geometry(hierarchy) else { throw AppleSimulatorError.invalidResponse }
        let data = try file(observation.screenshot, root: root, maximum: 32 * 1024 * 1024)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetType(source) as String? == UTType.png.identifier, CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 20_000_000,
              (0.5...4).contains(Double(w) / geometry.0), (0.5...4).contains(Double(h) / geometry.1), abs(Double(w) / Double(h) - geometry.0 / geometry.1) < 0.02 else { throw AppleSimulatorError.invalidResponse }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1280, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw AppleSimulatorError.invalidResponse }
        var jpeg = Data()
        for quality in [0.85, 0.65, 0.4] {
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { throw AppleSimulatorError.invalidResponse }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AppleSimulatorError.invalidResponse }
            jpeg = buffer as Data
            if jpeg.count <= 400 * 1024 { break }
        }
        guard jpeg.count <= 400 * 1024 else { throw AppleSimulatorError.invalidResponse }
        let frame = SimulatorFrame(sessionID: observation.sessionID, revision: observation.revision, width: geometry.0, height: geometry.1, jpeg: jpeg, hierarchy: hierarchy, targets: try targets(hierarchy, width: geometry.0, height: geometry.1), applicationState: observation.applicationState)
        guard try JSONEncoder().encode(frame.payload).count < 850 * 1024 else { throw AppleSimulatorError.invalidResponse }
        return frame
    }
    private static func file(_ url: URL, root: URL, maximum: Int) throws -> Data {
        guard url.isFileURL, url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath() == root, url.resolvingSymlinksInPath().lastPathComponent == url.lastPathComponent else { throw AppleSimulatorError.invalidResponse }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AppleSimulatorError.invalidResponse }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size > 0, info.st_size <= maximum, abs(Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec)) < 180 else { throw AppleSimulatorError.invalidResponse }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 16384)
        while data.count <= maximum {
            let n = Darwin.read(fd, &bytes, min(bytes.count, maximum + 1 - data.count))
            guard n >= 0 else { throw AppleSimulatorError.invalidResponse }
            if n == 0 { break }; data.append(contentsOf: bytes.prefix(n))
        }
        guard data.count <= maximum, data.count == info.st_size else { throw AppleSimulatorError.invalidResponse }
        return data
    }
    /// Accepts the largest zero-origin device window; smaller SpringBoard/Stage Manager windows do not change the display plane. Incomparable extents are ambiguous.
    public static func geometry(_ hierarchy: String) throws -> (Double, Double)? {
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*Window, \{\{0\.0, 0\.0\}, \{([0-9.]+), ([0-9.]+)\}\}"#)
        let ns = hierarchy as NSString
        let sizes = regex.matches(in: hierarchy, range: NSRange(location: 0, length: ns.length)).compactMap { match -> (Double, Double)? in
            guard let w = Double(ns.substring(with: match.range(at: 1))), let h = Double(ns.substring(with: match.range(at: 2))), w.isFinite, h.isFinite, w >= 100, h >= 100, w <= 5000, h <= 5000 else { return nil }; return (w, h)
        }
        guard let full = sizes.max(by: { $0.0 * $0.1 < $1.0 * $1.1 }), sizes.allSatisfy({ $0.0 <= full.0 && $0.1 <= full.1 }) else { return nil }; return full
    }
    private static func targets(_ hierarchy: String, width: Double, height: Double) throws -> [BridgeValue] {
        let regex = try NSRegularExpression(pattern: #"\{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{([0-9.]+), ([0-9.]+)\}\}.*hitPoint: \{([0-9.]+), ([0-9.]+)\}"#)
        let ns = hierarchy as NSString
        return Array(regex.matches(in: hierarchy, range: NSRange(location: 0, length: ns.length)).prefix(1000).compactMap { match in
            let numbers = (1...6).compactMap { Double(ns.substring(with: match.range(at: $0))) }
            guard numbers.count == 6, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0, numbers[4] < width, numbers[5] < height else { return nil }
            return .object(Dictionary(uniqueKeysWithValues: zip(["x", "y", "width", "height", "hitX", "hitY"], numbers.map(BridgeValue.number))))
        })
    }
}
