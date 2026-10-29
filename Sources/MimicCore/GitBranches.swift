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

/// A picker entry. Remote IDs use full refs so a local branch named origin/foo stays distinct.
public struct LocalBranch: Identifiable, Equatable, Sendable {
    public var id: String { self.isRemote ? "refs/remotes/origin/" + self.name : self.name }
    public let name: String
    public let isRemote: Bool
    public var displayName: String { self.isRemote ? "origin/" + self.name : self.name }
    public init(name: String, isRemote: Bool = false) { self.name = name; self.isRemote = isRemote }
}

public enum BranchError: Error, Equatable {
    case dirty
    case operation
    case missing
    case timeout
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
        try await Task.detached { try Self.availableBranches(project) }.value
    }

    public func switchBranch(_ name: String, project: ProjectContext) async throws -> GitCheckoutState {
        try await Task.detached {
            try Task.checkCancellation()
            let state = try Self.snapshot(project)
            guard state.isClean else { throw BranchError.dirty }
            guard !state.hasOperation else { throw BranchError.operation }
            let branches = try Self.availableBranches(project)
            guard let selected = branches.first(where: { $0.id == name }) else { throw BranchError.missing }
            if selected.isRemote && !branches.contains(where: { !$0.isRemote && $0.name == selected.name }) {
                try Self.git(project, ["switch", "--no-overwrite-ignore", "--track=direct", "-c", selected.name, selected.id], timeout: 60)
            } else {
                try Self.git(project, ["switch", "--no-guess", "--no-overwrite-ignore", "--", selected.name], timeout: 60)
            }
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

    /// Uses the fetched origin snapshot without network access; symbolic origin/HEAD is never a choice.
    private static func availableBranches(_ project: ProjectContext) throws -> [LocalBranch] {
        try self.git(project, ["for-each-ref", "--sort=-committerdate", "--format=%(refname)%09%(symref)", "refs/heads/", "refs/remotes/origin/"], trim: false)
            .split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 2, fields[1].isEmpty else { return nil }
                let ref = String(fields[0])
                if ref.hasPrefix("refs/heads/") { return LocalBranch(name: String(ref.dropFirst("refs/heads/".count))) }
                let name = String(ref.dropFirst("refs/remotes/origin/".count))
                guard name != "HEAD" else { return nil }
                return LocalBranch(name: name, isRemote: true)
            }
    }

    /// Own the entire process group: a stalled fsmonitor/helper cannot retain
    /// the pipe forever after the Git leader exits or ignores termination.
    @discardableResult
    private static func git(_ project: ProjectContext, _ arguments: [String], trim: Bool = true, timeout: TimeInterval = 8) throws -> String {
        let environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        let result = BranchGitProcess.capture("/usr/bin/git", ["-C", project.path] + arguments, directory: project.path,
                                              environment: environment, timeout: timeout, maximumBytes: 8 * 1024 * 1024)
        if result.0 == BranchGitProcess.timeoutExitCode { throw BranchError.timeout }
        let output = result.1
        guard result.0 == 0 else { throw BranchError.command(String(output.prefix(2000))) }
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
