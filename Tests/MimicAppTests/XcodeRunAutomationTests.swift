//
//  XcodeRunAutomationTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 22.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

struct XcodeRunAutomationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_XCODE_SCRIPT_DICTIONARIES"] != nil))
    func generatedScriptsCompileAgainstSelectedXcodeDictionariesWithoutExecuting() async throws {
        let paths = try JSONDecoder().decode([String].self, from: Data(try #require(ProcessInfo.processInfo.environment["MIMIC_XCODE_SCRIPT_DICTIONARIES"]).utf8))
        for path in paths {
            let target = XcodeRunAutomation.Target(application: path, workspace: "/fixture/App.xcworkspace", scheme: "Profile \"QA\"", destinationID: self.target.destinationID)
            let automation = XcodeRunAutomation { source in
                let script = try #require(NSAppleScript(source: source))
                var error: NSDictionary?
                let compiled = script.compileAndReturnError(&error)
                #expect(compiled, "Dictionary compilation failed: \(error?.description ?? "")")
                if source.contains("return completed of previousAction") { return .flag(true) }
                if source.contains("return status of actionResult") { return .text("running") }
                if source.contains("return id of actionResult") { return .text("owned-action") }
                if source.contains("return selectedName") { return .text("QA iPhone") }
                return .empty
            }
            _ = try await automation.select(target)
            try await automation.requireIdle(target)
            _ = try await automation.debugWithoutBuilding(target)
            _ = try await automation.debugStatus(target, actionID: "owned-action")
            try await automation.stopOwnedDebug(target, actionID: "owned-action")
        }
    }
    private var target: XcodeRunAutomation.Target {
        .init(application: "/fixture/Xcode 26.5.app", workspace: "/fixture/App.xcworkspace", scheme: "Profile \"QA\"", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    }
    @Test func selectionUsesExactApplicationWorkspaceSchemeAndDevice() async throws {
        let automation = XcodeRunAutomation { script in
            #expect(script.contains("tell application \"/fixture/Xcode 26.5.app\""))
            #expect(script.contains("/fixture/App.xcworkspace"))
            #expect(script.contains("Profile \\\"QA\\\""))
            #expect(script.contains("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
            #expect(script.contains("\"iphonesimulator\""))
            #expect(!script.contains("do shell script"))
            return .text("QA iPhone")
        }
        #expect(try await automation.select(target) == "QA iPhone")
    }
    /// Live Xcode 27 rejects `POSIX path of (file of …)` with -1700, returns package paths with a trailing slash,
    /// and answers ~0.15 s per Apple Event, so 80 destinations queried property by property exceed the 15 s timeout.
    @Test func workspaceAndDestinationQueriesUseResolvedFilesAndBulkLists() async throws {
        let automation = XcodeRunAutomation { script in
            #expect(script.contains("set candidateFile to file of candidate"))
            #expect(script.contains("set candidatePath to POSIX path of candidateFile"))
            #expect(script.contains("if candidatePath ends with \"/\" then"))
            #expect(!script.contains("POSIX path of (file of candidate)"))
            #expect(script.contains("platform of every run destination"))
            #expect(script.contains("device identifier of device of every run destination"))
            #expect(!script.contains("repeat with candidate in run destinations"))
            #expect(!script.contains("of active run destination"))
            #expect(script.components(separatedBy: "device identifier of device of run destination selectedIndex").count == 3)
            return .text("QA iPhone")
        }
        _ = try await automation.select(target)
        let verify = XcodeRunAutomation { script in
            #expect(!script.contains("of active run destination"))
            #expect(script.contains("name of active scheme is not \"Profile \\\"QA\\\"\""))
            #expect(script.contains("if matchingCount is not 1"))
            return .empty
        }
        try await verify.verify(target)
    }
    /// Live NSAppleScript returns `return true` as a 'true' descriptor; treating it as text made every idle Xcode look busy.
    @Test func literalBooleanRepliesAreFlagsNotText() throws {
        for (source, expected) in [("return true", XcodeRunAutomation.Response.flag(true)), ("return false", .flag(false)), ("return \"QA iPhone\"", .text("QA iPhone"))] {
            var error: NSDictionary?
            let reply = try #require(NSAppleScript(source: source)).executeAndReturnError(&error)
            #expect(error == nil)
            #expect(XcodeRunAutomation.response(reply) == expected)
        }
    }
    /// Xcode 26.5 rejects MCP clients until the workspace window exists; only the identity check means "not yet".
    @Test func workspaceReadinessWaitsOnlyForMissingOrLoadingWorkspace() async throws {
        let missing = XcodeRunAutomation { _ in throw XcodeRunAutomation.ScriptError(number: -2700, message: "Workspace identity changed") }
        #expect(try await missing.workspaceNotReady(target) == "AppleScript -2700: Workspace identity changed")
        let ready = XcodeRunAutomation { script in
            #expect(script.contains("return true") && script.contains("/fixture/App.xcworkspace"))
            return .flag(true)
        }
        #expect(try await ready.workspaceNotReady(target) == nil)
        let denied = XcodeRunAutomation { _ in throw XcodeRunAutomation.ScriptError(number: -1743, message: "Not authorized") }
        await #expect(throws: XcodeRunFailure.self) { _ = try await denied.workspaceNotReady(target) }
    }
    @Test func scriptFailuresKeepTheStepAndXcodeError() async throws {
        let rejected = XcodeRunAutomation { _ in throw XcodeRunAutomation.ScriptError(number: -1700, message: "Can’t make POSIX path of file into type specifier.") }
        do { try await rejected.requireIdle(target); Issue.record("Script failure was ignored") }
        catch let failure as XcodeRunFailure {
            #expect(failure.step == "automation.requireIdle")
            #expect(failure.code == .configuration)
            #expect(failure.summary.contains("AppleScript -1700: Can’t make POSIX path"))
        }
        let denied = XcodeRunAutomation { _ in throw XcodeRunAutomation.ScriptError(number: -1743, message: "Not authorized") }
        do { _ = try await denied.select(target); Issue.record("Denied automation was ignored") }
        catch let failure as XcodeRunFailure { #expect(failure.code == .xcodeAccess && failure.step == "automation.select") }
        let unnamed = XcodeRunAutomation { _ in .empty }
        await #expect(throws: XcodeRunFailure.self) { _ = try await unnamed.select(target) }
    }
    @Test func debugRunsWithoutAnotherBuildAndPinsTheReturnedAction() async throws {
        let automation = XcodeRunAutomation { script in
            if script.contains("set actionResult to debug") {
                #expect(script.contains("skip building true"))
                #expect(script.contains("run destination specifier \"platform=iOS Simulator,id="))
                return .text("owned-action")
            }
            return .empty
        }
        #expect(try await automation.debugWithoutBuilding(target) == "owned-action")
        let status = XcodeRunAutomation { script in
            #expect(script.contains("if id of actionResult is not \"owned-action\""))
            return .text("running")
        }
        #expect(try await status.debugStatus(target, actionID: "owned-action") == "running")
    }
    @Test func busyWorkspaceAndControlCharacterInjectionFailBeforeLaunch() async throws {
        let busy = XcodeRunAutomation { _ in .flag(false) }
        await #expect(throws: XcodeRunFailure(step: "automation.requireIdle", code: .xcodeBusy, detail: "Xcode reports an unfinished scheme action")) { try await busy.requireIdle(target) }
        let invalid = XcodeRunAutomation.Target(application: target.application, workspace: target.workspace, scheme: "App\nrun", destinationID: target.destinationID)
        let isolated = XcodeRunAutomation { _ in Issue.record("Invalid argument reached Apple Events"); return .empty }
        await #expect(throws: BuildError.arguments) { try await isolated.select(invalid) }
    }
}
