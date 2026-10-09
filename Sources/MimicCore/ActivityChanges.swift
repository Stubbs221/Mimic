//
//  ActivityChanges.swift
//  MimicCore
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import CryptoKit

public struct ActivityChanges: Codable, Sendable {
    public struct GitStatus: Codable, Sendable {
        public let path: String
        public let index: String
        public let worktree: String
    }
    public var gitBefore: [GitStatus]?
    public var gitAfter: [GitStatus]?
    public struct Change: Codable, Sendable {
        public let path: String
        public let beforeDigest: String?
        public let afterDigest: String?
        public let origin: String
    }
    public var preExisting: [String] = []
    public var observed: [Change] = []
    public var truncated = false
    public var unavailable = false
    public init() { }
}

/// Git status and file identities describe observations, never authorship inferred from timing.
public struct GitActivitySnapshot: Sendable {
    public let entries: [SourceEntry]
    public let dirtyPaths: [String]
    public let status: [ActivityChanges.GitStatus]
    public static func capture(path: String) throws -> Self {
        let status = ReadOnlyProcess.capture("/usr/bin/git", ["-C", path, "status", "--porcelain=v1", "-z", "--untracked-files=all"], timeout: 15, maximumBytes: 1024 * 1024)
        guard status.0 == 0, status.1.utf8.count < 1024 * 1024 else { throw BuildError.sourceUnavailable }
        var paths: [String] = [], states: [ActivityChanges.GitStatus] = [], skipRenameSource = false
        for item in status.1.split(separator: "\0").map(String.init) {
            if skipRenameSource { skipRenameSource = false; continue }
            guard item.count >= 3 else { continue }
            paths.append(String(item.dropFirst(3)))
            states.append(.init(path: String(item.dropFirst(3)), index: String(item.prefix(1)), worktree: String(item.dropFirst().prefix(1))))
            skipRenameSource = item.prefix(2).contains("R") || item.prefix(2).contains("C")
        }
        return .init(entries: try SourceRevisionReader.entries(path: path), dirtyPaths: paths.sorted(), status: states)
    }
    public func changes(after: Self) -> ActivityChanges {
        let before = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let next = Dictionary(uniqueKeysWithValues: after.entries.map { ($0.path, $0) })
        let paths = Set(before.keys).union(next.keys).sorted().filter { before[$0] != next[$0] }
        var result = ActivityChanges(); result.gitBefore = Array(status.prefix(200)); result.gitAfter = Array(after.status.prefix(200)); result.preExisting = Array(dirtyPaths.prefix(200))
        result.observed = paths.prefix(200).map { .init(path: $0, beforeDigest: before[$0]?.digest, afterDigest: next[$0]?.digest, origin: "observedDuringOperation") }
        result.truncated = paths.count > 200 || dirtyPaths.count > 200 || after.status.count > 200; return result
    }
}

public struct ManagedArtifact: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let bytes: UInt64
    public let digest: String
}

/// Cleanup accepts native-owned artifact identities. Symlinks are never followed and cannot claim ownership.
public enum ManagedArtifactReader {
    public static func inspect(_ url: URL, root: URL) throws -> ManagedArtifact {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw BuildError.arguments }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let deadline = Date().addingTimeInterval(30)
        var entries: [SourceEntry] = [], bytes: UInt64 = 0
        func append(_ file: URL) throws {
            guard Date() < deadline, (file.deletingLastPathComponent().resolvingSymlinksInPath() == root || file.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root.path + "/")) else { throw BuildError.arguments }
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let kind = attrs[.type] as? FileAttributeType, kind == .typeRegular || kind == .typeDirectory || kind == .typeSymbolicLink else { throw BuildError.arguments }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            if kind == .typeRegular { bytes += size }
            let digest = kind == .typeRegular ? try fileDigest(file, deadline: deadline) : kind == .typeSymbolicLink ? SourceRevisionReader.hash(Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8)) : "directory"
            let after = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (after[.type] as? FileAttributeType) == kind, (after[.size] as? NSNumber) == (attrs[.size] as? NSNumber), (after[.modificationDate] as? Date) == (attrs[.modificationDate] as? Date), (after[.posixPermissions] as? NSNumber) == (attrs[.posixPermissions] as? NSNumber) else { throw BuildError.sourceChanged }
            entries.append(.init(path: String(file.path.dropFirst(url.path.count)), kind: kind.rawValue, mode: (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0, digest: digest))
        }
        try append(url)
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw BuildError.unavailable }
            for case let file as URL in enumerator { guard entries.count < 100_000 else { throw BuildError.capacity }; try append(file) }
            guard !enumerationFailed else { throw BuildError.unavailable }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SourceRevisionReader.hash(try encoder.encode(entries.sorted { $0.path < $1.path }))
        return .init(id: SourceRevisionReader.hash(Data(url.path.utf8)), path: url.path, bytes: bytes, digest: digest)
    }
    private static func fileDigest(_ file: URL, deadline: Date) throws -> String {
        // Streaming hashes avoid materializing large result bundles or video files.
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = CryptoKit.SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { guard Date() < deadline else { throw BuildError.unavailable }; hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
