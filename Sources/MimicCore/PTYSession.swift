//
//  PTYSession.swift
//  MimicCore
//
//  Created by Василий Маслов on 01.10.2026.
import Darwin
import Foundation

/// JSON lifecycle messages travel on the helper's stderr; terminal bytes use stdout exclusively.
public struct HostEvent: Codable, Sendable {
    public let kind: String
    public var pid: Int?
    public var code: Int?
    public var signal: Int?
    public var cancelled: Bool?
    public var launchError: Int?
    public var errno: Int?
}

/// Owns a helper process independently of all SwiftUI views. Input is framed, never recorded.
@MainActor
public final class PTYSession {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), events = Pipe()
    private var eventBuffer = Data()
    private var eventEnded = false
    private var outputEnded = false
    private var exitEvent: HostEvent?
    private var didComplete = false
    private var helperStarted = false
    private var cancellationRequested = false
    public var onOutput: ((Data) -> Void)?
    /// Awaited before the pipe reader accepts another chunk; use for off-actor ingestion.
    public var onOutputAsync: ((Data) async -> Void)?
    public var onEvent: ((HostEvent) -> Void)?
    public var onCompletion: ((HostEvent?) -> Void)?
    public private(set) var running = false
    private let writer = DispatchQueue(label: "Mimic.pty.input")

    public init() { }
    public func start(helper: URL, command: CommandSpec) throws {
        // A helper can exit between queuing a resize/cancel frame and writing it.
        guard fcntl(self.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.process.executableURL = helper; self.process.arguments = ["--cwd", command.directory, "--", command.executable] + command.arguments
        self.process.environment = command.environment; self.process.currentDirectoryURL = URL(fileURLWithPath: command.directory)
        self.process.standardInput = self.input; self.process.standardOutput = self.output; self.process.standardError = self.events
        self.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // FileHandle.read(upToCount:) may wait to fill its request on a pipe.
            // One read returns currently available bytes, so prompts and cancellation stay live.
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
            let data = Data(buffer.prefix(max(0, count)))
            if data.isEmpty { handle.readabilityHandler = nil }
            let delivered = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                defer { delivered.signal() }
                guard let self else { return }
                if data.isEmpty { self.outputEnded = true; self.completeIfReady() } else if let onOutputAsync = self.onOutputAsync { await onOutputAsync(data) } else { self.onOutput?(data) }
            }
            // Backpressure prevents an unbounded backlog of main-actor output tasks.
            delivered.wait()
        }
        self.events.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if data.isEmpty { self.eventEnded = true; self.completeIfReady() } else { self.receiveEvents(data) }
            }
        }
        do { try self.process.run(); self.running = true }
        catch { self.output.fileHandleForReading.readabilityHandler = nil; self.events.fileHandleForReading.readabilityHandler = nil; throw error }
    }

    public func send(_ bytes: Data) { self.frame(kind: 1, payload: bytes) }
    public func resize(columns: Int, rows: Int) {
        let columns = UInt16(clamping: columns), rows = UInt16(clamping: rows)
        self.frame(kind: 2, payload: Data([UInt8(columns >> 8), UInt8(columns & 255), UInt8(rows >> 8), UInt8(rows & 255)]))
    }

    public func cancel() {
        guard self.running, !self.cancellationRequested else { return }
        self.cancellationRequested = true
        // The frame can wait in stdin before helper startup. Signal only after its
        // started event confirms handlers exist, including when paste is blocked.
        self.frame(kind: 3, payload: Data())
        if self.helperStarted { self.process.interrupt() }
    }

    /// Used by recovery tests; EOF instructs the helper to stop its own children.
    public func disconnect() { try? self.input.fileHandleForWriting.close() }
    private func frame(kind: UInt8, payload: Data) {
        guard self.running, payload.count <= 1024 * 1024 else { return }
        let size = UInt32(payload.count)
        var data = Data([kind, UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]); data.append(payload)
        let handle = self.input.fileHandleForWriting
        let outgoing = data
        self.writer.async { try? handle.write(contentsOf: outgoing) }
    }

    private func receiveEvents(_ data: Data) {
        self.eventBuffer.append(data)
        while let end = eventBuffer.firstIndex(of: 10) {
            let line = self.eventBuffer.prefix(upTo: end); self.eventBuffer.removeSubrange(...end)
            if let event = try? JSONDecoder().decode(HostEvent.self, from: line) {
                if event.kind == "started" {
                    self.helperStarted = true
                    if self.cancellationRequested { self.process.interrupt() }
                }
                if event.kind == "exit" { self.exitEvent = event }
                self.onEvent?(event)
            }
        }
    }

    private func completeIfReady() {
        guard self.eventEnded, self.outputEnded, !self.didComplete else { return }
        self.didComplete = true; self.running = false
        try? self.input.fileHandleForWriting.close()
        self.onCompletion?(self.exitEvent)
    }
}
