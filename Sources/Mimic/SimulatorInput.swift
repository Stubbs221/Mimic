//
//  SimulatorInput.swift
//  Mimic
//
//  Created by Василий Маслов on 08.10.2026.
import Darwin
import Foundation
import MimicCore

/// Replaced by a deterministic fixture when testing queue ownership. An ack
/// confirms XPC submission, not application handling or presentation.
@MainActor protocol SimulatorInputDriver: AnyObject {
    var onFailure: (() -> Void)? { get set }
    var stopped: Bool { get }
    func start(device: UUID, developer: String) async throws
    func send(phase: SimulatorTouchEvent.Phase, gesture: UUID, x: Double, y: Double, timestamp: Double) async throws
    func stop() async
}

/// A persistent, single-request pipe to the isolated private-API helper. Any
/// ambiguous reply retires the connection; input is never retried.
@MainActor final class SimulatorInput: SimulatorInputDriver {
    private static var stopping: [ObjectIdentifier: Process] = [:]
    static var canExit: Bool { stopping.values.allSatisfy { !$0.isRunning } }
    var onFailure: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var sequence: UInt64 = 0
    private var pending: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var ready = false
    private var retiring = false
    var stopped: Bool { process?.isRunning != true }

    func start(device: UUID, developer: String) async throws {
        guard process == nil else { guard ready else { throw AppleSimulatorError.occupied }; return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SimulatorInputHost")
        #if DEBUG
        let executable = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("SimulatorInputHost")
        #else
        let executable = bundled
        #endif
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AppleSimulatorError.unsupported }
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe(), generation = UUID()
        self.generation = generation; sequence = 0; retiring = false; buffer = Data()
        child.executableURL = executable; child.arguments = [device.uuidString, developer]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in guard let self, self.generation == generation else { return }; self.receive(data) }
        }
        // Drain framework diagnostics without retaining device data or raw logs.
        errors?.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                Self.stopping[ObjectIdentifier(child)] = nil
                guard let self, self.generation == generation else { return }
                self.ready = false; self.complete(throwing: AppleSimulatorError.connectionLost)
                if !self.retiring { self.onFailure?() }
            }
        }
        do { try child.run() } catch { await stop(); throw AppleSimulatorError.unsupported }
        do { try await wait(timeout: .seconds(6)) } catch { await stop(); throw error }
    }

    func send(phase: SimulatorTouchEvent.Phase, gesture: UUID, x: Double, y: Double, timestamp: Double) async throws {
        guard ready, !retiring, process?.isRunning == true, pending == nil else { throw AppleSimulatorError.connectionLost }
        sequence += 1
        let value: [String: Any] = ["phase": phase.rawValue, "gesture": gesture.uuidString, "sequence": sequence, "epoch": 1, "x": x, "y": y, "timestamp": timestamp]
        let data = try JSONSerialization.data(withJSONObject: value) + Data([10])
        do {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation; armTimeout(.seconds(1))
                do { try input?.write(contentsOf: data) } catch { complete(throwing: AppleSimulatorError.connectionLost) }
            }
        } catch { await stop(); throw error }
    }

    // MARK: - Framing and failure

    private func wait(timeout duration: Duration) async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { continuation in pending = continuation; armTimeout(duration) }
    }
    private func armTimeout(_ duration: Duration) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.complete(throwing: AppleSimulatorError.connectionLost)
        }
    }
    private func complete(throwing error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        let waiter = pending; pending = nil
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty, buffer.count + data.count <= 16_384 else { fail(); return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            guard let fields = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { fail(); return }
            if fields["ready"] as? Bool == true { ready = true; complete() }
            else if fields["accepted"] as? Bool == true, (fields["sequence"] as? NSNumber)?.uint64Value == sequence { complete() }
            else { fail(); return }
        }
    }
    private func fail() {
        guard !retiring else { return }
        ready = false; complete(throwing: AppleSimulatorError.connectionLost); onFailure?()
        Task { await stop() }
    }

    /// Keep the global queue reserved until the helper actually exits. Closing
    /// stdin releases its contact; SIGTERM/SIGKILL bound an unresponsive helper.
    func stop() async {
        guard let child = process else { return }
        retiring = true; ready = false; complete(throwing: AppleSimulatorError.connectionLost)
        Self.stopping[ObjectIdentifier(child)] = child
        try? input?.close(); input = nil
        for index in 0..<100 where child.isRunning {
            if index == 10 { child.terminate() }
            if index == 35 { kill(child.processIdentifier, SIGKILL) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !child.isRunning else { return }
        Self.stopping[ObjectIdentifier(child)] = nil
        if process === child {
            generation = UUID(); output?.readabilityHandler = nil; errors?.readabilityHandler = nil
            try? output?.close(); try? errors?.close(); output = nil; errors = nil; process = nil
        }
    }
}
