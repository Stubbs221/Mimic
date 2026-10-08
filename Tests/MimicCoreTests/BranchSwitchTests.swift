// Created by Василий Маслов on 07.10.2026.
import Foundation
import Testing
@testable import MimicCore

private struct SwitchFixture: Sendable {
    let root: URL
    var repo: URL { self.root.appendingPathComponent("repo") }
    var upstream: URL { self.root.appendingPathComponent("upstream") }
    var project: ProjectContext { get throws { ProjectContext(path: self.repo.path, branch: "source", commit: try self.git(["rev-parse", "source"])) } }
    init(conflict: Bool = false) throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicSwitchTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: self.repo, withIntermediateDirectories: true)
        try self.git(["init", "-b", "source"])
        try self.git(["config", "user.name", "Fixture"]); try self.git(["config", "user.email", "fixture@example.invalid"])
        for name in ["conflict.txt", "staged.txt", "unstaged.txt"] { try self.write(name, "base\n") }
        try self.git(["add", "."]); try self.git(["commit", "-m", "base"])
        try self.git(["branch", "develop"]); try self.git(["switch", "-c", "feature/quoted-$value"])
        try self.write(conflict ? "conflict.txt" : "feature.txt", "feature\n")
        try self.git(["add", "."]); try self.git(["commit", "-m", "feature"]); try self.git(["switch", "source"])
        try self.git(["init", "--bare", root.appendingPathComponent("remote.git").path])
        try self.git(["remote", "add", "origin", root.appendingPathComponent("remote.git").path]); try self.git(["push", "origin", "develop"])
        try self.git(["clone", "--branch", "develop", root.appendingPathComponent("remote.git").path, self.upstream.path])
        try self.git(["config", "user.name", "Fixture"], path: self.upstream.path); try self.git(["config", "user.email", "fixture@example.invalid"], path: self.upstream.path)
        try self.write(conflict ? "conflict.txt" : "develop.txt", "upstream\n", directory: self.upstream)
        try self.git(["add", "."], path: self.upstream.path); try self.git(["commit", "-m", "develop update"], path: self.upstream.path)
        try self.git(["push", "origin", "develop"], path: self.upstream.path)
    }
    func write(_ name: String, _ contents: String, directory: URL? = nil) throws { try Data(contents.utf8).write(to: (directory ?? self.repo).appendingPathComponent(name)) }
    @discardableResult func git(_ args: [String], path: String? = nil) throws -> String {
        let result = BranchGitProcess.capture("/usr/bin/git", ["-C", path ?? self.repo.path] + args, directory: nil, environment: nil, timeout: 15)
        guard result.0 == 0 else { throw BranchSwitchError.command(result.1) }
        return result.1.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func remove() { try? FileManager.default.removeItem(at: self.root) }
    func operation(rebase: Bool = true, target: String = "feature/quoted-$value") throws -> BranchSwitchOperation {
        BranchSwitchOperation(id: UUID(), source: try self.project, target: target, rebase: rebase)
    }
}

private actor SwitchJournal {
    var latest: BranchSwitchOperation?
    func add(_ op: BranchSwitchOperation) { self.latest = op }
}

struct BranchSwitchTests {
    @Test func rejectedCheckoutRestoresOriginalEditsWithoutOverwritingIgnoredFiles() async throws {
        let f = try SwitchFixture(); defer { f.remove() }
        try f.git(["switch", "feature/quoted-$value"])
        try f.write("collision.txt", "target tracked\n"); try f.git(["add", "."]); try f.git(["commit", "-m", "tracked collision"])
        try f.git(["switch", "source"])
        try Data("collision.txt\n".utf8).write(to: f.repo.appendingPathComponent(".git/info/exclude"))
        try f.write("collision.txt", "keep ignored\n"); try f.write("unstaged.txt", "keep local\n")
        let engine = BranchSwitchGit(temporaryRoot: f.root), journal = SwitchJournal()
        do { _ = try await engine.prepare(f.operation(rebase: false)) { await journal.add($0) }; Issue.record("Expected ignored collision") }
        catch BranchSwitchError.command { }
        let stopped = try #require(await journal.latest)
        let recovered = await engine.recover(stopped, cancelled: false) { await journal.add($0) }
        #expect(recovered.phase == .failed)
        #expect(try f.git(["branch", "--show-current"]) == "source")
        #expect(try String(contentsOf: f.repo.appendingPathComponent("collision.txt"), encoding: .utf8) == "keep ignored\n")
        #expect(try String(contentsOf: f.repo.appendingPathComponent("unstaged.txt"), encoding: .utf8) == "keep local\n")
        #expect(recovered.stashSHA != nil)
    }

