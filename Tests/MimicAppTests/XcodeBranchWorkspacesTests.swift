//
//  XcodeBranchWorkspacesTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

private final class WorkspaceScriptFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    let rejectClose: Bool
    init(rejectClose: Bool = false) { self.rejectClose = rejectClose }
    func reopened() { self.lock.lock(); self.closed = false; self.lock.unlock() }
    func evaluate(_ source: String) throws -> XcodeRunAutomation.Response {
        self.lock.lock(); defer { self.lock.unlock() }
        if source.contains("close selectedWorkspace saving ask") {
            if self.rejectClose { throw BranchSwitchError.xcodeClose }
            self.closed = true; return .flag(true)
        }
        return .text(self.closed ? "" : "/fixture/repo/App.xcworkspace")
    }
}

@MainActor struct XcodeBranchWorkspacesTests {
    private func operation() -> BranchSwitchOperation {
        .init(id: UUID(), source: .init(path: "/fixture/repo", branch: "source", commit: "original"), target: "target", rebase: false)
    }

    @Test func keepsWorkspacesClosedDuringConflictAndReopensAfterCompletion() async throws {
        let suite = "XcodeBranch-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let script = WorkspaceScriptFixture()
        var opened: [XcodeBranchWorkspaces.Workspace] = []
        let service = XcodeBranchWorkspaces(defaults: defaults, automation: .init(evaluate: script.evaluate),
            applications: { ["/fixture/Xcode.app"] }, open: { opened.append($0); script.reopened() })
        var op = self.operation()
        try await service.prepare(op)
        op.phase = .awaitingAgent; try await service.restore(op)
        #expect(opened.isEmpty)
        op.phase = .succeeded; try await service.restore(op); try await service.restore(op)
        #expect(opened == [.init(application: "/fixture/Xcode.app", path: "/fixture/repo/App.xcworkspace")])
    }

    @Test func closeCancellationHasDurableRecoveryAndReopenFailureRetainsLease() async throws {
        let suite = "XcodeBranchRecovery-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let script = WorkspaceScriptFixture(rejectClose: true)
        var opened: [XcodeBranchWorkspaces.Workspace] = []
        let service = XcodeBranchWorkspaces(defaults: defaults, automation: .init(evaluate: script.evaluate),
            applications: { ["/fixture/Xcode.app"] }, open: { _ in throw BranchSwitchError.xcodeReopen })
        var op = self.operation()
        await #expect(throws: BranchSwitchError.xcodeClose) { try await service.prepare(op) }
        op.phase = .failed
        await #expect(throws: BranchSwitchError.xcodeReopen) { try await service.restore(op) }
        let recovered = XcodeBranchWorkspaces(defaults: defaults, automation: .init(evaluate: script.evaluate), applications: { [] }, open: { opened.append($0); script.reopened() })
        try await recovered.restoreCompleted([op])
        #expect(opened.count == 1)
        let restarted = XcodeBranchWorkspaces(defaults: defaults, applications: { [] }, open: { _ in Issue.record("Lease was replayed") })
        try await restarted.restoreCompleted([op])
    }

    @Test(arguments: [-1743, -10004])
    func deniedAutomationIsReportedBeforeCheckoutChanges(number: Int) async throws {
        let suite = "XcodeBranchAccess-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let automation = XcodeBranchWorkspaceAutomation { _ in throw XcodeRunAutomation.ScriptError(number: number, message: "fixture denied") }
        let service = XcodeBranchWorkspaces(defaults: defaults, automation: automation,
            applications: { ["/fixture/Xcode.app"] }, open: { _ in Issue.record("Unprepared workspace opened") })
        await #expect(throws: BranchSwitchError.xcodeAccess) { try await service.prepare(self.operation()) }
    }

    @Test func rejectsAWorkspaceOutsideTheCheckout() async throws {
        let suite = "XcodeBranchScope-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let automation = XcodeBranchWorkspaceAutomation { _ in .text("/fixture/repo-other/App.xcworkspace") }
        let service = XcodeBranchWorkspaces(defaults: defaults, automation: automation,
            applications: { ["/fixture/Xcode.app"] }, open: { _ in Issue.record("Foreign workspace was reopened") })
        await #expect(throws: BranchSwitchError.xcodeClose) { try await service.prepare(self.operation()) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_XCODE_SCRIPT_DICTIONARIES"] != nil))
    func scriptsCompileAgainstXcodeWithoutExecutingOrDiscardingEdits() async throws {
        let paths = try JSONDecoder().decode([String].self, from: Data(try #require(ProcessInfo.processInfo.environment["MIMIC_XCODE_SCRIPT_DICTIONARIES"]).utf8))
        for path in paths {
            let automation = XcodeBranchWorkspaceAutomation { source in
                let script = try #require(NSAppleScript(source: source))
                var error: NSDictionary?
                let compiled = script.compileAndReturnError(&error)
                #expect(compiled, "Invalid Xcode script: \(error?.description ?? "")")
                #expect(!source.contains("saving no") && !source.contains("quit"))
                return source.contains("close selectedWorkspace") ? .flag(true) : .text("")
            }
            _ = try await automation.paths(application: path, checkout: "/fixture/repo")
            try await automation.close(.init(application: path, path: "/fixture/repo/App.xcworkspace"))
        }
    }
}
