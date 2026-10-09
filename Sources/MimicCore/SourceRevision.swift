//
//  SourceRevision.swift
//  MimicCore
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import CryptoKit

/// Content identity, independent of ProjectContext and Git staging. No source bytes are persisted.
public struct SourceRevision: Codable, Equatable, Sendable {
    public let algorithm: String
    public let rulesRevision: String
    public let digest: String
    public let fileCount: Int
    public init(rulesRevision: String, digest: String, fileCount: Int) {
        algorithm = "sha256-working-tree-v1"; self.rulesRevision = rulesRevision; self.digest = digest; self.fileCount = fileCount
    }
}

public struct SourceEntry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: String
    public let mode: Int
    public let digest: String
}

/// A bounded read of tracked and nonignored untracked files, including deletions and symlink text.
/// Explicit profile exclusions use checkout-relative paths, optionally ending in / for a subtree.
public enum SourceRevisionReader {
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func validate(exclusions: [String]) throws {
        guard exclusions.count <= 100, exclusions.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains("..") && !$0.hasPrefix(".git") }) else { throw BuildError.arguments }
    }
    public static func entries(path: String, exclusions: [String] = []) throws -> [SourceEntry] {
        try validate(exclusions: exclusions)
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let query = ReadOnlyProcess.capture("/usr/bin/git", ["-C", root.path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"], timeout: 15, maximumBytes: 16 * 1024 * 1024)
        guard query.0 == 0, query.1.utf8.count < 16 * 1024 * 1024 else { throw BuildError.sourceUnavailable }
        let paths = Set(query.1.split(separator: "\0").map(String.init)).sorted()
        guard paths.count <= 100_000 else { throw BuildError.sourceUnavailable }
        let deadline = Date().addingTimeInterval(60)
        var entries: [SourceEntry] = []
        for path in paths {
            guard Date() < deadline else { throw BuildError.sourceUnavailable }
            if exclusions.contains(where: { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 }) { continue }
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw BuildError.sourceUnavailable }
            let file = root.appendingPathComponent(path)
            guard file.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root.path + "/") || file.deletingLastPathComponent().resolvingSymlinksInPath() == root else { throw BuildError.sourceUnavailable }
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
            catch {
                if (error as NSError).code == NSFileReadNoSuchFileError || (error as NSError).code == NSFileNoSuchFileError {
                    entries.append(.init(path: path, kind: "deleted", mode: 0, digest: "")); continue
                }
                throw BuildError.sourceUnavailable
            }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let type = attributes[.type] as? FileAttributeType
            let digest: String, kind: String
            if type == .typeSymbolicLink {
                kind = "symlink"; digest = hash(Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8))
            } else if type == .typeRegular {
                kind = "file"
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                var hasher = SHA256()
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    guard Date() < deadline else { throw BuildError.sourceUnavailable }; hasher.update(data: data)
                }
                digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                let after = try FileManager.default.attributesOfItem(atPath: file.path)
                guard (after[.modificationDate] as? Date) == (attributes[.modificationDate] as? Date), (after[.size] as? NSNumber) == (attributes[.size] as? NSNumber) else { throw BuildError.sourceUnavailable }
            } else { throw BuildError.sourceUnavailable }
            entries.append(.init(path: path, kind: kind, mode: mode, digest: digest))
        }
        return entries
    }
    public static func capture(path: String, exclusions: [String] = []) throws -> SourceRevision {
        let head = ReadOnlyProcess.capture("/usr/bin/git", ["-C", path, "rev-parse", "HEAD"], timeout: 15, maximumBytes: 4096)
        guard head.0 == 0 else { throw BuildError.sourceUnavailable }
        let entries = try entries(path: path, exclusions: exclusions)
        let afterHead = ReadOnlyProcess.capture("/usr/bin/git", ["-C", path, "rev-parse", "HEAD"], timeout: 15, maximumBytes: 4096)
        guard afterHead.0 == 0, afterHead.1 == head.1 else { throw BuildError.sourceUnavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let rules = hash(try encoder.encode(exclusions.sorted()))
        return .init(rulesRevision: rules, digest: hash(Data(head.1.utf8) + (try encoder.encode(entries))), fileCount: entries.count)
    }
}

/// Boundary and periodic observations, not an immutable snapshot of the build's inputs.
public struct SourceProvenance: Codable, Sendable {
    public var admitted: SourceRevision?
    public var started: SourceRevision?
    public var finished: SourceRevision?
    public var stability: String = "unknown"
    public var observationCount = 0
    public var changed = false
    public var unavailable = false
    public init(admitted: SourceRevision?) { self.admitted = admitted }
    public mutating func observe(_ revision: SourceRevision?) {
        observationCount += 1
        guard let revision else { unavailable = true; stability = changed ? "changed" : "unknown"; return }
        if let started, started != revision { changed = true }
        finished = revision; stability = changed ? "changed" : unavailable || started == nil ? "unknown" : "unchangedObserved"
    }
}
