// Created by Василий Маслов on 04.10.2026.
import AppKit
import Combine
import Darwin
import Foundation
import MCP
import MimicCore
import XcodeMCPTransport

/// Explicit connection to the selected Xcode's bridge, never a universal tool proxy.
@MainActor final class XcodeBuildConnection: ObservableObject {
    @Published private(set) var project: ProjectContext?
    @Published private(set) var windows: [String: String] = [:]
    @Published private(set) var version = ""
    @Published private(set) var connecting = false
    @Published private(set) var message = ""
    private(set) var developerDirectory: String?
    private var client: Client?
    private var requestSequence = 0
    private var process: Process?
    private var pipes: [Pipe] = []
    private var supported = Set<String>()
    private var progressHandlers: [String: (String) async -> Void] = [:]
    struct Result { let status: BuildStatus; let text: String; let errors: Int?; let warnings: Int?; let summaryPath: String?; let truncated: Bool }
    func supports(_ operation: BuildOperation) -> Bool { client != nil && supported.contains(operation == .build ? "BuildProject" : "RunSomeTests") }
    func hasWorkspace(_ tab: String, path: String) -> Bool {
        guard let actual = windows[tab] else { return false }
        return URL(fileURLWithPath: actual).resolvingSymlinksInPath() == URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    func connect(project: ProjectContext) async {
        guard !connecting else { return }; connecting = true; message = ""
        defer { connecting = false }
        await disconnect()
        do {
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); child.arguments = ["mcpbridge"]
            var environment = EnvironmentInspector.environment(project: project)
            let developer: String
            if let selected = project.developerDirectory { developer = selected } else { developer = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1 }.value }
            let app = URL(fileURLWithPath: developer).deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
            let instances = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath() == app }
            guard instances.count == 1, let instance = instances.first else { throw BuildError.configuration }
            environment["MCP_XCODE_PID"] = String(instance.processIdentifier)
            environment["DEVELOPER_DIR"] = developer; developerDirectory = developer
            child.environment = environment
            let input = Pipe(), output = Pipe(); pipes = [input, output]
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw BuildError.unavailable }
            child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
            let connection = Client(name: "Mimic", version: "1.0.0"); client = connection; process = child
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    await connection.disconnect()
                    guard let self, self.process === child else { return }
                    self.client = nil; self.project = nil; self.supported = []; self.windows = [:]; self.developerDirectory = nil
                    self.message = text("build.tracking.lost")
                }
            }
            try child.run()
            let deadline = Task { try? await Task.sleep(for: .seconds(120)); if !Task.isCancelled { await connection.disconnect(); if child.isRunning { child.terminate() } } }
            defer { deadline.cancel() }
            let initialized = try await connection.connect(transport: XcodeRPCTransport(base: StdioTransport(input: .init(rawValue: output.fileHandleForReading.fileDescriptor), output: .init(rawValue: input.fileHandleForWriting.fileDescriptor))))
            version = initialized.serverInfo.version
            var cursor: String?; var seenCursors = Set<String>(); var pages = 0
            repeat {
                pages += 1; guard pages <= 8 else { throw BuildError.unsupported }
                let page = try await connection.listTools(cursor: cursor)
                for tool in page.tools {
                    if XcodeBuildProfile.accepts(name: tool.name, input: try BridgeValue.encode(tool.inputSchema), output: try tool.outputSchema.map(BridgeValue.encode) ?? .null) { supported.insert(tool.name) }
                }
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted { throw BuildError.unsupported }
            } while cursor != nil
            guard supported.contains("XcodeListWindows"), supported.contains("BuildProject") else { throw BuildError.unsupported }
            await connection.onNotification(ProgressNotification.self) { [weak self] notification in
                guard case let .string(token) = notification.params.progressToken, let message = notification.params.message else { return }
                await self?.progress(token: token, message: message)
            }
            let result = try await call(name: "XcodeListWindows", arguments: [:])
            windows = XcodeBuildProfile.windows(result.value["message"].string ?? "")
            guard windows.values.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == URL(fileURLWithPath: project.workspace).resolvingSymlinksInPath().path }) else { throw BuildError.configuration }
            self.project = project
        } catch { await disconnect(); message = text("build.error." + ((error as? BuildError)?.rawValue ?? "unavailable")) }
    }
    func disconnect() async {
        let old = client; client = nil; project = nil; supported = []; windows = [:]
        developerDirectory = nil
        await old?.disconnect()
        if let process, process.isRunning { process.terminate() }; process = nil; pipes = []
    }
    func refreshWindows() async throws {
        let result = try await call(name: "XcodeListWindows", arguments: [:]); windows = XcodeBuildProfile.windows(result.value["message"].string ?? "")
    }
    private func progress(token: String, message: String) async { await progressHandlers[token]?(message) }
    private func call(name: String, arguments: [String: Value], token: String? = nil, requestStarted: ((String) -> Void)? = nil) async throws -> (value: BridgeValue, text: String, isError: Bool) {
        guard let client, supported.contains(name) else { throw BuildError.unsupported }
        requestSequence += 1
        let request = try await client.send(CallTool.request(id: .number(requestSequence), .init(name: name, arguments: arguments, meta: token.map { Metadata(progressToken: .string($0)) })))
        requestStarted?(String(describing: request.requestID))
        let result = try await request.value
        let strings = result.content.compactMap { content -> String? in if case let .text(text, _, _) = content { return text }; return nil }
        let body = strings.joined(separator: "\n")
        let structured = try result.structuredContent.map(BridgeValue.encode) ?? (try? JSONDecoder().decode(BridgeValue.self, from: Data(body.utf8))) ?? .null
        return (structured, body, result.isError == true)
    }
    private func artifactPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ActionArtifacts", isDirectory: true).resolvingSymlinksInPath().path + "/"
        guard file.path.hasPrefix(root), file.pathExtension == "txt" else { return nil }
        return file.path
    }
    func run(_ record: BuildActivity, requestStarted: @escaping (String) -> Void, progress: @escaping (String) async -> Void) async throws -> Result {
        guard project == record.project, hasWorkspace(record.parameters.workspaceTab, path: record.project.workspace), supports(record.parameters.operation) else { throw BuildError.configuration }
        let token = record.id.uuidString; progressHandlers[token] = progress
        defer { progressHandlers[token] = nil }
        var arguments: [String: Value] = ["tabIdentifier": .string(record.parameters.workspaceTab)]
        if record.parameters.operation == .test {
            arguments["tests"] = .array(record.parameters.testIdentifiers.map { identifier in
                let parts = identifier.split(separator: "/").map(String.init)
                return .object(["targetName": .string(parts[0]), "testIdentifier": .string(parts.dropFirst().joined(separator: "/"))])
            })
        }
        let connection = client
        let deadline = Task { try? await Task.sleep(for: .seconds(1800)); if !Task.isCancelled { await connection?.disconnect() } }
        defer { deadline.cancel() }
        let result = try await call(name: record.parameters.operation == .build ? "BuildProject" : "RunSomeTests", arguments: arguments, token: token, requestStarted: requestStarted)
        let entries = result.value["errors"].array
        let errors = entries?.allSatisfy({ ["error", "warning", "remark"].contains($0["classification"].string?.lowercased() ?? "") }) == true ? entries : nil
        // Only files returned by this exact tool call under Xcode's private artifacts directory belong to it.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let structuredText = result.value == .null ? result.text : String(decoding: try encoder.encode(result.value), as: UTF8.self)
        let logPath = artifactPath(result.value[record.parameters.operation == .build ? "fullLogPath" : "fullConsoleLogsPath"].string)
        var body = structuredText; var truncated = result.value["truncated"] == .bool(true)
        if let logPath, let handle = FileHandle(forReadingAtPath: logPath) {
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data()
            let limit = 20 * 1024 * 1024
            if bytes.count > limit { truncated = true }
            body += "\n" + BuildOutput.slice(Data(bytes.prefix(limit)), after: 0, limit: limit).text
            if bytes.count > limit { body += "\n[TRUNCATED XCODE RESULT LOG]\n" }
        }
        return .init(status: XcodeBuildProfile.status(operation: record.parameters.operation, result: result.value, isError: result.isError), text: body, errors: record.parameters.operation == .test ? result.value["counts"]["failed"].integer : errors?.filter { $0["classification"].string?.lowercased() == "error" }.count, warnings: errors?.filter { $0["classification"].string?.lowercased() == "warning" }.count, summaryPath: artifactPath(result.value["fullSummaryPath"].string), truncated: truncated)
    }
}
