//
//  BuildResultStore.swift
//  MimicCore
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation

/// Persisted extraction belongs to one activity. Freshness is evaluated independently at read time.
public struct BuildResultStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".result.json") }
    public func load(_ id: UUID) throws -> BuildResult? {
        let path = url(id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let attributes = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 128 * 1024 * 1024 else { throw BuildError.arguments }
        return try JSONDecoder().decode(BuildResult.self, from: Data(contentsOf: path))
    }
    public func save(_ result: BuildResult, id: UUID) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(result)
        guard data.count <= 128 * 1024 * 1024 else { throw BuildError.capacity }
        try data.write(to: url(id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(id).path)
    }
}