    @MainActor @Test func cancellationAndClosedHandoffKeepOneOwner() async throws {
        let f = try SwitchFixture(); defer { f.remove() }
        let suite = "SwitchCancel-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = BranchSwitchCoordinator(defaults: defaults, temporaryRoot: f.root)
        try coordinator.setRebase(true, path: f.repo.path)
        let id = UUID(); _ = try coordinator.start(id: id, project: f.project, target: "feature/quoted-$value")
        let result = try await coordinator.cancel(id)
        #expect(result.phase == .cancelled); #expect(!coordinator.hasPending)
        #expect(try f.git(["branch", "--show-current"]) == "source")
    }
    @Test func rebaseLeavesOriginalCheckoutUntouchedUntilFinalSwitch() async throws {
        let f = try SwitchFixture(); defer { f.remove() }
        let original = try f.project, oldTarget = try f.git(["rev-parse", "feature/quoted-$value"])
        let engine = BranchSwitchGit(temporaryRoot: f.root)
        let result = try await engine.prepare(f.operation()) { op in
            if [.checking, .fetching, .rebasing, .stashing].contains(op.phase) {
                let branch = try f.git(["branch", "--show-current"]), sha = try f.git(["rev-parse", "HEAD"])
                #expect(branch == "source"); #expect(sha == original.commit)
            }
        }
        #expect(result.phase == .succeeded)
        #expect(try f.git(["branch", "--show-current"]) == result.target)
        #expect(result.resultSHA != oldTarget)
        #expect(try f.git(["merge-base", result.target, "origin/develop"]) == result.developSHA)
        #expect(try f.git(["rev-parse", "source"]) == original.commit)
        #expect(!FileManager.default.fileExists(atPath: result.worktree!))
    }

    @Test(arguments: [false, true]) func localChangesAndIndexTransferWithRetainedBackup(rebase: Bool) async throws {
        let f = try SwitchFixture(); defer { f.remove() }
        try f.write("staged.txt", "staged\n"); try f.git(["add", "staged.txt"])
        try f.write("unstaged.txt", "unstaged\n"); try f.write("untracked.txt", "untracked\n")
        try f.write("ignored.txt", "ignored\n"); try Data("ignored.txt\n".utf8).write(to: f.repo.appendingPathComponent(".git/info/exclude"))
        let before = try f.git(["status", "--porcelain=v1", "-z"])
        let result = try await BranchSwitchGit(temporaryRoot: f.root).prepare(f.operation(rebase: rebase)) { _ in }
        #expect(result.phase == .succeeded)
        #expect(try f.git(["status", "--porcelain=v1", "-z"]) == before)
        #expect(try f.git(["stash", "list", "--format=%H"]).contains(result.stashSHA!))
        #expect(try String(contentsOf: f.repo.appendingPathComponent("ignored.txt"), encoding: .utf8) == "ignored\n")
    }

    @Test func rebaseConflictIsAbortedAndAgentCompletesPinnedOperation() async throws {
        let f = try SwitchFixture(conflict: true); defer { f.remove() }
        try f.write("unstaged.txt", "keep local\n")
        let engine = BranchSwitchGit(temporaryRoot: f.root)
        let op = try await engine.prepare(f.operation()) { _ in }
        let path = try #require(op.worktree)
        #expect(op.phase == .awaitingAgent); #expect(op.conflict == .rebase); #expect(op.stashSHA == nil)
        #expect(op.conflictPaths == ["conflict.txt"]); #expect(op.stoppedCommit != nil)
        #expect(try f.git(["rev-parse", "HEAD"], path: path) == op.targetSHA)
        #expect(try f.git(["status", "--porcelain=v1"], path: path).isEmpty)
        #expect(try f.git(["branch", "--show-current"]) == "source")
        #expect(try String(contentsOf: f.repo.appendingPathComponent("unstaged.txt"), encoding: .utf8) == "keep local\n")
        // Repeat the same rebase and emulate a resolver, without touching the main checkout.
        let retry = BranchGitProcess.capture("/usr/bin/git", ["-C", path, "-c", "rebase.updateRefs=false", "rebase", "--no-update-refs", op.developSHA!], directory: nil, environment: nil)
        #expect(retry.0 != 0)
        try f.write("conflict.txt", "resolved\n", directory: URL(fileURLWithPath: path)); try f.git(["add", "conflict.txt"], path: path)
        try f.git(["-c", "core.editor=true", "rebase", "--continue"], path: path)
        for marker in ["rebase-merge", "rebase-apply"] {
            let markerPath = try f.git(["rev-parse", "--git-path", marker], path: path)
            #expect(!FileManager.default.fileExists(atPath: markerPath), "Remaining marker: \(marker)")
        }
        #expect(try f.git(["status", "--porcelain=v1"], path: path).isEmpty)
        let result = try await engine.finish(op) { _ in }
        #expect(result.phase == .succeeded)
        #expect(try String(contentsOf: f.repo.appendingPathComponent("conflict.txt"), encoding: .utf8) == "resolved\n")
        #expect(result.stashSHA != nil)
    }

