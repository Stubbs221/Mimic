//
//  AIProcessRunner.swift
//  MimicCore
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation

public struct AIProcessOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int
    public init(stdout: Data, stderr: Data, exitCode: Int) { self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode }
}

/// A single supervised pipe invocation. Cancellation is complete only after its host releases children.
@MainActor
public protocol AIProcessRunning: AnyObject {
    func start(executable: String, arguments: [String], input: Data, environment: [String: String], completion: @escaping (Result<AIProcessOutput, AIError>) -> Void) throws
    func cancel()
}

/// TaskHost keeps PID/start-time ownership and signal escalation identical to terminal tasks.
/// Prompt, stdout and stderr remain memory-only; the temporary directory contains no request file.
@MainActor
public final class AIProcessRunner: AIProcessRunning {
    private let helper: URL
    private let timeLimit: TimeInterval
    private let outputLimit: Int
    private var runID: UUID?
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var eventPipe: Pipe?
    private var directory: URL?
    private var frameBuffer = Data(), eventBuffer = Data(), stdout = Data(), stderr = Data()
    private var outputEnded = false, eventEnded = false, processEnded = false
    private var exitEvent: HostEvent?
    private var failure: AIError?
    private var completion: ((Result<AIProcessOutput, AIError>) -> Void)?
    private var deadline: Task<Void, Never>?
    private let writer = DispatchQueue(label: "Mimic.ai.stdin")

    public init(helper: URL, timeLimit: TimeInterval = 180, outputLimit: Int = 1024 * 1024) {
        self.helper = helper; self.timeLimit = timeLimit; self.outputLimit = outputLimit
    }

    public func start(executable: String, arguments: [String], input: Data, environment: [String: String], completion: @escaping (Result<AIProcessOutput, AIError>) -> Void) throws {
        guard self.process == nil else { throw AIError.busy }
        guard input.count <= 1024 * 1024 else { throw AIError.outputLimit }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-AI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        let runID = UUID(); self.runID = runID
        self.frameBuffer = Data(); self.eventBuffer = Data(); self.stdout = Data(); self.stderr = Data()
        self.outputEnded = false; self.eventEnded = false; self.processEnded = false; self.failure = nil; self.exitEvent = nil
        let process = Process(), inputPipe = Pipe(), outputPipe = Pipe(), eventPipe = Pipe()
        self.process = process; self.inputPipe = inputPipe; self.outputPipe = outputPipe; self.eventPipe = eventPipe; self.completion = completion
        process.executableURL = self.helper
        process.arguments = ["--pipes", "--cwd", directory.path, "--", executable] + arguments
        process.currentDirectoryURL = directory; process.environment = environment
        process.standardInput = inputPipe; process.standardOutput = outputPipe; process.standardError = eventPipe
        self.read(outputPipe.fileHandleForReading, output: true, runID: runID)
        self.read(eventPipe.fileHandleForReading, output: false, runID: runID)
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.runID == runID else { return }
                self.processEnded = true; self.completeIfReady()
            }
        }
        do { try process.run() }
        catch { self.cleanup(); throw AIError.processFailed }
        let handle = inputPipe.fileHandleForWriting
        let size = UInt32(input.count)
        var framed = Data([1, UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        framed.append(input); framed.append(contentsOf: [4, 0, 0, 0, 0])
        let outgoing = framed
        self.writer.async { try? handle.write(contentsOf: outgoing) }
        self.deadline = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(self.timeLimit)) } catch { return }
            guard self.runID == runID else { return }
            self.stop(reason: .timeout)
        }
    }

    public func cancel() { self.stop(reason: .cancelled) }

    private func stop(reason: AIError) {
        guard let process = self.process else { return }
        if self.failure == nil { self.failure = reason }
        if process.isRunning { process.interrupt() }
    }

    private func read(_ handle: FileHandle, output: Bool, runID: UUID) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            // As with terminal sessions, bound pending deliveries by applying backpressure off-main.
            let delivered = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                defer { delivered.signal() }
                guard let self, self.runID == runID else { return }
                if data.isEmpty {
                    if output { self.outputEnded = true } else { self.eventEnded = true }
                    self.completeIfReady()
                } else if output { self.receiveFrames(data) }
                else { self.receiveEvents(data) }
            }
            delivered.wait()
        }
    }

    private func receiveFrames(_ data: Data) {
        guard self.failure != .outputLimit else { return }
        self.frameBuffer.append(data)
        while self.frameBuffer.count >= 5 {
            let bytes = Array(self.frameBuffer.prefix(5))
            let size = Int(bytes[1]) << 24 | Int(bytes[2]) << 16 | Int(bytes[3]) << 8 | Int(bytes[4])
            guard size <= 16 * 1024, bytes[0] == 1 || bytes[0] == 2 else { self.stop(reason: .invalidJSON); self.frameBuffer.removeAll(); return }
            guard self.frameBuffer.count >= size + 5 else { return }
            guard self.stdout.count + self.stderr.count + size <= self.outputLimit else { self.stop(reason: .outputLimit); self.frameBuffer.removeAll(); return }
            let payload = self.frameBuffer.dropFirst(5).prefix(size)
            if bytes[0] == 1 { self.stdout.append(payload) } else { self.stderr.append(payload) }
            self.frameBuffer.removeFirst(size + 5)
        }
    }

    private func receiveEvents(_ data: Data) {
        self.eventBuffer.append(data)
        guard self.eventBuffer.count < 16 * 1024 else { self.stop(reason: .invalidJSON); self.eventBuffer.removeAll(); return }
        while let end = self.eventBuffer.firstIndex(of: 10) {
            let line = self.eventBuffer.prefix(upTo: end)
            self.eventBuffer.removeSubrange(...end)
            if let event = try? JSONDecoder().decode(HostEvent.self, from: line), event.kind == "exit" { self.exitEvent = event }
        }
    }

    private func completeIfReady() {
        guard self.outputEnded, self.eventEnded, self.processEnded, let completion = self.completion else { return }
        let result: Result<AIProcessOutput, AIError>
        if let failure = self.failure { result = .failure(failure) }
        else if !self.frameBuffer.isEmpty { result = .failure(.invalidJSON) }
        else if let event = self.exitEvent, event.signal == 0, event.launchError == 0, event.cancelled != true {
            result = .success(AIProcessOutput(stdout: self.stdout, stderr: self.stderr, exitCode: event.code ?? -1))
        } else { result = .failure(.processFailed) }
        self.cleanup(); completion(result)
    }

    private func cleanup() {
        self.deadline?.cancel(); self.deadline = nil
        self.outputPipe?.fileHandleForReading.readabilityHandler = nil; self.eventPipe?.fileHandleForReading.readabilityHandler = nil
        try? self.inputPipe?.fileHandleForWriting.close()
        try? self.outputPipe?.fileHandleForReading.close(); try? self.eventPipe?.fileHandleForReading.close()
        if let directory = self.directory { try? FileManager.default.removeItem(at: directory) }
        self.runID = nil; self.directory = nil; self.process = nil; self.inputPipe = nil; self.outputPipe = nil; self.eventPipe = nil; self.completion = nil
        self.stdout.removeAll(); self.stderr.removeAll(); self.frameBuffer.removeAll(); self.eventBuffer.removeAll()
    }
}
