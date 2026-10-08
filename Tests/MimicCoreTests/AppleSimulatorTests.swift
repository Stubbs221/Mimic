//
//  AppleSimulatorTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation
import Testing
@testable import MimicCore

private actor AppleSimulatorRPCFixture {
    struct Request: Sendable { let name: String; let arguments: [String: BridgeValue] }
    var calls: [Request] = []
    let deviceID: UUID
    var physical = false
    var failure = false
    var delayed = false
    var continuation: CheckedContinuation<Void, Never>?
    init(deviceID: UUID) { self.deviceID = deviceID }
    func setPhysical() { self.physical = true }
    func setFailure() { self.failure = true }
    func delay() { self.delayed = true }
    func complete() { self.continuation?.resume(); self.continuation = nil }
    func call(_ name: String, _ arguments: [String: BridgeValue]) async throws -> BridgeValue {
        self.calls.append(.init(name: name, arguments: arguments))
        if self.failure { throw AppleSimulatorError.connectionLost }
        if name.hasPrefix("DeviceInteractionStart") {
            return .object(["deviceUUID": .string(self.deviceID.uuidString), "deviceIsSimulator": .bool(!self.physical), "interactionSessionKey": .string("fixture-private-key")])
        }
        if name == "DeviceInteractionSynthesize" {
            if self.delayed { await withCheckedContinuation { self.continuation = $0 } }
            return .object(["applicationState": .string("Running"), "screenshotPath": .string("/private/tmp/fixture-screen.png"), "hierarchyPath": .string("/private/tmp/fixture-hierarchy.txt"), "logsPath": .string("/private/tmp/forbidden-console.txt")])
        }
        return .object(["userMessage": .string("Completed")])
    }
}

struct AppleSimulatorTests {
    @Test func selectedXcode265KeepsSimulatorDisabledEvenWithAnotherXcodeInstalled() {
        for nativeToolsAvailable in [false, true] {
            let capability = AppleSimulatorAvailability.evaluate(selectedXcodeVersion: "26.5", macOSMajor: 27, macOSMinor: 0, nativeToolsAvailable: nativeToolsAvailable)
            #expect(capability == .requiresXcode27)
            #expect(!capability.deviceControlsEnabled)
        }
    }
    @Test func selectedXcode27RequiresSupportedOSAndValidatedNativeAccess() {
        #expect(AppleSimulatorAvailability.evaluate(selectedXcodeVersion: "27", macOSMajor: 26, macOSMinor: 5, nativeToolsAvailable: true) == .requiresSupportedMacOS)
        #expect(AppleSimulatorAvailability.evaluate(selectedXcodeVersion: "27", macOSMajor: 26, macOSMinor: 6, nativeToolsAvailable: false) == .requiresNativeAccess)
        #expect(AppleSimulatorAvailability.evaluate(selectedXcodeVersion: "27", macOSMajor: 26, macOSMinor: 6, nativeToolsAvailable: true).deviceControlsEnabled)
        #expect(AppleSimulatorAvailability.evaluate(selectedXcodeVersion: "27.1", macOSMajor: 27, macOSMinor: 0, nativeToolsAvailable: true).deviceControlsEnabled)
        #expect(!AppleSimulatorAvailability.evaluate(selectedXcodeVersion: "", macOSMajor: 27, macOSMinor: 0, nativeToolsAvailable: true).deviceControlsEnabled)
    }

