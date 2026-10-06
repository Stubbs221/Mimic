//
//  History.swift
//  MimicCore
//
//  Created by Василий Маслов on 01.10.2026.
import Foundation

/// Private local history, with interrupted recovery and no persisted process environment/input.
public struct HistoryStore: Sendable {
    public let directory: URL
    public let limit: Int
    public init(directory: URL, limit: Int = 100) { self.directory = directory; self.limit = limit }
    public func load() throws -> [TaskRecord] {
        let path = self.directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        var records = try JSONDecoder().decode([TaskRecord].self, from: Data(contentsOf: path))
        for index in records.indices where records[index].status == .running || records[index].status == .queued {
            records[index].status = .interrupted; records[index].finishedAt = Date()
        }
        return records
    }

    public func save(_ records: [TaskRecord]) throws {
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Preserve live jobs; remove only the oldest completed entries.
        let live = records.filter { $0.status == .queued || $0.status == .running }
        let completed = records.filter { $0.status != .queued && $0.status != .running }.suffix(max(0, self.limit - live.count))
        let kept = (Array(completed) + live).sorted { $0.createdAt < $1.createdAt }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let historyURL = self.directory.appendingPathComponent("history.json")
        let original = (try? Data(contentsOf: historyURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        var preserved: [String: [String: Any]] = [:]
        for entry in original {
            guard let id = entry["id"] as? String else { continue }; preserved[id] = entry
        }
        let entries: [[String: Any]] = try kept.map { record in
            let encoded = try encoder.encode(record)
            if let entry = preserved[record.id.uuidString], let bytes = try? JSONSerialization.data(withJSONObject: entry),
               let old = try? JSONDecoder().decode(TaskRecord.self, from: bytes), try encoder.encode(old) == encoded { return entry }
            return try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        }
        try JSONSerialization.data(withJSONObject: entries, options: .sortedKeys).write(to: historyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.directory.appendingPathComponent("history.json").path)
        let keepIDs = Set(kept.map { $0.id.uuidString + ".log" })
        for file in (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "log" && !keepIDs.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

/// A hard byte budget; truncation never affects execution or the terminal's live stream.
public final class BoundedLog {
    public let url: URL
    private let handle: FileHandle
    private let limit: Int
    public private(set) var truncated = false
    private var count = 0
    public init(url: URL, limit: Int = 20 * 1024 * 1024) throws {
        self.url = url; self.limit = limit
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        self.handle = try FileHandle(forWritingTo: url)
    }

    public func append(_ data: Data) throws {
        let remaining = max(0, limit - self.count)
        try self.handle.write(contentsOf: data.prefix(remaining)); self.count += min(data.count, remaining)
        if data.count > remaining { self.truncated = true }
    }

    public func close() { try? self.handle.close() }
    deinit { close() }
}
