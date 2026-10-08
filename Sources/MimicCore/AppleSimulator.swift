//
//  AppleSimulator.swift
//  MimicCore
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation

/// Failures of the constrained Apple device-interaction adapter. No raw server response is exposed.
public enum AppleSimulatorError: Error, Sendable, Equatable {
    case arguments, unsupported, occupied, noSession, wrongDevice, invalidResponse, connectionLost
}

/// Capability of the selected Xcode only; other installed Xcodes never enable device controls.
public enum AppleSimulatorAvailability: String, Sendable, Equatable {
    case requiresXcode27, requiresSupportedMacOS, requiresNativeAccess, available
    public var deviceControlsEnabled: Bool { self == .available }

    /// Xcode 26.5 retains all existing Mimic features while this capability remains disabled.
    public static func evaluate(selectedXcodeVersion: String, macOSMajor: Int, macOSMinor: Int, nativeToolsAvailable: Bool) -> Self {
        guard let major = Int(selectedXcodeVersion.split(separator: ".").first ?? ""), major >= 27 else { return .requiresXcode27 }
        guard macOSMajor > 26 || macOSMajor == 26 && macOSMinor >= 6 else { return .requiresSupportedMacOS }
        return nativeToolsAvailable ? .available : .requiresNativeAccess
    }
}

/// Explicit user actions translated to Apple's DSL; callers cannot supply arbitrary commands.
public enum AppleSimulatorAction: Sendable, Equatable {
    case tap(x: Double, y: Double)
    case swipe(x: Double, y: Double, endX: Double, endY: Double, duration: Double)
    case text(String)
    case home
    case key(Key)
    public enum Key: String, Sendable { case backspace, forwardDelete, `return` }
    case orientation(Orientation)
    public enum Orientation: String, Sendable { case portrait, landscapeLeft, landscapeRight, portraitUpsideDown }