    @Test func commandsRejectMalformedCoordinatesAndDuration() throws {
        #expect(try AppleSimulatorAction.tap(x: 12.5, y: 34).command() == "t 12.5000 34.0000")
        #expect(try AppleSimulatorAction.swipe(x: 1, y: 2, endX: 3, endY: 4, duration: 0.3).command() == "t 1.0000 2.0000 f 3.0000 4.0000 0.3000")
        for value in [Double.nan, Double.infinity, -1, 20_001] {
            #expect(throws: AppleSimulatorError.self) { try AppleSimulatorAction.tap(x: value, y: 0).command() }
        }
        for duration in [Double.nan, 0, -1, 2.1] {
            #expect(throws: AppleSimulatorError.self) { try AppleSimulatorAction.swipe(x: 0, y: 0, endX: 1, endY: 1, duration: duration).command() }
        }
    }
    @Test func specialKeysUseVerifiedCommandsAndUnsupportedDeleteIsRejected() throws {
        #expect(try AppleSimulatorAction.key(.backspace).command() == "sender keyboard kbd \\u{0008}")
        #expect(try AppleSimulatorAction.key(.return).command() == "sender keyboard kbd \\u{000A}")
        #expect(throws: AppleSimulatorError.unsupported) { try AppleSimulatorAction.key(.forwardDelete).command() }
        #expect(try SimulatorBridge.action(.object(["type": .string("key"), "key": .string("backspace")])) == .key(.backspace))
        #expect(throws: AppleSimulatorError.arguments) { try SimulatorBridge.action(.object(["type": .string("key"), "key": .string("arbitrary DSL")])) }
    }
    @Test func unicodeSpacesAndLiteralEscapesCannotBecomeCommands() throws {
        let value = "Привет  🧪\n\\u{000A} b h"
        let command = try AppleSimulatorAction.text(value).command()
        let prefix = "sender keyboard kbd "
        #expect(command.hasPrefix(prefix))
        let scalars = command.dropFirst(prefix.count).split(separator: "}").compactMap { UInt32($0.dropFirst(3), radix: 16) }.compactMap(Unicode.Scalar.init)
        #expect(String(String.UnicodeScalarView(scalars)) == value)
        #expect(!command.contains(" b h"))
        #expect(throws: AppleSimulatorError.self) { try AppleSimulatorAction.text("").command() }
        #expect(throws: AppleSimulatorError.self) { try AppleSimulatorAction.text("\0").command() }
        #expect(throws: AppleSimulatorError.self) { try AppleSimulatorAction.text(String(repeating: "я", count: 4097)).command() }
        #expect(try AppleSimulatorAction.home.command() == "b h")
        #expect(try AppleSimulatorAction.orientation(.landscapeLeft).command() == "orientation landscapeLeft")
    }
    @Test func capturedNativeSchemasAreAcceptedWithoutExtendingBuild265() throws {
        let path = try #require(Bundle.module.url(forResource: "Xcode27DeviceTools", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(BridgeValue.self, from: Data(contentsOf: path))
        #expect(fixture["tools"].array?.count == 5)
        for tool in fixture["tools"].array ?? [] {
            let name = try #require(tool["name"].string)
            #expect(AppleSimulatorProfile.accepts(name: name, input: tool["inputSchema"], output: tool["outputSchema"]))
            #expect(!XcodeBuildProfile.accepts(name: name, input: tool["inputSchema"], output: tool["outputSchema"]))
            var input = try #require(tool["inputSchema"].object)
            input["required"] = .array((input["required"]?.array ?? []) + [.string("unexpectedRequiredField")])
            #expect(!AppleSimulatorProfile.accepts(name: name, input: .object(input), output: tool["outputSchema"]))
            input = try #require(tool["inputSchema"].object)
            input["required"] = .array((input["required"]?.array ?? []) + [.number(1)])
            #expect(!AppleSimulatorProfile.accepts(name: name, input: .object(input), output: tool["outputSchema"]))
            var output = try #require(tool["outputSchema"].object)
            output["required"] = .array([])
            #expect(!AppleSimulatorProfile.accepts(name: name, input: tool["inputSchema"], output: .object(output)))
        }
    }
    @Test func workspaceAuthorizationRequiresExactSupportedShape() {
        let input: BridgeValue = .object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])]), "required": .array([.string("path")])])
        let output: BridgeValue = .object(["type": .string("object"), "properties": .object(["workspaceIdentifier": .object(["type": .string("string")])]), "required": .array([.string("workspaceIdentifier")])])
        #expect(AppleSimulatorProfile.acceptsWorkspaceAccess(input: input, output: output))
        var changed = input.object!
        changed["required"] = .array([.string("path"), .string("grantAllAgents")])
        #expect(!AppleSimulatorProfile.acceptsWorkspaceAccess(input: .object(changed), output: output))
        changed = output.object!
        changed["required"] = .array([])
        #expect(!AppleSimulatorProfile.acceptsWorkspaceAccess(input: input, output: .object(changed)))
        changed["required"] = .array([.string("workspaceIdentifier")])
        changed["properties"] = .object(["workspaceIdentifier": .object(["type": .string("integer")])])
        #expect(!AppleSimulatorProfile.acceptsWorkspaceAccess(input: input, output: .object(changed)))
    }

    @Test func exactDeviceAndPrivateSessionKeyAreKeptSeparate() async throws {
        let device = UUID(), rpc = AppleSimulatorRPCFixture(deviceID: device)
        let session = AppleSimulatorSession { try await rpc.call($0, $1) }
        let descriptor = try await session.start(deviceID: device)
        #expect(descriptor.deviceID == device)
        #expect(descriptor.id != device)
        let first = try await session.capture(sessionID: descriptor.id)
        #expect(first.revision == 1)
        let second = try await session.perform(sessionID: descriptor.id, action: .home, observedRevision: first.revision)
        #expect(second.revision == 2)
        let calls = await rpc.calls
        #expect(calls[0].arguments["deviceIdentifier"] == .string(device.uuidString))
        #expect(calls[1].arguments["interactSessionKey"] == .string("fixture-private-key"))
        #expect(calls[1].arguments["interactionCommand"] == nil)
        #expect(calls[2].arguments["interactionCommand"] == .string("b h"))
        #expect(!String(describing: descriptor).contains("fixture-private-key"))
        #expect(!String(describing: second).contains("forbidden-console"))
    }
    @Test func physicalAndUnexpectedDevicesAreClosedBeforeInteraction() async throws {
        for physical in [true, false] {
            let returned = UUID(), rpc = AppleSimulatorRPCFixture(deviceID: returned)
            if physical { await rpc.setPhysical() }
            let session = AppleSimulatorSession { try await rpc.call($0, $1) }
            await #expect(throws: AppleSimulatorError.wrongDevice) { try await session.start(deviceID: physical ? returned : UUID()) }
            #expect(await rpc.calls.map(\.name) == ["DeviceInteractionStartSession", "DeviceInteractionEndSession"])
            #expect(await session.descriptor == nil)
        }
    }
    @Test func staleImageAndUnobservedActionsNeverReachApple() async throws {
        let device = UUID(), rpc = AppleSimulatorRPCFixture(deviceID: device)
        let session = AppleSimulatorSession { try await rpc.call($0, $1) }
        let descriptor = try await session.start(deviceID: device)
        await #expect(throws: AppleSimulatorError.arguments) { try await session.perform(sessionID: descriptor.id, action: .home, observedRevision: 0) }
        let image = try await session.capture(sessionID: descriptor.id)
        _ = try await session.perform(sessionID: descriptor.id, action: .home, observedRevision: image.revision)
        await #expect(throws: AppleSimulatorError.arguments) { try await session.perform(sessionID: descriptor.id, action: .home, observedRevision: image.revision) }
        #expect(await rpc.calls.count == 3)
    }
    @Test func lostConnectionCannotReplayAnActionOrInstall() async throws {
        let device = UUID(), rpc = AppleSimulatorRPCFixture(deviceID: device)
        let session = AppleSimulatorSession { try await rpc.call($0, $1) }
        let descriptor = try await session.start(deviceID: device)
        let image = try await session.capture(sessionID: descriptor.id)
        await rpc.setFailure()
        await #expect(throws: AppleSimulatorError.connectionLost) { try await session.perform(sessionID: descriptor.id, action: .home, observedRevision: image.revision) }
        let count = await rpc.calls.count
        await #expect(throws: AppleSimulatorError.connectionLost) { try await session.perform(sessionID: descriptor.id, action: .home, observedRevision: image.revision) }
        await #expect(throws: AppleSimulatorError.connectionLost) { try await session.installAndRun(sessionID: descriptor.id) }
        #expect(await rpc.calls.count == count)
    }
    @Test func closeEndsSessionWithoutShuttingDownAndWorkspaceIsBound() async throws {
        let device = UUID(), rpc = AppleSimulatorRPCFixture(deviceID: device)
        let session = AppleSimulatorSession { try await rpc.call($0, $1) }
        let workspace = URL(fileURLWithPath: "/private/tmp/Fixture.xcworkspace")
        let descriptor = try await session.start(deviceID: device, workspace: workspace)
        try await session.installAndRun(sessionID: descriptor.id)
        try await session.close(sessionID: descriptor.id)
        let calls = await rpc.calls
        #expect(calls.map(\.name) == ["DeviceInteractionStartWorkspaceSession", "DeviceInteractionInstallAndRun", "DeviceInteractionEndSession"])
        #expect(calls[0].arguments["workspaceIdentifier"] == .string(workspace.path))
        #expect(calls[1].arguments["workspaceIdentifier"] == .string(workspace.path))
        #expect(await session.descriptor == nil)
        await #expect(throws: AppleSimulatorError.noSession) { try await session.capture(sessionID: descriptor.id) }
    }
    @Test func workspaceAliasStaysBoundAcrossStartAndInstall() async throws {
        let device = UUID(), rpc = AppleSimulatorRPCFixture(deviceID: device)
        let session = AppleSimulatorSession { try await rpc.call($0, $1) }
        let workspace = URL(fileURLWithPath: "/private/tmp/fixture.xcodeproj")
        let descriptor = try await session.start(deviceID: device, workspace: workspace, workspaceIdentifier: "workspace1")
        try await session.installAndRun(sessionID: descriptor.id)
        let calls = await rpc.calls
        #expect(calls[0].arguments["workspaceIdentifier"] == .string("workspace1"))
        #expect(calls[1].arguments["workspaceIdentifier"] == .string("workspace1"))
        #expect(descriptor.workspace == workspace)
        try await session.close(sessionID: descriptor.id)
        let standalone = AppleSimulatorSession { try await rpc.call($0, $1) }
        await #expect(throws: AppleSimulatorError.arguments) { try await standalone.start(deviceID: device, workspaceIdentifier: "workspace1") }
    }

    @Test func nativeSessionLabelsRemainUniqueAcrossCloseAndReopen() async throws {
        let device = UUID(), rpc = AppleSimulatorRPCFixture(deviceID: device)
        let session = AppleSimulatorSession { try await rpc.call($0, $1) }
        let first = try await session.start(deviceID: device)
        try await session.close(sessionID: first.id)
        let second = try await session.start(deviceID: device)
        let labels = await rpc.calls.filter { $0.name.hasPrefix("DeviceInteractionStart") }.compactMap { $0.arguments["sessionIdentifier"]?.string }
        #expect(labels == ["Mimic Simulator " + first.id.uuidString, "Mimic Simulator " + second.id.uuidString])
        #expect(first.id != second.id)
        try await session.close(sessionID: second.id)
    }

    @Test func workspaceLessSessionsCannotBuildOrInstall() async throws {
        let device = UUID(), rpc = AppleSimulatorRPCFixture(deviceID: device)
        let session = AppleSimulatorSession { try await rpc.call($0, $1) }
        let descriptor = try await session.start(deviceID: device)
        await #expect(throws: AppleSimulatorError.arguments) { try await session.installAndRun(sessionID: descriptor.id) }
        #expect(await rpc.calls.count == 1)
    }
    @Test func concurrentObserversAndCloseCannotInterleave() async throws {
        let device = UUID(), rpc = AppleSimulatorRPCFixture(deviceID: device)
        let session = AppleSimulatorSession { try await rpc.call($0, $1) }
        let descriptor = try await session.start(deviceID: device)
        await rpc.delay()
        let pending = Task { try await session.capture(sessionID: descriptor.id) }
        for _ in 0..<200 {
            if await rpc.continuation != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await #expect(throws: AppleSimulatorError.occupied) { try await session.capture(sessionID: descriptor.id) }
        await #expect(throws: AppleSimulatorError.occupied) { try await session.close(sessionID: descriptor.id) }
        await rpc.complete()
        _ = try await pending.value
        #expect(await rpc.calls.count == 2)
    }
}
