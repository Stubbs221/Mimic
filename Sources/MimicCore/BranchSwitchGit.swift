// Created by Василий Маслов on 07.10.2026.
import Foundation

/// Serialized Git work runs off the main actor. Only the final step touches the original working tree.
actor BranchSwitchGit {
    typealias Update = @Sendable (BranchSwitchOperation) async throws -> Void
    private let temporaryRoot: URL
    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) { self.temporaryRoot = temporaryRoot }

    // MARK: - Preparation and finalization

    func prepare(_ initial: BranchSwitchOperation, update: Update) async throws -> BranchSwitchOperation {
        var op = initial
        try self.verifySource(op)
        guard op.source.branch != "(detached)", try self.optionalGit(op.source.path, ["symbolic-ref", "-q", "HEAD"]) != nil else { throw BranchSwitchError.detached }
        guard op.target != op.source.branch else { op.phase = .succeeded; try await update(op); return op }
        guard try self.optionalGit(op.source.path, ["show-ref", "--verify", "--hash", "refs/heads/" + op.target]) != nil else { throw BranchSwitchError.missing }
        try self.verifyUnoccupied(op)
        op.targetSHA = try self.git(op.source.path, ["rev-parse", "--verify", "refs/heads/" + op.target])
        try await update(op)
        if op.rebase {
            op.phase = .fetching; try await update(op)
            try self.git(op.source.path, ["fetch", "--no-tags", "--no-recurse-submodules", "origin", "+refs/heads/develop:refs/remotes/origin/develop"], timeout: 120)
            op.developSHA = try self.git(op.source.path, ["rev-parse", "--verify", "refs/remotes/origin/develop^{commit}"])
            if op.target == "develop" {
                guard try self.isAncestor(op.targetSHA!, op.developSHA!, path: op.source.path) else { throw BranchSwitchError.diverged }
                op.resultSHA = op.developSHA; try await update(op)
            } else {
                op.worktree = self.temporaryRoot.appendingPathComponent("MimicBranchSwitch-" + op.id.uuidString).path
                op.phase = .rebasing; try await update(op)
                try self.git(op.source.path, ["worktree", "add", "--detach", op.worktree!, op.targetSHA!], timeout: 60)
                let result = self.capture(op.worktree!, ["-c", "rebase.updateRefs=false", "-c", "rebase.autoStash=false", "rebase", "--no-update-refs", "--no-autostash", op.developSHA!], timeout: 120)
                if result.0 != 0 {
                    let paths = try self.conflicts(op.worktree!)
                    guard !paths.isEmpty, try self.hasOperation(op.worktree!) else { throw BranchSwitchError.command(self.diagnostic(result.1)) }
                    op.conflict = .rebase; op.conflictPaths = paths
                    op.stoppedCommit = try self.optionalGit(op.worktree!, ["rev-parse", "--verify", "REBASE_HEAD"])
                    op.diagnostic = self.diagnostic(result.1)
                    // Capture identities before abort, and verify abort rather than inferring it from an exit request.
                    try await update(op)
                    try self.git(op.worktree!, ["rebase", "--abort"], cancellable: false)
                    guard try !self.hasOperation(op.worktree!), try self.git(op.worktree!, ["rev-parse", "HEAD"]) == op.targetSHA,
                          try self.git(op.worktree!, ["status", "--porcelain=v1", "-z"]).isEmpty else { throw BranchSwitchError.review }
                    op.phase = .awaitingAgent; try await update(op); return op
                }
                op.resultSHA = try self.git(op.worktree!, ["rev-parse", "HEAD"]); try await update(op)
            }
        } else { op.resultSHA = op.targetSHA; try await update(op) }
        return try await self.finish(op, update: update)
    }

    func finish(_ initial: BranchSwitchOperation, update: Update) async throws -> BranchSwitchOperation {
        var op = initial
        if op.didSwitch {
            try self.verifyDestination(op)
            op.phase = .succeeded; op.error = nil; try await update(op)
            try self.removeWorktree(op); return op
        }
        try self.verifySource(op); try self.verifyUnoccupied(op)
        guard let old = op.targetSHA, try self.git(op.source.path, ["rev-parse", "refs/heads/" + op.target]) == old else { throw BranchSwitchError.context }
        if let worktree = op.worktree {
            guard try !self.hasOperation(worktree), try self.conflicts(worktree).isEmpty,
                  try self.git(worktree, ["status", "--porcelain=v1", "-z"]).isEmpty else { throw BranchSwitchError.review }
            op.resultSHA = try self.git(worktree, ["rev-parse", "HEAD"])
            guard let base = op.developSHA, try self.isAncestor(base, op.resultSHA!, path: worktree) else { throw BranchSwitchError.review }
        }
        guard let result = op.resultSHA else { throw BranchSwitchError.review }
        op.phase = .stashing; try await update(op)
        if try !self.git(op.source.path, ["status", "--porcelain=v1", "-z"]).isEmpty {
            op.stashName = "Mimic switch " + op.id.uuidString + " " + op.source.branch + " → " + op.target
            try await update(op)
            try self.git(op.source.path, ["stash", "push", "--include-untracked", "--message", op.stashName!], timeout: 60)
            op.stashSHA = try self.git(op.source.path, ["rev-parse", "refs/stash"]); try await update(op)
        }
        guard try self.git(op.source.path, ["status", "--porcelain=v1", "-z"]).isEmpty else { throw BranchSwitchError.review }
        try self.verifySource(op); try self.verifyUnoccupied(op)
        op.phase = .switching; try await update(op)
        try self.git(op.source.path, ["update-ref", "-m", "Mimic branch switch " + op.id.uuidString, "refs/heads/" + op.target, result, old])
        op.refUpdated = true; try await update(op)
        try self.git(op.source.path, ["switch", "--no-guess", "--no-overwrite-ignore", "--", op.target], timeout: 60)
        op.didSwitch = true; op.phase = .restoring; try await update(op)
        if let stash = op.stashSHA {
            let restored = self.capture(op.source.path, ["stash", "apply", "--index", stash], timeout: 60)
            if restored.0 != 0 {
                // Includes index/untracked collisions which may not create unmerged index entries.
                op.conflict = .stash; op.conflictPaths = try self.conflicts(op.source.path)
                op.diagnostic = self.diagnostic(restored.1); op.phase = op.ownerThreadID == nil ? .awaitingAgent : .resolving
                try await update(op); return op
            }
        }
        try self.verifyDestination(op)
        op.phase = .succeeded; op.error = nil; try await update(op)
        try self.removeWorktree(op); return op
    }

    // MARK: - Failure and cancellation

    /// Never reset user files. Failed finalization restores a stash only onto a verified clean original checkout.
    func recover(_ initial: BranchSwitchOperation, cancelled: Bool, update: Update) async -> BranchSwitchOperation {
        var op = initial
        do {
            if let worktree = op.worktree, FileManager.default.fileExists(atPath: worktree) {
                if try self.hasOperation(worktree) {
                    guard op.ownerThreadID == nil else { throw BranchSwitchError.review }
                    try self.git(worktree, ["rebase", "--abort"], cancellable: false)
                }
                guard try self.conflicts(worktree).isEmpty else { throw BranchSwitchError.review }
            }
            // The journal can lag a successful switch by one filesystem write.
            let branch = try self.git(op.source.path, ["symbolic-ref", "--short", "HEAD"], cancellable: false)
            guard branch == op.source.branch, try self.git(op.source.path, ["rev-parse", "HEAD"], cancellable: false) == op.source.commit,
                  try !self.hasOperation(op.source.path), try self.conflicts(op.source.path).isEmpty else { throw BranchSwitchError.review }
            if op.stashSHA == nil, let name = op.stashName {
                let entries = try self.git(op.source.path, ["stash", "list", "--format=%H%x00%gs"], cancellable: false)
                op.stashSHA = entries.split(separator: "\n").first(where: { $0.contains(name) })?.split(separator: "\0").first.map(String.init)
            }
            if let stash = op.stashSHA {
                guard try self.git(op.source.path, ["status", "--porcelain=v1", "-z"], cancellable: false).isEmpty else { throw BranchSwitchError.review }
                try self.git(op.source.path, ["stash", "apply", "--index", stash], timeout: 60, cancellable: false)
            }
            if op.refUpdated, let old = op.targetSHA, let new = op.resultSHA, old != new,
               try self.git(op.source.path, ["rev-parse", "refs/heads/" + op.target], cancellable: false) == new {
                try self.verifyUnoccupied(op)
                try self.git(op.source.path, ["update-ref", "refs/heads/" + op.target, old, new], cancellable: false)
            }
            try self.removeWorktree(op)
            op.phase = cancelled ? .cancelled : .failed
        } catch { op.phase = .needsReview }
        try? await update(op); return op
    }

    /// A claimed agent must first stop its processes and leave both trees outside any Git operation.
    func cancel(_ initial: BranchSwitchOperation, update: Update) async throws -> BranchSwitchOperation {
        var op = initial
        guard try !self.hasOperation(op.source.path), try self.conflicts(op.source.path).isEmpty else { throw BranchSwitchError.review }
        if let worktree = op.worktree, FileManager.default.fileExists(atPath: worktree) {
            guard try !self.hasOperation(worktree), try self.conflicts(worktree).isEmpty,
                  try self.git(worktree, ["status", "--porcelain=v1", "-z"]).isEmpty else { throw BranchSwitchError.review }
        }
        if op.phase == .needsReview {
            // Restart recovery requires explicit acknowledgment of actual Git state; no replay or rollback.
            try self.removeWorktree(op); op.phase = .cancelled; try await update(op); return op
        }
        return await self.recover(op, cancelled: true, update: update)
    }

    // MARK: - Git identities and bounded diagnostics

    private func verifySource(_ op: BranchSwitchOperation) throws {
        guard try self.git(op.source.path, ["symbolic-ref", "--short", "HEAD"]) == op.source.branch,
              try self.git(op.source.path, ["rev-parse", "HEAD"]) == op.source.commit else { throw BranchSwitchError.context }
        guard try !self.hasOperation(op.source.path), try self.conflicts(op.source.path).isEmpty else { throw BranchSwitchError.operation }
    }
    private func verifyDestination(_ op: BranchSwitchOperation) throws {
        guard try self.git(op.source.path, ["symbolic-ref", "--short", "HEAD"]) == op.target,
              try self.git(op.source.path, ["rev-parse", "HEAD"]) == op.resultSHA,
              try !self.hasOperation(op.source.path), try self.conflicts(op.source.path).isEmpty else { throw BranchSwitchError.review }
    }
    private func verifyUnoccupied(_ op: BranchSwitchOperation) throws {
        let worktrees = try self.git(op.source.path, ["worktree", "list", "--porcelain"])
        guard !worktrees.split(separator: "\n").contains(Substring("branch refs/heads/" + op.target)) else { throw BranchSwitchError.occupied }
    }
    private func hasOperation(_ path: String) throws -> Bool {
        try ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer"].contains { marker in
            let value = try self.git(path, ["rev-parse", "--git-path", marker], cancellable: false)
            return FileManager.default.fileExists(atPath: URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: path, isDirectory: true)).path)
        }
    }
    private func conflicts(_ path: String) throws -> [String] {
        try self.git(path, ["diff", "--name-only", "--diff-filter=U", "-z"], cancellable: false).split(separator: "\0").map(String.init)
    }
    private func isAncestor(_ ancestor: String, _ descendant: String, path: String) throws -> Bool {
        let result = self.capture(path, ["merge-base", "--is-ancestor", ancestor, descendant])
        guard result.0 == 0 || result.0 == 1 else { throw BranchSwitchError.command(self.diagnostic(result.1)) }
        return result.0 == 0
    }
    private func removeWorktree(_ op: BranchSwitchOperation) throws {
        guard let path = op.worktree, FileManager.default.fileExists(atPath: path) else { return }
        try self.git(op.source.path, ["worktree", "remove", path], timeout: 30, cancellable: false)
    }
    private func diagnostic(_ value: String) -> String { DiagnosticText.bounded(DiagnosticText.clean(value), limit: 16 * 1024).text }
    private func capture(_ path: String, _ arguments: [String], timeout: TimeInterval = 15, cancellable: Bool = true) -> (Int32, String) {
        let environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_EDITOR": "/usr/bin/true", "GIT_SEQUENCE_EDITOR": "/usr/bin/true", "LC_ALL": "en_US.UTF-8"]) { _, new in new }
        return BranchGitProcess.capture("/usr/bin/git", ["-C", path] + arguments, directory: path, environment: environment, timeout: timeout, cancellable: cancellable)
    }
    private func optionalGit(_ path: String, _ arguments: [String]) throws -> String? {
        let result = self.capture(path, arguments)
        if result.0 == 1 || result.0 == 128 { return nil }
        guard result.0 == 0 else { throw BranchSwitchError.command(self.diagnostic(result.1)) }
        return result.1.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @discardableResult private func git(_ path: String, _ arguments: [String], timeout: TimeInterval = 15, cancellable: Bool = true) throws -> String {
        let result = self.capture(path, arguments, timeout: timeout, cancellable: cancellable)
        guard result.0 == 0 else {
            if Task.isCancelled && cancellable { throw CancellationError() }
            throw BranchSwitchError.command(self.diagnostic(result.1))
        }
        return result.1.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
