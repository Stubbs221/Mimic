//
//  Xcode27SimulatorConnection.swift
//  AppleSimulatorMCP
//
//  Created by Василий Маслов on 04.10.2026.
import Darwin
import Foundation
import MCP
import MimicCore
import XcodeMCPTransport

/// Headless Xcode 27 connection exposing only validated Apple device tools, never an arbitrary MCP proxy.
/// Create a fresh owner after a lost connection; an uncertain session is never reset or replayed.
@MainActor public final class Xcode27SimulatorConnection {
    public private(set) var version = ""
    /// Fixed diagnostic categories only; never copies server text or session values.
    public private(set) var failureCategory = ""
    public private(set) var supportedTools: Set<String> = []
    private var client: Client?
    private var process: Process?
    private var pipes: [Pipe] = []
    private var sequence = 0
    private var workspaceAccessSupported = false
    private var workspaceIdentifiers: [URL: String] = [:]
    public private(set) lazy var session = AppleSimulatorSession { [weak self] name, arguments in
        guard let self else { throw AppleSimulatorError.connectionLost }
        return try await self.call(name, arguments)
    }
    private let clientName: String
    public init(clientName: String = "Mimic") { self.clientName = clientName }

    /// Never enables mcp-server, changes xcode-select, or grants agent permissions automatically.
    public func connect(developerDirectory: String) async throws {
        guard self.client == nil else { throw AppleSimulatorError.occupied }
        let developer = URL(fileURLWithPath: developerDirectory).resolvingSymlinksInPath()
        let app = developer.deletingLastPathComponent().deletingLastPathComponent()
        guard let bundle = Bundle(url: app), let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { throw AppleSimulatorError.unsupported }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let capability = AppleSimulatorAvailability.evaluate(selectedXcodeVersion: version, macOSMajor: system.majorVersion, macOSMinor: system.minorVersion, nativeToolsAvailable: false)
        guard capability == .requiresNativeAccess else { throw AppleSimulatorError.unsupported }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["mcpbridge"]
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = developer.path
        environment.removeValue(forKey: "MCP_XCODE_PID")
        environment["LANG"] = "en_US.UTF-8"; environment["LC_ALL"] = "en_US.UTF-8"; environment["LC_CTYPE"] = "en_US.UTF-8"
        let selectedEnvironment = environment
        let lookup = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcrun", ["--find", "mcp-server"], environment: selectedEnvironment) }.value
        guard lookup.0 == 0, FileManager.default.isExecutableFile(atPath: lookup.1) else { throw AppleSimulatorError.unsupported }
        child.environment = environment
        let input = Pipe(), output = Pipe()
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw AppleSimulatorError.connectionLost }
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        self.pipes = [input, output]
        let client = Client(name: self.clientName, version: "0.1.0")
        self.client = client; self.process = child
        let deadline = Task { try? await Task.sleep(for: .seconds(120)); if !Task.isCancelled { await client.disconnect(); if child.isRunning { child.terminate() } } }
        defer { deadline.cancel() }
        do {
            try child.run()
            let initialized = try await client.connect(transport: XcodeRPCTransport(base: StdioTransport(input: .init(rawValue: output.fileHandleForReading.fileDescriptor), output: .init(rawValue: input.fileHandleForWriting.fileDescriptor))))
            self.version = initialized.serverInfo.version
            var cursor: String?, cursors = Set<String>(), pages = 0
            repeat {
                pages += 1
                guard pages <= 8 else { throw AppleSimulatorError.unsupported }
                let page = try await client.listTools(cursor: cursor)
                for tool in page.tools {
                    if tool.name == "XcodeOpenWorkspace" {
                        self.workspaceAccessSupported = AppleSimulatorProfile.acceptsWorkspaceAccess(input: try BridgeValue.encode(tool.inputSchema), output: try tool.outputSchema.map(BridgeValue.encode) ?? .null)
                    }
                    guard AppleSimulatorProfile.accepts(name: tool.name, input: try BridgeValue.encode(tool.inputSchema), output: try tool.outputSchema.map(BridgeValue.encode) ?? .null) else { continue }
                    self.supportedTools.insert(tool.name)
                }
                cursor = page.nextCursor
                if let cursor, !cursors.insert(cursor).inserted { throw AppleSimulatorError.unsupported }
            } while cursor != nil
            guard self.supportedTools == Set(AppleSimulatorProfile.tools) else { throw AppleSimulatorError.unsupported }
        } catch {
            await self.disconnect()
            throw error
        }
    }

    /// Native authorization handshake for an explicit project only. Apple may wait for user approval.
    /// A CLI `mcp-server open` does not authorize this client; this call uses the same MCP connection.
    public func authorize(workspace: URL) async throws {
        guard self.workspaceAccessSupported, workspace.isFileURL, workspace.path.hasPrefix("/"), ["xcworkspace", "xcodeproj"].contains(workspace.pathExtension), FileManager.default.fileExists(atPath: workspace.path) else { throw AppleSimulatorError.arguments }
        let result = try await self.call("XcodeOpenWorkspace", ["path": .string(workspace.path)])
        guard let identifier = result["workspaceIdentifier"].string, !identifier.isEmpty, identifier.utf8.count <= 4096 else { throw AppleSimulatorError.invalidResponse }
        if let path = result["workspacePath"].string {
            guard URL(fileURLWithPath: path).resolvingSymlinksInPath() == workspace.resolvingSymlinksInPath() else { throw AppleSimulatorError.invalidResponse }
        }
        self.workspaceIdentifiers[workspace.resolvingSymlinksInPath()] = identifier
    }

    /// Workspace aliases are taken only from this connection's validated authorization response.
    public func startSession(deviceID: UUID, workspace: URL? = nil) async throws -> AppleSimulatorDescriptor {
        let identifier = workspace.flatMap { self.workspaceIdentifiers[$0.resolvingSymlinksInPath()] }
        guard workspace == nil || identifier != nil else { throw AppleSimulatorError.arguments }
        return try await self.session.start(deviceID: deviceID, workspace: workspace, workspaceIdentifier: identifier)
    }

    /// The caller must explicitly close its Apple session first. Disconnect only terminates our bridge child.
    public func disconnect() async {
        let client = self.client
        self.client = nil; self.supportedTools = []; self.workspaceAccessSupported = false; self.workspaceIdentifiers = [:]
        await client?.disconnect()
        if let process = self.process, process.isRunning { process.terminate() }
        self.process = nil
        for pipe in self.pipes { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        self.pipes = []
    }

    private func call(_ name: String, _ arguments: [String: BridgeValue]) async throws -> BridgeValue {
        guard let client = self.client, (self.supportedTools.contains(name) || name == "XcodeOpenWorkspace" && self.workspaceAccessSupported) else { throw AppleSimulatorError.unsupported }
        self.sequence += 1
        let values = try JSONDecoder().decode([String: Value].self, from: JSONEncoder().encode(arguments))
        let request = try await client.send(CallTool.request(id: .number(self.sequence), .init(name: name, arguments: values)))
        let deadline = Task { try? await Task.sleep(for: .seconds(name == "DeviceInteractionInstallAndRun" ? 1800 : name == "XcodeOpenWorkspace" ? 600 : 120)); if !Task.isCancelled { await client.disconnect() } }
        defer { deadline.cancel() }
        let result: CallTool.Result
        do { result = try await request.value }
        catch {
            self.failureCategory = "rpc_failure"
            throw error
        }
        guard result.isError != true else {
            let body = result.content.compactMap { content -> String? in if case let .text(value, _, _) = content { value.lowercased() } else { nil } }.joined(separator: "\n")
            let markers = ["permission", "access", "approve", "denied", "workspace", "device", "simulator", "session", "unavailable", "failed", "not found", "invalid", "timeout", "agent", "identifier", "unique", "already", "boot", "xcode", "tool", "enable"]
            self.failureCategory = "native_tool_error:" + markers.filter { body.contains($0) }.joined(separator: ",")
            throw AppleSimulatorError.connectionLost
        }
        if let structured = result.structuredContent { return try BridgeValue.encode(structured) }
        let body = result.content.compactMap { content -> String? in if case let .text(value, _, _) = content { value } else { nil } }.joined(separator: "\n")
        do { return try JSONDecoder().decode(BridgeValue.self, from: Data(body.utf8)) }
        catch { self.failureCategory = "non_json_tool_content"; throw error }
    }
}
