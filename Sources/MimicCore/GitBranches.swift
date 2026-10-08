//
//  GitBranches.swift
//  MimicCore
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation

/// A fresh checkout snapshot, including operations that make ordinary switching unsafe.
public struct GitCheckoutState: Sendable {
    public let project: ProjectContext
    public let summary: GitSummary
    public let hasOperation: Bool
    public var isClean: Bool { self.summary.changed == 0 && self.summary.untracked == 0 }
    public init(project: ProjectContext, summary: GitSummary, hasOperation: Bool) {
        self.project = project; self.summary = summary; self.hasOperation = hasOperation
    }
}

public struct LocalBranch: Identifiable, Equatable, Sendable {
    public var id: String { self.name }
    public let name: String
    public init(name: String) { self.name = name }
}

public enum BranchError: Error, Equatable {
    case dirty
    case operation
    case missing
    case command(String)
}

/// Queries and a guarded ordinary switch. Implementations never fetch or discard edits.
public protocol GitBranchService: Sendable {
    func inspect(_ project: ProjectContext) async throws -> GitCheckoutState
    func branches(_ project: ProjectContext) async throws -> [LocalBranch]
    func switchBranch(_ name: String, project: ProjectContext) async throws -> GitCheckoutState
}

public struct LocalGitBranchService: GitBranchService {
    public init() { }
    public func inspect(_ project: ProjectContext) async throws -> GitCheckoutState {
        try await Task.detached { try Self.snapshot(project) }.value
    }

    public func branches(_ project: ProjectContext) async throws -> [LocalBranch] {
        try await Task.detached { try Self.localBranches(project) }.value
    }

    public func switchBranch(_ name: String, project: ProjectContext) async throws -> GitCheckoutState {
        try await Task.detached {
            try Task.checkCancellation()
            let state = try Self.snapshot(project)
            guard state.isClean else { throw BranchError.dirty }
            guard !state.hasOperation else { throw BranchError.operation }
            guard try Self.localBranches(project).contains(where: { $0.name == name }) else { throw BranchError.missing }
            try Self.git(project, ["switch", "--no-guess", "--", name], timeout: 60)
            return try Self.snapshot(project)
        }.value
    }

    private static func snapshot(_ project: ProjectContext) throws -> GitCheckoutState {
        let context = try EnvironmentInspector.project(path: project.path, developerDirectory: project.developerDirectory, appleTarget: project.appleTarget)
        let status = try self.git(context, ["status", "--porcelain=v1", "-z"], trim: false)
        let markers = ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer"]
        let operation = try markers.contains { marker in
            let path = try self.git(context, ["rev-parse", "--git-path", marker])
            let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: context.path, isDirectory: true))
            return FileManager.default.fileExists(atPath: url.path)
        }
        return GitCheckoutState(project: context, summary: GitSummary(porcelain: status), hasOperation: operation)
    }

    private static func localBranches(_ project: ProjectContext) throws -> [LocalBranch] {
        try self.git(project, ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads/"])
            .split(separator: "\n").map { LocalBranch(name: String($0)) }
    }

    /// One pipe avoids stdout/stderr deadlocks; only Git's error text is surfaced.
    @discardableResult
    private static func git(_ project: ProjectContext, _ arguments: [String], trim: Bool = true, timeout: TimeInterval = 8) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", project.path] + arguments
        process.standardOutput = pipe; process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); deadline.cancel()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw BranchError.command(String(output.prefix(2000))) }
        return trim ? output.trimmingCharacters(in: .whitespacesAndNewlines) : output
    }
}

/// Covers both queued records and the admission interval before a record exists.
@MainActor
public final class CheckoutMutationGate {
    public private(set) var isSwitching = false
    public private(set) var admissions = 0
    public init() { }
    public func admitTask() -> Bool {
        guard !self.isSwitching else { return false }
        self.admissions += 1; return true
    }

    public func finishAdmission() { self.admissions = max(0, self.admissions - 1) }
    public func canSwitch(records: [TaskRecord], preparing: Bool) -> Bool {
        !self.isSwitching && self.admissions == 0 && !preparing && !records.contains { $0.status == .queued || $0.status == .running }
    }

    public func beginSwitch(records: [TaskRecord], preparing: Bool) -> Bool {
        guard self.canSwitch(records: records, preparing: preparing) else { return false }
        self.isSwitching = true; return true
    }

    public func finishSwitch() { self.isSwitching = false }
}
