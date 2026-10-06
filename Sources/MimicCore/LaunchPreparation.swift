//
//  LaunchPreparation.swift
//  MimicCore
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation

/// A normal application-quit request. Implementations must observe exit before requesting it,
/// wait asynchronously and never force termination or discard unsaved changes.
@MainActor
public protocol XcodeApplicationService: AnyObject {
    var hasRunningXcode: Bool { get }
    func closeXcode(timeout: Duration) async -> Bool
    func activateXcode()
}

/// These states hold the queue without marking a task running or allocating a PTY.
public enum LaunchPreparationState: Equatable, Sendable {
    case idle
    case checking(UUID)
    case closingXcode(UUID)
    case blockedByXcode(UUID)
    public var taskID: UUID? {
        switch self {
        case .idle: nil
        case let .checking(id),
             let .closingXcode(id),
             let .blockedByXcode(id): id
        }
    }

    public var holdsQueue: Bool { self.taskID != nil }
}

/// Preflight error keys are localized by the application, not persisted as executable commands.
public enum CommandPreparation: Sendable {
    case ready(CommandSpec)
    case failed(String)
}

/// Owns one queue admission attempt. A blocked Bootstrap needs explicit retry even after Xcode exits.
@MainActor
public final class LaunchPreparation {
    public typealias Inspect = @Sendable (TaskRecord) async -> CommandPreparation
    public private(set) var state = LaunchPreparationState.idle {
        didSet { self.onStateChange?(self.state) }
    }

    public var onStateChange: ((LaunchPreparationState) -> Void)?
    private let applications: any XcodeApplicationService
    private let timeout: Duration
    private var operation: Operation?
    private var attempt = UUID()
    private var task: Task<Void, Never>?
    private struct Operation {
        let record: TaskRecord
        let inspect: Inspect
        let launch: (CommandSpec) -> Void
        let failure: (String) -> Void
    }

    public init(applications: any XcodeApplicationService, timeout: Duration = .seconds(30)) {
        self.applications = applications; self.timeout = timeout
    }

    // MARK: - Queue admission

    /// Returns false when another admission attempt already holds the queue.
    @discardableResult
    public func start(record: TaskRecord, inspect: @escaping Inspect, launch: @escaping (CommandSpec) -> Void, failure: @escaping (String) -> Void) -> Bool {
        guard !self.state.holdsQueue else { return false }
        self.operation = Operation(record: record, inspect: inspect, launch: launch, failure: failure)
        self.perform(); return true
    }

    public func retry(id: UUID) {
        guard self.state == .blockedByXcode(id), self.operation?.record.id == id else { return }
        self.perform()
    }

    /// Cancels only this attempt; a late preflight or application-exit callback cannot launch it.
    public func cancel(id: UUID) {
        guard self.state.taskID == id else { return }
        self.attempt = UUID(); self.task?.cancel(); self.task = nil; self.operation = nil; self.state = .idle
    }

    public func cancelAll() { if let id = state.taskID { self.cancel(id: id) } }
    public func activateXcode() { self.applications.activateXcode() }

    // MARK: - Preparation lifecycle

    private func perform() {
        guard let operation else { return }
        let token = UUID(); attempt = token; state = .checking(operation.record.id)
        self.task = Task { [weak self] in
            guard let self else { return }
            let initial = await operation.inspect(operation.record)
            guard self.isCurrent(token) else { return }
            guard case var .ready(command) = initial else {
                if case let .failed(error) = initial { self.fail(error, operation: operation) }
                return
            }
            if operation.record.requiresXcodeQuit {
                if self.applications.hasRunningXcode {
                    self.state = .closingXcode(operation.record.id)
                    let closed = await self.applications.closeXcode(timeout: self.timeout)
                    guard self.isCurrent(token) else { return }
                    guard closed else { self.block(operation); return }
                }
                // Closing Xcode can take time; revalidate the checkout and capabilities afterwards.
                self.state = .checking(operation.record.id)
                let fresh = await operation.inspect(operation.record)
                guard self.isCurrent(token) else { return }
                guard case let .ready(checked) = fresh else {
                    if case let .failed(error) = fresh { self.fail(error, operation: operation) }
                    return
                }
                command = checked
                guard !self.applications.hasRunningXcode else { self.block(operation); return }
            }
            // No suspension between the final application check and handing off to the runner.
            self.operation = nil; self.task = nil; self.state = .idle
            operation.launch(command)
        }
    }

    private func isCurrent(_ token: UUID) -> Bool { self.attempt == token && !Task.isCancelled }
    private func block(_ operation: Operation) { self.task = nil; self.state = .blockedByXcode(operation.record.id) }
    private func fail(_ error: String, operation: Operation) {
        self.operation = nil; self.task = nil; self.state = .idle; operation.failure(error)
    }
}