    /// Coordinates are display-relative points, not screenshot pixels. The UI must establish that mapping first.
    public func command() throws -> String {
        func number(_ value: Double, range: ClosedRange<Double>) throws -> String {
            guard value.isFinite, range.contains(value) else { throw AppleSimulatorError.arguments }
            return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        func point(_ value: Double) throws -> String { try number(value, range: 0...20_000) }
        switch self {
        case let .tap(x, y): return try "t \(point(x)) \(point(y))"
        case let .swipe(x, y, endX, endY, duration):
            return try "t \(point(x)) \(point(y)) f \(point(endX)) \(point(endY)) \(number(duration, range: 0.05...2))"
        case let .text(value):
            guard !value.isEmpty, value.utf8.count <= 8192, !value.unicodeScalars.contains(where: { $0.value == 0 }) else { throw AppleSimulatorError.arguments }
            // Escape every scalar, including backslashes. A user's literal Unicode escape stays literal.
            return "sender keyboard kbd " + value.unicodeScalars.map { "\\u{" + String($0.value, radix: 16, uppercase: true) + "}" }.joined()
        case .home: return "b h"
        case .key(.backspace): return "sender keyboard kbd \\u{0008}"
        case .key(.return): return "sender keyboard kbd \\u{000A}"
        case .key(.forwardDelete): throw AppleSimulatorError.unsupported
        case let .orientation(value): return "orientation " + value.rawValue
        }
    }
}

/// The tested Xcode 27 device-tool shapes. This does not extend the Xcode 26.5 build adapter.
public enum AppleSimulatorProfile {
    public static let tools = ["DeviceInteractionStartSession", "DeviceInteractionStartWorkspaceSession", "DeviceInteractionInstallAndRun", "DeviceInteractionSynthesize", "DeviceInteractionEndSession"]
    /// Opening a workspace is the headless authorization handshake, not a generic project-management tool.
    public static func acceptsWorkspaceAccess(input: BridgeValue, output: BridgeValue) -> Bool {
        input["type"].string == "object" && input["properties"]["path"]["type"].string == "string" && input["required"] == .array([.string("path")]) && output["type"].string == "object" && output["properties"]["workspaceIdentifier"]["type"].string == "string" && output["required"] == .array([.string("workspaceIdentifier")])
    }
    public static func accepts(name: String, input: BridgeValue, output: BridgeValue) -> Bool {
        guard input["type"].string == "object", output["type"].string == "object", let inputRequired = input["required"].array, let outputRequiredValues = output["required"].array else { return false }
        let required = inputRequired.compactMap(\.string), outputRequired = outputRequiredValues.compactMap(\.string)
        guard required.count == inputRequired.count, outputRequired.count == outputRequiredValues.count else { return false }
        let fields: [String: String]
        let expected: Set<String>
        let results: [String: String]
        switch name {
        case "DeviceInteractionStartSession", "DeviceInteractionStartWorkspaceSession":
            fields = name == "DeviceInteractionStartSession" ? ["deviceIdentifier": "string", "sessionIdentifier": "string"] : ["deviceIdentifier": "string", "sessionIdentifier": "string", "workspaceIdentifier": "string"]
            expected = name == "DeviceInteractionStartSession" ? ["deviceIdentifier", "sessionIdentifier"] : ["sessionIdentifier"]
            results = ["deviceUUID": "string", "deviceIsSimulator": "boolean", "interactionSessionKey": "string"]
        case "DeviceInteractionSynthesize":
            fields = ["interactSessionKey": "string", "interactionCommand": "string"]
            expected = ["interactSessionKey"]
            results = ["applicationState": "string", "screenshotPath": "string", "hierarchyPath": "string"]
        case "DeviceInteractionInstallAndRun":
            fields = ["interactionSessionKey": "string", "workspaceIdentifier": "string"]
            expected = ["interactionSessionKey"]
            results = ["userMessage": "string"]
        case "DeviceInteractionEndSession":
            fields = ["interactionSessionKey": "string"]
            expected = ["interactionSessionKey"]
            results = ["userMessage": "string"]
        default: return false
        }
        return Set(required) == expected && required.count == expected.count && fields.allSatisfy { input["properties"][$0.key]["type"].string == $0.value } && results.allSatisfy { output["properties"][$0.key]["type"].string == $0.value && outputRequired.contains($0.key) }
    }
}

/// Public session identity. Apple's secret key, screenshot paths and hierarchy never enter this descriptor.
public struct AppleSimulatorDescriptor: Sendable, Equatable {
    public let id: UUID
    public let deviceID: UUID
    public let workspace: URL?
}

/// Native-only references returned by one exact synthesis call; logs are intentionally discarded.
/// Consumers must validate artifact locations and image dimensions before reading these files.
public struct AppleSimulatorObservation: Sendable, Equatable {
    public let sessionID: UUID
    public let revision: UInt64
    public let applicationState: String
    public let screenshot: URL
    public let hierarchy: URL
}

/// Owns one Apple session without persisting its secret. Concurrent actions fail instead of interleaving.
/// Transport failure makes the session unusable: callers must never automatically replay a gesture.
public actor AppleSimulatorSession {
    public typealias Call = @Sendable (String, [String: BridgeValue]) async throws -> BridgeValue
    private struct Session: Sendable {
        let descriptor: AppleSimulatorDescriptor
        let secret: String
        let workspaceIdentifier: String?
    }
    private let call: Call
    private var session: Session?
    private var occupied = false
    private var lost = false
    private var revision: UInt64 = 0
    public init(call: @escaping Call) { self.call = call }
    public var descriptor: AppleSimulatorDescriptor? { self.session?.descriptor }
    public var connectionIsLost: Bool { self.lost }

    // MARK: - Lifecycle

    /// Caller must admit start/install to Mimic's shared queue. Only an exact simulator UUID is accepted.
    public func start(deviceID: UUID, workspace: URL? = nil, workspaceIdentifier: String? = nil) async throws -> AppleSimulatorDescriptor {
        guard !self.occupied, self.session == nil else { throw AppleSimulatorError.occupied }
        guard !self.lost else { throw AppleSimulatorError.connectionLost }
        if let workspace {
            guard workspace.isFileURL, workspace.path.hasPrefix("/"), ["xcworkspace", "xcodeproj"].contains(workspace.pathExtension) else { throw AppleSimulatorError.arguments }
        }
        if let workspaceIdentifier {
            guard workspace != nil, !workspaceIdentifier.isEmpty, workspaceIdentifier.utf8.count <= 4096, !workspaceIdentifier.contains("\0") else { throw AppleSimulatorError.arguments }
        }
        self.occupied = true
        defer { self.occupied = false }
        // Apple requires a unique label even when a previous native session has ended.
        let sessionID = UUID()
        var arguments: [String: BridgeValue] = ["deviceIdentifier": .string(deviceID.uuidString), "sessionIdentifier": .string("Mimic Simulator " + sessionID.uuidString)]
        if let workspace { arguments["workspaceIdentifier"] = .string(workspaceIdentifier ?? workspace.path) }
        let result = try await self.invoke(workspace == nil ? "DeviceInteractionStartSession" : "DeviceInteractionStartWorkspaceSession", arguments)
        guard let key = result["interactionSessionKey"].string, !key.isEmpty, key.utf8.count <= 4096 else {
            self.lost = true
            throw AppleSimulatorError.invalidResponse
        }
        guard result["deviceIsSimulator"] == .bool(true), result["deviceUUID"].string.flatMap(UUID.init(uuidString:)) == deviceID else {
            // The tool can select a 'best candidate'. Close an unexpected target before any interaction.
            do { _ = try await self.invoke("DeviceInteractionEndSession", ["interactionSessionKey": .string(key)]) }
            catch { self.lost = true; throw error }
            throw AppleSimulatorError.wrongDevice
        }
        let descriptor = AppleSimulatorDescriptor(id: sessionID, deviceID: deviceID, workspace: workspace)
        self.session = Session(descriptor: descriptor, secret: key, workspaceIdentifier: workspaceIdentifier ?? workspace?.path)
        self.revision = 0
        return descriptor
    }

    /// Expensive install/build is available only to a workspace-bound session and requires queue admission.
    public func installAndRun(sessionID: UUID) async throws {
        let current = try self.admit(sessionID)
        guard let workspace = current.descriptor.workspace else { throw AppleSimulatorError.arguments }
        self.occupied = true
        defer { self.occupied = false }
        _ = try await self.invoke("DeviceInteractionInstallAndRun", ["interactionSessionKey": .string(current.secret), "workspaceIdentifier": .string(current.workspaceIdentifier ?? workspace.path)])
    }

    /// Closing a session never shuts down its simulator. On a lost connection only explicit cleanup is attempted.
    public func close(sessionID: UUID) async throws {
        guard !self.occupied else { throw AppleSimulatorError.occupied }
        guard let current = self.session, current.descriptor.id == sessionID else { throw AppleSimulatorError.noSession }
        self.occupied = true
        defer { self.occupied = false }
        _ = try await self.invoke("DeviceInteractionEndSession", ["interactionSessionKey": .string(current.secret)])
        self.session = nil
        self.lost = false
    }

    // MARK: - Actions and observations

    /// A nil action only captures. The result's revision rejects coordinates derived from an older observation.
    public func capture(sessionID: UUID) async throws -> AppleSimulatorObservation {
        try await self.synthesize(sessionID: sessionID, action: nil, observedRevision: nil)
    }
    public func perform(sessionID: UUID, action: AppleSimulatorAction, observedRevision: UInt64) async throws -> AppleSimulatorObservation {
        try await self.synthesize(sessionID: sessionID, action: action, observedRevision: observedRevision)
    }
    private func synthesize(sessionID: UUID, action: AppleSimulatorAction?, observedRevision: UInt64?) async throws -> AppleSimulatorObservation {
        let current = try self.admit(sessionID)
        if action != nil { guard self.revision > 0, observedRevision == self.revision else { throw AppleSimulatorError.arguments } }
        var arguments: [String: BridgeValue] = ["interactSessionKey": .string(current.secret)]
        if let action { arguments["interactionCommand"] = .string(try action.command()) }
        self.occupied = true
        defer { self.occupied = false }
        let result = try await self.invoke("DeviceInteractionSynthesize", arguments)
        // Any completed call invalidates the previous image, even if the response cannot be decoded.
        self.revision += 1
        guard let state = result["applicationState"].string, let screenshot = Self.artifact(result["screenshotPath"].string), let hierarchy = Self.artifact(result["hierarchyPath"].string) else {
            self.lost = true
            throw AppleSimulatorError.invalidResponse
        }
        return AppleSimulatorObservation(sessionID: current.descriptor.id, revision: self.revision, applicationState: state, screenshot: screenshot, hierarchy: hierarchy)
    }
    private func admit(_ id: UUID) throws -> Session {
        guard !self.occupied else { throw AppleSimulatorError.occupied }
        guard !self.lost else { throw AppleSimulatorError.connectionLost }
        guard let current = self.session, current.descriptor.id == id else { throw AppleSimulatorError.noSession }
        return current
    }
    private func invoke(_ name: String, _ arguments: [String: BridgeValue]) async throws -> BridgeValue {
        do { return try await self.call(name, arguments) }
        catch { self.lost = true; throw AppleSimulatorError.connectionLost }
    }
    private static func artifact(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
