//
//  AnalysisCoordinator.swift
//  MimicCore
//
//  Created by Василий Маслов on 02.10.2026.
import Combine
import Foundation

public enum AnalysisState: String, Sendable { case ready, preparing, running, succeeded, failed, cancelled }

/// UI state belongs to the original task and remains ephemeral, even after a provider succeeds.
public struct AnalysisSession: Sendable {
    public let snapshot: DiagnosticSnapshot
    public var provider: AIProvider
    public var fragment: String
    public var comment = ""
    public var state = AnalysisState.ready
    public var result = ""
    public var error: AIError?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var requestID: UUID?
    /// Session-only presentation: closing the editor never cancels a request.
    public var requestExpanded = true
    public init(snapshot: DiagnosticSnapshot, provider: AIProvider) {
        self.snapshot = snapshot; self.provider = provider; self.fragment = snapshot.text
    }

    public var prompt: String { self.snapshot.prompt(fragment: self.fragment, comment: self.comment) }
}

/// Reads only version/help/feature output; no prompt or credential store is inspected.
@MainActor
public enum AICLIInspector {
    public static func check(provider: AIProvider, settings: AISettings, runner: any AIProcessRunning, isCancelled: () -> Bool = { false }) async throws -> AICapability {
        guard let executable = AIProviderAdapters.resolve(provider: provider, configuredPath: settings.path(for: provider)) else { throw AIError.missingCLI }
        let adapter = AIProviderAdapters.make(provider)
        var outputs: [String] = []
        for arguments in adapter.probes {
            guard !isCancelled() else { throw AIError.cancelled }
            let output = try await invoke(runner: runner, executable: executable, arguments: arguments, input: Data())
            guard !isCancelled() else { throw AIError.cancelled }
            guard output.exitCode == 0 else { throw AIError.unsupportedCLI }
            outputs.append(String(decoding: output.stdout, as: UTF8.self))
        }
        return try adapter.validate(executable: executable, outputs: outputs)
    }

    public static func invoke(runner: any AIProcessRunning, executable: String, arguments: [String], input: Data, onStarted: (() -> Void)? = nil) async throws -> AIProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try runner.start(executable: executable, arguments: arguments, input: input, environment: AIProviderAdapters.environment()) { result in
                    continuation.resume(with: result)
                }
                onStarted?()
            } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Runs one analysis independently of command queues and live checkout selection.
/// Request identity prevents a late callback from replacing another task's result.
@MainActor
public final class AnalysisCoordinator: ObservableObject {
    @Published
    public private(set) var sessions: [UUID: AnalysisSession] = [:]
    @Published
    public private(set) var activeTaskID: UUID?
    private let makeRunner: () -> any AIProcessRunning
    private let makeProbeRunner: () -> any AIProcessRunning
    private var runner: (any AIProcessRunning)?
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let timeLimit: TimeInterval
    private var cancelRequested = false
    private var stopError: AIError?
    private var clearedForExit = false
    public var onIdle: (() -> Void)?
    /// The native lifecycle owner closes admission while preparing an app replacement.
    public var mayAdmit: () -> Bool = { true }
    /// Ephemeral requests have no session log; the app records their provider at inference admission.
    public var onInferenceStarted: ((AIProvider, Date) -> Void)?

    public init(makeRunner: @escaping () -> any AIProcessRunning, makeProbeRunner: (() -> any AIProcessRunning)? = nil, timeLimit: TimeInterval = 180) {
        self.makeRunner = makeRunner; self.makeProbeRunner = makeProbeRunner ?? makeRunner; self.timeLimit = timeLimit
    }

    public var isActive: Bool { self.activeTaskID != nil }

    public func prepare(snapshot: DiagnosticSnapshot, provider: AIProvider) {
        guard self.sessions[snapshot.taskID] == nil else { return }
        if self.sessions.count >= 8, let oldest = self.sessions.filter({ $0.key != self.activeTaskID }).min(by: { $0.value.snapshot.createdAt < $1.value.snapshot.createdAt }) {
            self.sessions.removeValue(forKey: oldest.key)
        }
        self.sessions[snapshot.taskID] = AnalysisSession(snapshot: snapshot, provider: provider)
    }

