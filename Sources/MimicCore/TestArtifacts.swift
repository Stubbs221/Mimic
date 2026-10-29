//
//  TestArtifacts.swift
//  MimicCore
//
//  Created by Василий Маслов on 28.10.2026.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Original attachment identity is independent of the lossy, bounded display preview.
public struct TestImageArtifact: Codable, Sendable, Identifiable {
    public let id: UUID
    public let activityID: UUID
    public let methodID: String
    public let caseID: String?
    public let originalPath: String
    public let digest: String
    public let attachmentID: String
    public let role: String
    public let width: Int
    public let height: Int
    public let metadata: BridgeValue
}

public struct TestArtifactCatalogue: Codable, Sendable {
    public var availability: String
    public var reason: String?
    public var items: [TestImageArtifact]
}

/// Only an activity-owned xcresult may create artifacts. Shared simulator temporary files are never read.
public struct TestArtifactStore: Sendable {
    public typealias Export = @Sendable ([String], [String: String]) -> (Int32, String)
    public let root: URL
    public init(root: URL) { self.root = root }
    private func directory(_ activity: UUID, method: String) -> URL {
        root.appendingPathComponent(activity.uuidString + "-Attachments").appendingPathComponent(SourceRevisionReader.hash(Data(method.utf8)))
    }
    public func list(record: BuildActivity, methodID: String, facts: [TestExecutionFact], export: Export? = nil) throws -> TestArtifactCatalogue {
        guard !record.status.isPending, record.status != .unknown, record.hasPrivateInput != true else { return .init(availability: "unavailable", reason: "activityNotReadable", items: []) }
        let owned = facts.filter { $0.method == methodID }
        guard !owned.isEmpty else { return .init(availability: "unavailable", reason: "methodNotObserved", items: []) }
        let dir = directory(record.id, method: methodID), catalogueURL = dir.appendingPathComponent("catalogue.json")
        if FileManager.default.fileExists(atPath: catalogueURL.path) {
            let saved = try JSONDecoder().decode(TestArtifactCatalogue.self, from: Data(contentsOf: catalogueURL))
            for artifact in saved.items { _ = try original(artifact) }
            return saved
        }
        guard let bundle = record.resultBundlePath, FileManager.default.fileExists(atPath: bundle), let developer = record.selectedDeveloperDirectory else { return .init(availability: "unavailable", reason: "resultBundleUnavailable", items: []) }
        let expectedBundle = root.appendingPathComponent(record.id.uuidString + ".xcresult")
        guard URL(fileURLWithPath: bundle).standardizedFileURL.path == expectedBundle.standardizedFileURL.path else { throw BuildError.arguments }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = dir.appendingPathComponent("Export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "DEVELOPER_DIR": developer]
        let arguments = ["xcresulttool", "export", "attachments", "--path", bundle, "--test-id", owned.first?.identifierURL?.components(separatedBy: "?").first ?? methodID, "--output-path", stage.path, "--filter", "*.png"]
        let capture = export ?? { ReadOnlyProcess.capture("/usr/bin/xcrun", $0, environment: $1, timeout: 30, maximumBytes: 512 * 1024) }
        guard capture(arguments, environment).0 == 0 else { return .init(availability: "unavailable", reason: "attachmentExportUnavailable", items: []) }
        let manifestData = try regularFile(stage.appendingPathComponent("manifest.json"), root: stage, maximum: 2 * 1024 * 1024)
        guard let groups = try JSONSerialization.jsonObject(with: manifestData) as? [[String: Any]], groups.count <= 10_000 else { throw BuildError.catalogueResponse }
        var items: [TestImageArtifact] = [], total = 0
        for group in groups {
            let identifier = group["testIdentifier"] as? String ?? "", url = group["testIdentifierURL"] as? String
            let exactURL = url.map { candidate in owned.contains { $0.identifierURL == candidate || $0.identifierURL?.components(separatedBy: "?").first == candidate } } == true
            guard identifier == methodID || identifier == methodID.split(separator: "/").dropFirst().joined(separator: "/") || exactURL else { throw BuildError.catalogueResponse }
            for attachment in group["attachments"] as? [[String: Any]] ?? [] {
                guard items.count < 128 else { throw BuildError.capacity }
                guard let filename = attachment["exportedFileName"] as? String, !filename.contains("/"), !filename.contains("\\"), filename.hasSuffix(".png") else { throw BuildError.arguments }
                let bytes = try regularFile(stage.appendingPathComponent(filename), root: stage, maximum: 32 * 1024 * 1024)
                total += bytes.count; guard total <= 256 * 1024 * 1024 else { throw BuildError.capacity }
                let dimensions = try imageSize(bytes), digest = SourceRevisionReader.hash(bytes), id = UUID()
                let original = dir.appendingPathComponent(id.uuidString + ".png")
                try bytes.write(to: original, options: .atomic)
                let meta: BridgeValue = .object(["source": .string("xcresultAttachmentManifest"), "configuration": Self.string(attachment["configurationName"]), "deviceID": Self.string(attachment["deviceId"]), "device": Self.string(attachment["deviceName"]), "repetition": (attachment["repetitionNumber"] as? Int).map { .number(Double($0)) } ?? .null, "timestamp": (attachment["timestamp"] as? Double).map(BridgeValue.number) ?? .null, "scale": .null, "locale": .null, "effectiveTraits": .null, "developerDirectory": .string(developer), "xcode": record.toolchainEnvironment?["xcode"] ?? .null, "availableSDK": record.toolchainEnvironment?["availableSDK"] ?? .null, "sdk": .null, "checkout": .string(record.project.path), "sha": .string(record.project.commit), "sourceStability": record.sourceProvenance.map { .string($0.stability) } ?? .null])
                let artifact = TestImageArtifact(id: id, activityID: record.id, methodID: methodID, caseID: url?.contains("?args=") == true ? url : nil, originalPath: original.path, digest: digest, attachmentID: filename, role: "unknown", width: dimensions.0, height: dimensions.1, metadata: meta)
                let index = root.appendingPathComponent("ArtifactIndex").appendingPathComponent(record.id.uuidString)
                try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(artifact).write(to: index.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
                items.append(artifact)
            }
        }
        let result = TestArtifactCatalogue(availability: items.isEmpty ? "unavailable" : "available", reason: items.isEmpty ? "noImageAttachments" : nil, items: items)
        try JSONEncoder().encode(result).write(to: catalogueURL, options: .atomic)
        return result
    }
    public func artifact(_ id: UUID) throws -> TestImageArtifact {
        let index = root.appendingPathComponent("ArtifactIndex")
        guard let directories = try? FileManager.default.contentsOfDirectory(at: index, includingPropertiesForKeys: [.isSymbolicLinkKey]), directories.count <= 10_000 else { throw BuildError.notFound }
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            let path = directory.appendingPathComponent(id.uuidString + ".json")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let data = try regularFile(path, root: directory, maximum: 64 * 1024)
            let artifact = try JSONDecoder().decode(TestImageArtifact.self, from: data)
            guard artifact.id == id, artifact.activityID.uuidString == directory.lastPathComponent else { throw BuildError.arguments }
            return artifact
        }
        throw BuildError.notFound
    }
    public func original(_ artifact: TestImageArtifact) throws -> Data {
        let dir = directory(artifact.activityID, method: artifact.methodID)
        let bytes = try regularFile(URL(fileURLWithPath: artifact.originalPath), root: dir, maximum: 32 * 1024 * 1024)
        guard SourceRevisionReader.hash(bytes) == artifact.digest else { throw BuildError.sourceChanged }
        return bytes
    }
    public func preview(_ artifact: TestImageArtifact) throws -> Data {
        let data = try original(artifact)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1280] as CFDictionary) else { throw BuildError.catalogueResponse }
        for quality in [0.85, 0.65, 0.4] {
            let bytes = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw BuildError.catalogueResponse }
            CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw BuildError.catalogueResponse }
            if bytes.length <= 400 * 1024 { return bytes as Data }
        }
        throw BuildError.capacity
    }
    private static func string(_ value: Any?) -> BridgeValue { (value as? String).map { .string(DiagnosticText.bounded(DiagnosticText.clean($0), limit: 1024).text) } ?? .null }
    private func imageSize(_ bytes: Data) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetType(source) as String? == UTType.png.identifier, CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 20_000_000 else { throw BuildError.capacity }
        return (width, height)
    }
    private func regularFile(_ path: URL, root: URL, maximum: Int) throws -> Data {
        guard path.deletingLastPathComponent().resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path, path.resolvingSymlinksInPath().path == path.standardizedFileURL.path else { throw BuildError.arguments }
        let properties = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? Int.max) <= maximum else { throw BuildError.capacity }
        let data = try Data(contentsOf: path); guard data.count <= maximum else { throw BuildError.capacity }; return data
    }
}
