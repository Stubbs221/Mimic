//
//  XcodeRunTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 22.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct XcodeRunTests {
    @Test func debuggerEvidenceRequiresSuccessfulLaunchAndTheSamePID() throws {
        let launch: BridgeValue = .object(["runResult": .string("The app was launched successfully."), "buildErrors": .array([]), "processIdentifier": .number(123)])
        #expect(try XcodeRunVerification.launchedProcess(launch, isError: false) == 123)
        #expect(throws: BuildError.debuggerUnavailable) { try XcodeRunVerification.launchedProcess(launch, isError: true) }
        let attached: BridgeValue = .object(["debugSessionActive": .bool(true), "processIdentifier": .number(123), "isWaitingForMore": .bool(true)])
        #expect(XcodeRunVerification.debuggerMatches(attached, process: 123, isError: false))
        #expect(!XcodeRunVerification.debuggerMatches(attached, process: 124, isError: false))
        #expect(!XcodeRunVerification.debuggerMatches(attached, process: 123, isError: true))
        #expect(!XcodeRunVerification.debuggerMatches(.object(["output": .string("Process 123 is running.")]), process: 123, isError: false))
    }
    @Test func capturedXcode265And27SchemasPreserveExplicitWorkspaceScoping() throws {
        for file in ["Xcode26_5Tools", "Xcode27BuildTools"] {
            let url = try #require(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Fixtures"))
            let value = try JSONDecoder().decode(BridgeValue.self, from: Data(contentsOf: url))
            for tool in value["tools"].array ?? [] {
                guard let name = tool["name"].string, ["XcodeListWindows", "BuildProject", "RunSomeTests", "RunProject", "InvokeDebuggerCommand", "StopProject", "XcodeListRunDestinations"].contains(name) else { continue }
                #expect(XcodeBuildProfile.accepts(name: name, input: tool["inputSchema"], output: tool["outputSchema"]), "Rejected captured \(file) \(name)")
                if name == "RunProject", var input = tool["inputSchema"].object {
                    input["required"] = .array([.string("unknownRequiredParameter")])
                    #expect(!XcodeBuildProfile.accepts(name: name, input: .object(input), output: tool["outputSchema"]))
                }
            }
        }
    }
    @Test func pickerStateMustNameTheUUIDSelectedSimulatorExactlyOnce() {
        func entry(_ title: String, active: Bool = false, simulator: Bool = true, platform: String = "com.apple.platform.iphonesimulator") -> BridgeValue {
            .object(["displayTitle": .string(title), "isActive": .bool(active), "isSimulator": .bool(simulator), "isGenericDevice": .bool(false), "platformIdentifier": .string(platform)])
        }
        func list(_ entries: [BridgeValue], scheme: String = "ivi.ru", active: String = "QA iPhone") -> BridgeValue {
            .object(["activeSchemeName": .string(scheme), "activeDestinationDisplayTitle": .string(active), "destinations": .array(entries)])
        }
        let selected = list([entry("QA iPhone", active: true), entry("UI iPhone")])
        #expect(XcodeRunVerification.destinationMatches(selected, scheme: "ivi.ru", title: "QA iPhone", isError: false))
        #expect(!XcodeRunVerification.destinationMatches(selected, scheme: "ivi.ru", title: "QA iPhone", isError: true))
        #expect(!XcodeRunVerification.destinationMatches(selected, scheme: "Other", title: "QA iPhone", isError: false))
        #expect(!XcodeRunVerification.destinationMatches(list([entry("QA iPhone"), entry("UI iPhone", active: true)], active: "UI iPhone"), scheme: "ivi.ru", title: "QA iPhone", isError: false))
        #expect(!XcodeRunVerification.destinationMatches(list([entry("QA iPhone", active: true), entry("QA iPhone")]), scheme: "ivi.ru", title: "QA iPhone", isError: false))
        #expect(!XcodeRunVerification.destinationMatches(list([entry("QA iPhone", active: true, simulator: false, platform: "com.apple.platform.iphoneos")]), scheme: "ivi.ru", title: "QA iPhone", isError: false))
    }
    @Test func buildIssuesKeepXcodeLocationsAndMessages() {
        let entries: [BridgeValue] = [
            .object(["classification": .string("error"), "message": .string("Module file 'Foundation.pcm' not found"), "filePath": .string("/ios3/resource_bundle_accessor.h"), "lineNumber": .number(3)]),
            .object(["classification": .string("warning"), "message": .string("Deprecated")]),
        ]
        #expect(XcodeRunVerification.issues(entries) == "/ios3/resource_bundle_accessor.h:3: error: Module file 'Foundation.pcm' not found\nwarning: Deprecated")
        #expect(XcodeRunVerification.issues(nil).isEmpty)
    }
    @Test func launchedProcessMustLiveInTheExactSimulatorContainer() {
        let device = "56631DFB-BA54-40C2-BF6C-CC7B4F0A31E5"
        let path = "/Users/fixture/Library/Developer/CoreSimulator/Devices/\(device)/data/Containers/Bundle/Application/0B5D/ivi.app/ivi"
        #expect(XcodeRunVerification.processBelongsToSimulator(executablePath: path, deviceID: device))
        #expect(XcodeRunVerification.processBelongsToSimulator(executablePath: path, deviceID: device.lowercased()))
        #expect(!XcodeRunVerification.processBelongsToSimulator(executablePath: path.replacingOccurrences(of: device, with: "EC009D1B-10EF-4BF0-8789-988231F3FEB6"), deviceID: device))
        #expect(!XcodeRunVerification.processBelongsToSimulator(executablePath: "/Applications/ivi.app/ivi", deviceID: device))
        #expect(!XcodeRunVerification.processBelongsToSimulator(executablePath: path, deviceID: "QA iPhone"))
    }
    @Test func nativeRunRetainsExactSchemeAndSimulatorButDoesNotPermitOtherMCPIntents() throws {
        var value = BuildParameters(backend: .xcodeMCP, scheme: "App", destinationID: UUID().uuidString)
        value.intent = .run; try value.validate()
        value.intent = .cleanup
        #expect(throws: BuildError.arguments) { try value.validate() }
        value.intent = .run; value.destinationID = "simulator name"
        #expect(throws: BuildError.arguments) { try value.validate() }
    }
    @Test func nativeFractionMovesDuringCompilationWithoutATimerEstimate() {
        let project = ProjectContext(path: "/fixture", branch: "main", commit: "one")
        var parameters = BuildParameters(backend: .xcodeMCP, scheme: "App", destinationID: UUID().uuidString); parameters.intent = .run
        var activity = BuildActivity(project: project, parameters: parameters, source: "fixture")
        activity.status = .running; activity.stage = .compilation
        #expect(activity.progressFraction == nil)
        activity.executionProgress = .init(fraction: 0.3)
        #expect(activity.progressFraction == 0.3)
        activity.executionProgress = .init(fraction: 0.9)
        #expect(activity.progressFraction == 0.9)
        activity.executionProgress = .init(fraction: 1)
        #expect(activity.progressFraction == 0.99)
        activity.executionProgress = .init(fraction: .nan)
        #expect(activity.progressFraction == nil)
        activity.stage = .launch; activity.completedStages = 2
        #expect(activity.progressFraction == 2.0 / 3.0)
        activity.status = .succeeded
        #expect(activity.progressFraction == 1)
    }
    @Test func cacheSurvivesSourceAndDeviceChangesButSeparatesCompilerInputs() throws {
        let root = URL(fileURLWithPath: "/fixture/History")
        let first = ProjectContext(path: "/fixture/Checkout", branch: "main", commit: "one", appleTarget: .init(path: "App.xcodeproj"))
        let changed = ProjectContext(path: first.path, branch: "feature/profile", commit: "two", appleTarget: first.appleTarget)
        var parameters = BuildParameters(scheme: "App", destinationID: UUID().uuidString)
        func path(_ project: ProjectContext, _ parameters: BuildParameters, developer: String = "/fixture/Xcode27/Developer") throws -> URL {
            try BuildCompilationCache.directory(root: root, project: project, developer: developer, parameters: parameters, profileRevision: "profile")
        }
        let original = try path(first, parameters)
        parameters.destinationID = UUID().uuidString
        #expect(try path(changed, parameters) == original)
        #expect(try path(first, parameters, developer: "/fixture/Xcode265/Developer") != original)
        parameters.configuration = "Release"
        #expect(try path(first, parameters) != original)
        #expect(original.path.hasPrefix(root.path + "/CompilationCache/"))
        parameters.operation = .test
        #expect(throws: BuildError.arguments) { try path(first, parameters) }
    }
}