    public func edit(id: UUID, fragment: String? = nil, comment: String? = nil, provider: AIProvider? = nil) {
        guard self.activeTaskID != id, var value = self.sessions[id] else { return }
        if let fragment { value.fragment = fragment }
        if let comment { value.comment = comment }
        if let provider { value.provider = provider }
        self.sessions[id] = value
    }

    /// Changes editor visibility without affecting the request or its captured context.
    public func setRequestExpanded(id: UUID, expanded: Bool) {
        self.sessions[id]?.requestExpanded = expanded
    }

    public func submit(id: UUID, settings: AISettings) {
        guard self.mayAdmit(), !self.isActive, var value = self.sessions[id], !self.clearedForExit else { return }
        let requestID = UUID()
        value.state = .preparing; value.requestID = requestID; value.startedAt = Date(); value.finishedAt = nil; value.error = nil; value.result = ""
        self.sessions[id] = value; self.activeTaskID = id; self.cancelRequested = false; self.stopError = nil
        let prompt = value.prompt, provider = value.provider
        let probe = self.makeProbeRunner(); self.runner = probe
        self.deadline = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(self.timeLimit)) } catch { return }
            self.stopError = .timeout; self.cancel()
        }
        self.operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capability = try await AICLIInspector.check(provider: provider, settings: settings, runner: probe, isCancelled: { self.cancelRequested })
                guard !self.cancelRequested else { throw AIError.cancelled }
                guard self.sessions[id]?.requestID == requestID else { return }
                self.sessions[id]?.state = .running
                let runner = self.makeRunner(); self.runner = runner
                let adapter = AIProviderAdapters.make(provider)
                let output = try await AICLIInspector.invoke(runner: runner, executable: capability.executable, arguments: adapter.arguments(model: settings.model(for: provider)), input: Data(prompt.utf8), onStarted: { self.onInferenceStarted?(provider, Date()) })
                guard !self.cancelRequested else { throw AIError.cancelled }
                guard output.exitCode == 0 else { throw AIError.classify(String(decoding: output.stderr + output.stdout, as: UTF8.self)) }
                try self.finish(id: id, requestID: requestID, result: .success(adapter.response(stdout: output.stdout)))
            } catch { self.finish(id: id, requestID: requestID, result: .failure(self.stopError ?? (error as? AIError) ?? .processFailed)) }
        }
    }

    public func cancel() {
        guard self.isActive else { return }
        if self.stopError == nil { self.stopError = .cancelled }
        self.cancelRequested = true; self.runner?.cancel()
    }

    public func retain(ids: Set<UUID>) {
        if let activeTaskID = self.activeTaskID, !ids.contains(activeTaskID) { self.cancel() }
        self.sessions = self.sessions.filter { ids.contains($0.key) || $0.key == self.activeTaskID }
    }

    /// Eviction cannot interrupt the already-running request; its result is pruned on the next idle callback.
    public func retainBootstrap(ids: Set<UUID>) {
        self.sessions = self.sessions.filter { !$0.value.snapshot.metadataOnly || $0.value.snapshot.outputUnavailable || ids.contains($0.key) || $0.key == self.activeTaskID }
    }

    public func clearForExit() {
        self.clearedForExit = true
        if self.isActive { self.cancel() } else { self.sessions.removeAll() }
    }

    private func finish(id: UUID, requestID: UUID, result: Result<String, AIError>) {
        guard self.sessions[id]?.requestID == requestID else { return }
        self.sessions[id]?.finishedAt = Date()
        switch result {
        case let .success(text): self.sessions[id]?.state = .succeeded; self.sessions[id]?.result = text; self.sessions[id]?.requestExpanded = false
        case let .failure(error): self.sessions[id]?.state = error == .cancelled ? .cancelled : .failed; self.sessions[id]?.error = error
        }
        self.activeTaskID = nil; self.runner = nil; self.operation = nil
        self.deadline?.cancel(); self.deadline = nil
        if self.clearedForExit { self.sessions.removeAll() }
        self.onIdle?()
    }
}
