//
//  BuildEventStream.swift
//  MimicCore
//
//  Created by Василий Маслов on 22.10.2026.
import Darwin
import Dispatch
import Foundation
import os

/// A private FIFO receives Xcode's result stream without writing raw events to disk.
/// The serial queue owns reads; the lock protects parser snapshots, privacy and shutdown.
public final class BuildEventStream: @unchecked Sendable {
    private struct State {
        var parser = BuildEventParser()
        var privateInput = false
        var stopped = false
    }
    public let path: String
    private let descriptor: Int32
    private let source: any DispatchSourceRead
    private let fallback: any DispatchSourceTimer
    private let queue = DispatchQueue(label: "local.vmaslov.Mimic.BuildEvents", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Accessed only by the serial read queue, including final drain and queued retries.
    private var retryScheduled = false

    public init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MimicBuildEvents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("events.fifo").path
        guard mkfifo(path, 0o600) == 0 else { try? FileManager.default.removeItem(at: directory); throw BuildError.unavailable }
        let fd = Darwin.open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw BuildError.unavailable }
        descriptor = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Large blocking FIFO writes do not reliably wake a read source on macOS.
        // The fallback starts draining them; short bounded retries keep the writer moving.
        fallback = DispatchSource.makeTimerSource(queue: queue)
        fallback.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        source.setEventHandler { [weak self] in self?.drain() }
        fallback.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(fd); try? FileManager.default.removeItem(at: directory) }
        source.resume(); fallback.resume()
    }
    deinit { stop() }

    /// Attach only to our CLI Xcode invocation; fixtures and unrelated commands remain untouched.
    public func attaching(to command: CommandSpec) -> CommandSpec? {
        guard command.executable == "/usr/bin/xcrun", command.arguments.first == "xcodebuild",
              command.arguments.contains("-resultBundlePath"),
              !command.arguments.contains("-resultStreamPath") else { return nil }
        return .init(executable: command.executable, arguments: command.arguments + ["-resultStreamPath", path], directory: command.directory, environment: command.environment)
    }
    public var snapshot: BuildExecutionProgress? {
        state.withLock { $0.privateInput || $0.stopped ? nil : $0.parser.progress }
    }
    /// Keep draining after private input: closing the FIFO could break the running writer.
    public func makePrivate() {
        state.withLock { $0.privateInput = true; $0.parser = BuildEventParser() }
    }
    /// Drain bytes already written before taking the final snapshot and releasing the channel.
    public func finish() async -> BuildExecutionProgress? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                drain()
                let value = snapshot
                stop()
                continuation.resume(returning: value)
            }
        }
    }
    public func stop() {
        let cancel = state.withLock { state in
            guard !state.stopped else { return false }
            state.stopped = true; return true
        }
        if cancel { fallback.cancel(); source.cancel() }
    }

    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var received = false
        // Bound each callback so a verbose writer cannot monopolize the serial queue.
        for _ in 0..<16 {
            guard !state.withLock({ $0.stopped }) else { return }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { if received { retry() }; return }
            received = true
            let data = Data(bytes.prefix(count))
            state.withLock { state in
                if !state.stopped && !state.privateInput { state.parser.append(data) }
            }
        }
        retry()
    }
    private func retry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false; self.drain()
        }
    }
}
