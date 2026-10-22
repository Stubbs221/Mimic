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
    /// Unlocalized cause of the last failed connection, bounded for activity diagnostics.
    private(set) var connectionFailure = ""
    private(set) var developerDirectory: String?
    private var client: Client?
    private var requestSequence = 0
    private var process: Process?
    private var pipes: [Pipe] = []
    private var supported = Set<String>()
    private var xcodeProcessID: pid_t?
    private let automation = XcodeRunAutomation()
    private var ownedDebug: (workspace: String, processID: Int?, actionID: String?)?
    private var progressHandlers: [String: (String) async -> Void] = [:]
    private var executionHandlers: [String: (BuildExecutionProgress) async -> Void] = [:]
    private var cancellableRequests: [String: (Client, MCP.ID)] = [:]
    struct Result { let status: BuildStatus; let text: String; let errors: Int?; let warnings: Int?; let summaryPath: String?; let truncated: Bool }
    func supports(_ operation: BuildOperation) -> Bool { client != nil && supported.contains(operation == .build ? "BuildProject" : "RunSomeTests") }
    func hasWorkspace(_ tab: String, path: String) -> Bool {
        guard let actual = windows[tab] else { return false }
        return URL(fileURLWithPath: actual).resolvingSymlinksInPath() == URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    func connect(project: ProjectContext) async {
        guard !connecting else { return }; connecting = true; message = ""; connectionFailure = ""
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
            xcodeProcessID = instance.processIdentifier
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
            // Xcode holds a new agent binary until the user answers its trust prompt.
            let deadline = Task { try? await Task.sleep(for: .seconds(300)); if !Task.isCancelled { await connection.disconnect(); if child.isRunning { child.terminate() } } }
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
                guard case let .string(token) = notification.params.progressToken else { return }
                let fraction = notification.params.total.flatMap { total in total > 0 && notification.params.progress >= 0 && notification.params.progress <= total ? notification.params.progress / total : nil }
                await self?.executionProgress(token: token, value: .init(operation: notification.params.message.map { String(DiagnosticText.clean($0).prefix(240)) }, fraction: fraction))
                if let message = notification.params.message { await self?.progress(token: token, message: message) }
            }
            let result = try await call(name: "XcodeListWindows", arguments: [:])
            windows = XcodeBuildProfile.windows(result.value["message"].string ?? "")
            guard windows.values.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == URL(fileURLWithPath: project.workspace).resolvingSymlinksInPath().path }) else { throw BuildError.configuration }
            self.project = project
        } catch {
            await disconnect(); message = text("build.error." + ((error as? BuildError)?.rawValue ?? "unavailable"))
            connectionFailure = String(DiagnosticText.clean(String(describing: error)).prefix(300))
        }
    }
    func disconnect() async {
        let old = client; client = nil; project = nil; supported = []; windows = [:]
        developerDirectory = nil; executionHandlers = [:]; cancellableRequests = [:]
        xcodeProcessID = nil
        await old?.disconnect()
        if let process, process.isRunning { process.terminate() }; process = nil; pipes = []
    }
    func refreshWindows() async throws {
        let result = try await call(name: "XcodeListWindows", arguments: [:]); windows = XcodeBuildProfile.windows(result.value["message"].string ?? "")
    }

    // MARK: - Native Run action

    /// Opens the exact pinned Xcode and workspace, preserving its incremental build storage and Run settings.
    func runWithDebugger(_ record: BuildActivity, requestStarted: @escaping (String) -> Void,
                         progress: @escaping (BuildExecutionProgress) async -> Void,
                         authorize: @escaping () async throws -> Void,
                         stage: @escaping (BuildStage, Int) -> Void,
                         phase: @escaping (String) -> Void = { _ in }) async throws -> (processID: Int?, detail: String) {
        try Task.checkCancellation()
        guard let developer = record.selectedDeveloperDirectory else { throw XcodeRunFailure(step: "context.developer", code: .configuration, detail: "No pinned Xcode") }
        let application = URL(fileURLWithPath: developer).deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: record.project.workspace)], withApplicationAt: application, configuration: configuration)
        let target = XcodeRunAutomation.Target(application: application.path, workspace: record.project.workspace, scheme: record.parameters.scheme, destinationID: record.parameters.destinationID)
        // A freshly opened large workspace takes a while to get its window; connecting earlier is rejected by Xcode.
        var attempts = 0
        while let pending = try await automation.workspaceNotReady(target) {
            attempts += 1
            guard attempts < 240 else { throw XcodeRunFailure(step: "automation.workspace", code: .configuration, detail: pending) }
            try await Task.sleep(for: .milliseconds(500))
        }
        try Task.checkCancellation()
        if project != record.project || developerDirectory != developer {
            // Unnotarized agents get Xcode's "Allow Mimic" prompt per binary; a slow handshake brings that prompt forward.
            let prompt = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3)); guard !Task.isCancelled else { return }
                phase("build.phase.xcodeApproval")
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
                    .first { $0.bundleURL?.resolvingSymlinksInPath() == application.resolvingSymlinksInPath() }?.activate()
            }
            await connect(project: record.project)
            prompt.cancel(); phase("build.phase.running")
        }
        guard project == record.project, developerDirectory == developer, let pid = xcodeProcessID else {
            throw XcodeRunFailure(step: "mcp.connect", code: .xcodeAccess, detail: connectionFailure.isEmpty ? message : connectionFailure)
        }
        try await refreshWindows()
        let candidates = windows.filter { URL(fileURLWithPath: $0.value).resolvingSymlinksInPath().path == URL(fileURLWithPath: record.project.workspace).resolvingSymlinksInPath().path }
        guard candidates.count == 1, let tab = candidates.keys.first else { throw XcodeRunFailure(step: "mcp.workspaceWindow", code: .configuration, detail: "\(candidates.count) matching of \(windows.count) windows") }
        let native = supported.contains("RunProject") && supported.contains("InvokeDebuggerCommand")
        guard !native || supported.contains("XcodeListRunDestinations") else { throw XcodeRunFailure(step: "mcp.tools", code: .unsupported, detail: "XcodeListRunDestinations is unavailable") }
        try await authorize()
        let token = record.id.uuidString
        executionHandlers[token] = progress
        defer { executionHandlers[token] = nil }
        // A repeat may replace our own debug session, never an unrelated session started in Xcode.
        if let owned = ownedDebug, owned.workspace == record.project.workspace {
            if let expected = owned.processID, supported.contains("InvokeDebuggerCommand"), supported.contains("StopProject") {
                let current = try await call(name: "InvokeDebuggerCommand", arguments: ["tabIdentifier": .string(tab), "command": .string("process status"), "timeout": .int(5)])
                if current.value["debugSessionActive"] != .bool(false) {
                    guard !current.isError, current.value["debugSessionActive"] == .bool(true), current.value["processIdentifier"].integer == expected else { throw BuildError.xcodeBusy }
                    _ = try await call(name: "StopProject", arguments: ["tabIdentifier": .string(tab)])
                }
            } else if let actionID = owned.actionID {
                do {
                    let status = try await automation.debugStatus(target, actionID: actionID)
                    if status == "running" { try await automation.stopOwnedDebug(target, actionID: actionID) }
                } catch { try await automation.requireIdle(target) }
            }
            for attempt in 0..<20 {
                do { try await automation.requireIdle(target); break }
                catch let failure as XcodeRunFailure where failure.code == .xcodeBusy { if attempt == 19 { throw failure }; try await Task.sleep(for: .milliseconds(250)) }
            }
            ownedDebug = nil
        }
        try await automation.requireIdle(target)
        try await authorize()
        let destinationTitle = try await automation.select(target)
        if native { try await verifyDestination(tab: tab, scheme: record.parameters.scheme, title: destinationTitle, step: "mcp.selection") }
        else { try await automation.verify(target) }
        if !XcodeCompilationProgress.requestAccess() {
            for _ in 0..<240 {
                try Task.checkCancellation()
                if XcodeCompilationProgress.hasAccess { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard XcodeCompilationProgress.hasAccess else { throw BuildError.xcodeAccess }
        }
        try Task.checkCancellation()
        guard self.project == record.project, xcodeProcessID == pid else { throw BuildError.context }
        let workspace = record.project.workspace
        let deadline = Task { try? await Task.sleep(for: .seconds(1800)); if !Task.isCancelled { await self.disconnect() } }
        defer { deadline.cancel() }
        let monitor = Task {
            // Until the bar drops below full it still shows the previous action, not this build.
            var fresh = false
            while !Task.isCancelled {
                let snapshot = await Task.detached { XcodeCompilationProgress.read(processID: pid, workspace: workspace) }.value
                if let fraction = snapshot?.fraction, fraction < 1 { fresh = true }
                if fresh, let snapshot { await progress(snapshot) }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        defer { monitor.cancel() }
        if native {
            try await verifyDestination(tab: tab, scheme: record.parameters.scheme, title: destinationTitle, step: "mcp.beforeRun")
            try await authorize()
            let result = try await call(name: "RunProject", arguments: ["tabIdentifier": .string(tab), "attachDebugger": .bool(true)], token: record.id.uuidString, requestStarted: requestStarted)
            let processID: Int
            do { processID = try XcodeRunVerification.launchedProcess(result.value, isError: result.isError) }
            catch {
                let errors = result.value["buildErrors"].array ?? []
                throw XcodeRunFailure(step: "mcp.runProject", code: .debuggerUnavailable, detail: result.value["runResult"].string ?? result.text,
                                      buildFailed: errors.contains { $0["classification"].string?.lowercased() == "error" }, issues: XcodeRunVerification.issues(errors))
            }
            stage(.launch, 2)
            // The launched host process is the only evidence that names the simulator by UUID after Run.
            let executable = Self.executablePath(processID) ?? ""
            guard XcodeRunVerification.processBelongsToSimulator(executablePath: executable, deviceID: record.parameters.destinationID) else {
                throw XcodeRunFailure(step: "launch.device", code: .configuration, detail: "Process \(processID) is not in simulator \(record.parameters.destinationID): " + (executable.isEmpty ? "no executable path" : executable))
            }
            try await verifyDestination(tab: tab, scheme: record.parameters.scheme, title: destinationTitle, step: "mcp.afterRun")
            let verified = try await call(name: "InvokeDebuggerCommand", arguments: ["tabIdentifier": .string(tab), "command": .string("process status"), "timeout": .int(5)])
            guard XcodeRunVerification.debuggerMatches(verified.value, process: processID, isError: verified.isError) else {
                throw XcodeRunFailure(step: "lldb.processStatus", code: .debuggerUnavailable, detail: "debugSessionActive \(verified.value["debugSessionActive"] == .bool(true)), process \(verified.value["processIdentifier"].integer.map(String.init) ?? "missing"), expected \(processID)")
            }
            ownedDebug = (workspace, processID, nil)
            return (processID, result.value["runResult"].string ?? "")
        }
        let version = Bundle(url: application)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard version.hasPrefix("26."), supports(.build) else { throw BuildError.unsupported }
        try await authorize()
        let result = try await call(name: "BuildProject", arguments: ["tabIdentifier": .string(tab)], token: record.id.uuidString, requestStarted: requestStarted)
        let built = XcodeBuildProfile.status(operation: .build, result: result.value, isError: result.isError)
        guard built == .succeeded else {
            throw XcodeRunFailure(step: "mcp.buildProject", code: .configuration, detail: result.value["buildResult"].string ?? result.text,
                                  buildFailed: built == .failed, issues: XcodeRunVerification.issues(result.value["errors"].array))
        }
        stage(.launch, 1)
        try await automation.verify(target)
        try await authorize()
        let action = try await automation.debugWithoutBuilding(target)
        ownedDebug = (workspace, nil, action)
        for _ in 0..<120 {
            try Task.checkCancellation()
            let status = try await automation.debugStatus(target, actionID: action)
            if status == "running" || status == "succeeded" {
                let attached = await Task.detached { XcodeCompilationProgress.debuggerIsAttached(processID: pid, workspace: workspace) }.value
                if attached { return (nil, "Xcode debug action: " + action) }
            }
            guard status != "failed", status != "error occurred", status != "cancelled" else { throw BuildError.debuggerUnavailable }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw BuildError.debuggerUnavailable
    }
    /// Evidence that nothing Mimic may have started is still running: the pinned Xcode is gone, the workspace is closed,
    /// or Xcode reports no unfinished scheme action and its toolbar shows no build in progress.
    func confirmsIdle(developer: String, workspace: String) async -> Bool {
        let application = URL(fileURLWithPath: developer).deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        guard let instance = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.resolvingSymlinksInPath() == application }) else { return true }
        let target = XcodeRunAutomation.Target(application: application.path, workspace: workspace, scheme: "", destinationID: "")
        do {
            if let pending = try await automation.workspaceNotReady(target) { return pending.contains("Workspace identity changed") }
            try await automation.requireIdle(target)
        } catch { return false }
        let pid = instance.processIdentifier
        let toolbar = await Task.detached { XcodeCompilationProgress.read(processID: pid, workspace: workspace) }.value
        return toolbar?.fraction.map { $0 >= 1 } ?? true
    }
    /// Cancels only the exact MCP request or pinned legacy debug action. Neither implies Xcode stopped.
    func requestRunCancellation(_ record: BuildActivity) async throws {
        if let (client, id) = cancellableRequests[record.id.uuidString] {
            try await client.cancelRequest(id, reason: "User requested cancellation in Mimic")
            return
        }
        guard let owned = ownedDebug, owned.workspace == record.project.workspace, let action = owned.actionID,
              let developer = record.selectedDeveloperDirectory else { throw BuildError.unsupported }
        let application = URL(fileURLWithPath: developer).deletingLastPathComponent().deletingLastPathComponent().path
        try await automation.stopOwnedDebug(.init(application: application, workspace: record.project.workspace, scheme: record.parameters.scheme, destinationID: record.parameters.destinationID), actionID: action)
    }
    /// Xcode 27 picker state; its scripting dictionary reports no active run destination.
    private func verifyDestination(tab: String, scheme: String, title: String, step: String) async throws {
        let result = try await call(name: "XcodeListRunDestinations", arguments: ["tabIdentifier": .string(tab)])
        guard XcodeRunVerification.destinationMatches(result.value, scheme: scheme, title: title, isError: result.isError) else {
            throw XcodeRunFailure(step: step, code: .configuration, detail: "active \(result.value["activeSchemeName"].string ?? "none") / \(result.value["activeDestinationDisplayTitle"].string ?? "none"), expected \(scheme) / \(title)")
        }
    }
    private nonisolated static func executablePath(_ processID: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid_t(processID), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
    private func progress(token: String, message: String) async { await progressHandlers[token]?(message) }
    private func executionProgress(token: String, value: BuildExecutionProgress) async { await executionHandlers[token]?(value) }
    private func call(name: String, arguments: [String: Value], token: String? = nil, requestStarted: ((String) -> Void)? = nil) async throws -> (value: BridgeValue, text: String, isError: Bool) {
        guard let client, supported.contains(name) else { throw BuildError.unsupported }
        requestSequence += 1
        let request = try await client.send(CallTool.request(id: .number(requestSequence), .init(name: name, arguments: arguments, meta: token.map { Metadata(progressToken: .string($0)) })))
        if let token { cancellableRequests[token] = (client, request.requestID) }
        defer { if let token { cancellableRequests[token] = nil } }
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