    @Test func stashConflictStaysOnTargetAndKeepsBackup() async throws {
        let f = try SwitchFixture(conflict: true); defer { f.remove() }
        try f.write("conflict.txt", "local edits\n")
        let engine = BranchSwitchGit(temporaryRoot: f.root)
        let op = try await engine.prepare(f.operation(rebase: false)) { _ in }
        #expect(op.phase == .awaitingAgent); #expect(op.conflict == .stash); #expect(op.didSwitch)
        #expect(try f.git(["branch", "--show-current"]) == op.target)
        #expect(try f.git(["stash", "list", "--format=%H"]).contains(op.stashSHA!))
        try f.write("conflict.txt", "feature plus local edits\n"); try f.git(["add", "conflict.txt"])
        let result = try await engine.finish(op) { _ in }
        #expect(result.phase == .succeeded)
        #expect(try f.git(["diff", "--cached", "--name-only"]) == "conflict.txt")
    }

    @Test func developOnlyFastForwardsAndDivergenceDoesNotSwitch() async throws {
        let f = try SwitchFixture(); defer { f.remove() }
        let result = try await BranchSwitchGit(temporaryRoot: f.root).prepare(f.operation(target: "develop")) { _ in }
        #expect(result.phase == .succeeded); #expect(result.resultSHA == result.developSHA); #expect(result.worktree == nil)
        try f.write("diverged.txt", "local develop commit\n"); try f.git(["add", "."]); try f.git(["commit", "-m", "diverge"]); try f.git(["switch", "source"])
        await #expect(throws: BranchSwitchError.diverged) { try await BranchSwitchGit(temporaryRoot: f.root).prepare(f.operation(target: "develop")) { _ in } }
        #expect(try f.git(["branch", "--show-current"]) == "source")
    }

    @Test func failedFetchNeverUsesStaleDevelop() async throws {
        let f = try SwitchFixture(); defer { f.remove() }
        try f.git(["remote", "set-url", "origin", f.root.appendingPathComponent("missing.git").path])
        do { _ = try await BranchSwitchGit(temporaryRoot: f.root).prepare(f.operation()) { _ in }; Issue.record("Expected fetch failure") }
        catch BranchSwitchError.command { }
        #expect(try f.git(["branch", "--show-current"]) == "source")
        #expect(try f.git(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ").count == 2)
    }

    @Test func occupiedMissingAndExternalRefChangesAreRejected() async throws {
        let f = try SwitchFixture(); defer { f.remove() }
        let engine = BranchSwitchGit(temporaryRoot: f.root)
        await #expect(throws: BranchSwitchError.missing) { try await engine.prepare(f.operation(target: "missing")) { _ in } }
        let linked = f.root.appendingPathComponent("occupied").path
        try f.git(["worktree", "add", linked, "feature/quoted-$value"])
        await #expect(throws: BranchSwitchError.occupied) { try await engine.prepare(f.operation()) { _ in } }
        try f.git(["worktree", "remove", linked])
        await #expect(throws: BranchSwitchError.context) {
            try await engine.prepare(f.operation()) { op in
                if op.phase == .rebasing && op.resultSHA != nil { try f.git(["update-ref", "refs/heads/feature/quoted-$value", "source"]) }
            }
        }
        #expect(try f.git(["branch", "--show-current"]) == "source")
    }

    @MainActor @Test func preferenceIdempotencyOwnershipAndRestartAreDurable() async throws {
        let f = try SwitchFixture(conflict: true); defer { f.remove() }
        let suite = "MimicBranchSwitchTests-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = BranchSwitchCoordinator(defaults: defaults, temporaryRoot: f.root)
        #expect(!coordinator.rebaseEnabled(path: f.repo.path))
        try coordinator.setRebase(true, path: f.repo.path)
        #expect(!coordinator.rebaseEnabled(path: f.upstream.path))
        let id = UUID(), project = try f.project
        let first = try coordinator.start(id: id, project: project, target: "feature/quoted-$value")
        #expect(try coordinator.start(id: id, project: project, target: first.target).id == id)
        #expect(throws: BranchSwitchError.context) { try coordinator.start(id: id, project: project, target: "develop") }
        #expect(throws: BranchSwitchError.blocked) { try coordinator.setRebase(false, path: project.path) }
        let deadline = Date().addingTimeInterval(15)
        while coordinator.isExecuting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!coordinator.isExecuting); #expect(coordinator.active?.phase == .awaitingAgent)
        coordinator.heartbeat(threadID: "panel-a", path: project.path, canSend: true)
        #expect(try coordinator.reserveDelivery(threadID: "panel-a", path: project.path)?.id == id)
        #expect(try coordinator.reserveDelivery(threadID: "panel-a", path: project.path) == nil)
        try coordinator.deliveryResult(id, threadID: "panel-a", sent: false)
        #expect(try coordinator.operation(id).delivery == .unknown)
        _ = try coordinator.claim(id, threadID: "agent-a")
        #expect(throws: BranchSwitchError.ownership) { try coordinator.claim(id, threadID: "agent-b") }
        #expect(coordinator.hasPending)
        let restored = BranchSwitchCoordinator(defaults: defaults, temporaryRoot: f.root)
        #expect(restored.active?.phase == .needsReview); #expect(restored.hasPending)
        #expect(restored.rebaseEnabled(path: project.path))
        #expect(restored.active?.diagnostic.isEmpty == true)
        #expect(try await restored.cancel(id).phase == .cancelled)
        #expect(!restored.hasPending)
    }
}
