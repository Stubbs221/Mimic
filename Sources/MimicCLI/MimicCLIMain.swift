// Created by Василий Маслов on 04.10.2026.
import AppKit
import Darwin
import Foundation
import MimicCore

/// A terminal observer of native operations. No process or shell is launched on behalf of callers.
@main struct MimicCLIMain {
    enum CLIError: Error { case arguments, bridge(String), context }
    @MainActor static var interrupted = false
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data(("MimicCLI: \(error)\n" + usage + "\n").utf8)); exit(2) }
    }
    static let usage = """
    MimicCLI build --scheme NAME --configuration Debug --destination UUID [--platform ios|tvos] [--checkout PATH] [--request-id UUID] [--detach]
    MimicCLI test --scheme NAME --configuration Debug --destination UUID --only-testing Target/Class[/method] [--test-plan NAME] [--detach]
    MimicCLI status|logs|cancel ID
    Xcode MCP: build|test --backend xcodeMCP --workspace-tab TAB --confirm-ios-simulator
    """
    @MainActor static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args == ["--help"] { print(usage); return }
        let verb = args.removeFirst()
        if ["status", "logs", "cancel"].contains(verb) {
            guard args.count == 1, let id = UUID(uuidString: args[0]) else { throw CLIError.arguments }
            try await ensureNativeApp()
            if verb == "logs" { try await observe(id, wait: false); return }
            let value = try await call(verb == "status" ? "get_build_activity" : "cancel_build_activity", ["activityID": .string(id.uuidString)])
            printJSON(value); return
        }
        guard ["build", "test"].contains(verb) else { throw CLIError.arguments }
        var options: [String: String] = [:], tests: [String] = [], detach = false, confirmed = false
        let allowed = Set(["--scheme", "--configuration", "--destination", "--checkout", "--request-id", "--backend", "--workspace-tab", "--only-testing", "--test-plan", "--platform"])
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--detach" { guard !detach else { throw CLIError.arguments }; detach = true; continue }
            if key == "--confirm-ios-simulator" { guard !confirmed else { throw CLIError.arguments }; confirmed = true; continue }
            guard allowed.contains(key), !args.isEmpty else { throw CLIError.arguments }
            let value = args.removeFirst()
            if key == "--only-testing" { tests.append(value) } else { guard options[key] == nil else { throw CLIError.arguments }; options[key] = value }
        }
        guard let backend = BuildBackend(rawValue: options["--backend"] ?? "cli") else { throw CLIError.arguments }
        if let platform = options["--platform"], BootstrapPlatform(rawValue: platform) == nil { throw CLIError.arguments }
        let parameters = BuildParameters(operation: verb == "build" ? .build : .test, backend: backend, scheme: options["--scheme"] ?? "", configuration: options["--configuration"] ?? "", destinationID: options["--destination"] ?? "", platform: options["--platform"].flatMap(BootstrapPlatform.init(rawValue:)), testPlan: options["--test-plan"] ?? "", testIdentifiers: tests, workspaceTab: options["--workspace-tab"] ?? "")
        try parameters.validate()
        guard backend == .xcodeMCP ? confirmed : !confirmed else { throw CLIError.arguments }
        let id: UUID
        if let value = options["--request-id"] { guard let parsed = UUID(uuidString: value) else { throw CLIError.arguments }; id = parsed } else { id = UUID() }
        try await ensureNativeApp()
        let state = try await call("get_state", [:]), context = state["context"]
        let path = URL(fileURLWithPath: options["--checkout"] ?? FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        guard context["checkoutId"].string == path else { throw CLIError.context }
        var payload = try BridgeValue.encode(parameters).object ?? [:]; payload["operation"] = nil
        let value = try await call(verb == "build" ? "cli_build_project" : "cli_run_selected_tests", ["requestID": .string(id.uuidString), "context": context, "parameters": .object(payload), "simulatorConfirmed": .bool(confirmed)])
        guard let activityID = value["id"].string.flatMap(UUID.init(uuidString:)) else { throw CLIError.bridge("invalid reply") }
        if detach { print(activityID.uuidString); return }
        FileHandle.standardError.write(Data((activityID.uuidString + "\n").utf8))
        try await observe(activityID, wait: true)
    }
    static func call(_ method: String, _ parameters: [String: BridgeValue]) async throws -> BridgeValue {
        let reply = try await MimicSocket.call(.init(method: method, parameters: parameters))
        guard reply.error == nil else { throw CLIError.bridge(reply.message ?? reply.error ?? "unavailable") }; return reply.result
    }
    @MainActor static func observe(_ id: UUID, wait: Bool) async throws {
        interrupted = false
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { Task { @MainActor in interrupted = true } }; interrupt.resume()
        defer { interrupt.cancel(); signal(SIGINT, SIG_DFL) }
        var cursor = 0, cancelSent = false
        while true {
            if interrupted, !cancelSent {
                cancelSent = true
                _ = try await call("cancel_build_activity", ["activityID": .string(id.uuidString)])
            }
            let result = try await call("get_build_log", ["activityID": .string(id.uuidString), "cursor": .number(Double(cursor))])
            if result["gap"] == .bool(true) { FileHandle.standardError.write(Data("[Mimic: часть вывода пропущена]\n".utf8)) }
            let output = result["text"].string ?? ""
            FileHandle.standardOutput.write(Data(output.utf8))
            cursor = result["nextCursor"].integer ?? cursor
            let activity = result["activity"], status = activity["status"].string ?? "unknown"
            let complete = !["queued", "preparing", "running"].contains(status)
            if output.isEmpty, !wait || complete {
                if wait { FileHandle.standardError.write(Data(("Mimic: " + status + "\n").utf8)); if status != "succeeded" { exit(status == "cancelled" ? 130 : 1) } }
                return
            }
            if output.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
        }
    }
    static func printJSON(_ value: BridgeValue) { if let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) { print(string) } }
    @MainActor static func ensureNativeApp() async throws {
        if (try? await MimicSocket.call(.init(method: "get_state"))) != nil { return }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = bundled.pathExtension == "app" ? bundled : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.vmaslov.Mimic")
        guard let app else { throw MimicBridgeError.unavailable }
        let options = NSWorkspace.OpenConfiguration(); options.activates = false; options.createsNewApplicationInstance = false; options.arguments = ["--mcp-background"]
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: options)
        for _ in 0..<50 { if FileManager.default.fileExists(atPath: MimicSocket.path) { return }; try await Task.sleep(for: .milliseconds(100)) }
        throw MimicBridgeError.unavailable
    }
}
