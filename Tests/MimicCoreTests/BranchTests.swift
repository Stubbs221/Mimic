//
//  BranchTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation
import Testing
@testable import MimicCore

private struct GitFixture {
    let root: URL
    var project: ProjectContext { get throws { try EnvironmentInspector.project(path: self.root.path) } }
    init() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicBranchTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: self.root.appendingPathComponent("App/App.xcworkspace"), withIntermediateDirectories: true)
        for name in ["bootstrap.sh", "utils.sh", "tracked.swift"] { try Data("// Created by Василий Маслов on 02.10.2026.\n".utf8).write(to: self.root.appendingPathComponent(name)) }
        try self.git(["init", "-b", "main"])
        try self.git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "add", "."])
        try self.git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"])
        try self.git(["branch", "feature/with spaces"], succeeds: false)
        try self.git(["branch", "feature/quoted-$value"])
    }

    @discardableResult
    func git(_ arguments: [String], succeeds: Bool = true) throws -> String {
        let result = EnvironmentInspector.capture("/usr/bin/git", ["-C", self.root.path] + arguments)
        #expect((result.0 == 0) == succeeds)
        return result.1
    }

    func remove() { try? FileManager.default.removeItem(at: self.root) }
}

struct BranchTests {
    @Test
    func ordinarySwitchUsesLiteralLocalName() async throws {
        let fixture = try GitFixture(); defer { fixture.remove() }
        let service = LocalGitBranchService(), project = try fixture.project
        let branches = try await service.branches(project)
        #expect(branches.map(\.name).contains("feature/quoted-$value"))
        #expect(branches.map(\.name).contains("main"))
        let result = try await service.switchBranch("feature/quoted-$value", project: project)
        #expect(result.project.branch == "feature/quoted-$value")
        #expect(result.isClean)
    }

    @Test(arguments: [true, false])
    func trackedAndUntrackedEditsBlockSwitch(tracked: Bool) async throws {
        let fixture = try GitFixture(); defer { fixture.remove() }
        try Data("fixture change".utf8).write(to: fixture.root.appendingPathComponent(tracked ? "tracked.swift" : "new.swift"))
        await #expect(throws: BranchError.dirty) { try await LocalGitBranchService().switchBranch("feature/quoted-$value", project: fixture.project) }
        #expect(try fixture.project.branch == "main")
    }

    @Test(arguments: ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"])
    func unfinishedOperationsBlockSwitch(marker: String) async throws {
        let fixture = try GitFixture(); defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent(".git/" + marker)
        if marker.hasPrefix("rebase-") { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        else { try Data((fixture.project.commit).utf8).write(to: path) }
        let service = LocalGitBranchService()
        #expect(try await service.inspect(fixture.project).hasOperation)
        await #expect(throws: BranchError.operation) { try await service.switchBranch("feature/quoted-$value", project: fixture.project) }
    }

    @Test
    func occupiedWorktreeAndMissingBranchAreNotForced() async throws {
        let fixture = try GitFixture(); defer { fixture.remove() }
        let linked = fixture.root.appendingPathComponent("linked")
        // An ignored sibling keeps the main worktree clean.
        try Data("linked/\n".utf8).write(to: fixture.root.appendingPathComponent(".git/info/exclude"))
        try fixture.git(["worktree", "add", linked.path, "feature/quoted-$value"])
        let service = LocalGitBranchService()
        do {
            _ = try await service.switchBranch("feature/quoted-$value", project: fixture.project)
            Issue.record("A branch occupied by another worktree was switched")
        } catch BranchError.command { }
        #expect(try fixture.project.branch == "main")
        await #expect(throws: BranchError.missing) { try await service.switchBranch("missing", project: fixture.project) }
    }

    @MainActor @Test
    func admissionsQueueAndRepeatedClicksAreSerialized() {
        let gate = CheckoutMutationGate()
        #expect(gate.admitTask())
        #expect(!gate.beginSwitch(records: [], preparing: false))
        gate.finishAdmission()
        let queued = TaskRecord(action: .format, project: ProjectContext(path: "/fixture"))
        #expect(!gate.beginSwitch(records: [queued], preparing: false))
        var running = queued; running.status = .running
        #expect(!gate.beginSwitch(records: [running], preparing: false))
        #expect(!gate.beginSwitch(records: [], preparing: true))
        #expect(gate.beginSwitch(records: [], preparing: false))
        #expect(!gate.admitTask())
        #expect(!gate.beginSwitch(records: [], preparing: false))
        gate.finishSwitch()
        #expect(gate.admitTask()); gate.finishAdmission()
        #expect(gate.canSwitch(records: [], preparing: false))
    }
}
