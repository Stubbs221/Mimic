//
//  BuildOutputWorker.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import os

/// Serial sanitation and disk writes. Producers await each chunk, keeping ingestion bounded.
public actor BuildOutputWorker {
    public struct Batch: Sendable {
        public let output: BuildOutput
        public let emitted: Data
        public let logTruncated: Bool
        public let logFailed: Bool
    }
    private let signposter = OSSignposter(subsystem: "local.vmaslov.Mimic", category: "BuildOutput")
    private var output = BuildOutput()
    private var log: BoundedLog?
    private var logURL: URL?
    private var logFailed = false
    public init() { }
    public func open(_ url: URL) throws { log = try BoundedLog(url: url); logURL = url }
    /// Close and remove persisted output before any input can be echoed by the PTY.
    public func makePrivate() throws {
        log?.close(); log = nil
        if let logURL, FileManager.default.fileExists(atPath: logURL.path) { try FileManager.default.removeItem(at: logURL) }
        logURL = nil
    }
    public func append(_ bytes: Data, final: Bool = false) -> Batch {
        let interval = signposter.beginInterval("SanitizeAndWrite")
        defer { signposter.endInterval("SanitizeAndWrite", interval) }
        let emitted = output.append(bytes, final: final)
        do { try log?.append(emitted) } catch { logFailed = true }
        let truncated = log?.truncated == true
        if final { log?.close(); log = nil }
        return Batch(output: output, emitted: emitted, logTruncated: truncated, logFailed: logFailed)
    }
}
