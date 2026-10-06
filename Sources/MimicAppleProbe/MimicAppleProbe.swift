//
//  MimicAppleProbe.swift
//  MimicAppleProbe
//
//  Created by Василий Маслов on 04.10.2026.
import AppleSimulatorMCP
import Foundation
import MimicCore

/// Developer gate, not a shipped Mimic action. By default only checks the installed Xcode and tool schemas.
@main struct MimicAppleProbe {
    enum Failure: Error { case arguments, device, cleanup }
    struct Options {
        var developer: String?
        var device: UUID?
        var text: String?
        var tap: (Double, Double)?
        var actions: [AppleSimulatorAction] = []
        var workspace: URL?
        var install = false
        init(_ arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                let option = arguments[index]; index += 1
                if option == "--home" { self.actions.append(.home); continue }
                if option == "--install" { self.install = true; continue }
                guard index < arguments.count else { throw Failure.arguments }
                let value = arguments[index]; index += 1
                switch option {
                case "--developer": guard self.developer == nil else { throw Failure.arguments }; self.developer = value
                case "--device": guard self.device == nil, let id = UUID(uuidString: value) else { throw Failure.arguments }; self.device = id
                case "--text": guard self.text == nil else { throw Failure.arguments }; self.text = value
                case "--workspace": self.workspace = URL(fileURLWithPath: value)
                case "--orientation":
                    guard let orientation = AppleSimulatorAction.Orientation(rawValue: value) else { throw Failure.arguments }
                    self.actions.append(.orientation(orientation))
                case "--swipe":
                    guard let x = Double(value), index + 3 < arguments.count, let y = Double(arguments[index]), let endX = Double(arguments[index+1]), let endY = Double(arguments[index+2]), let duration = Double(arguments[index+3]) else { throw Failure.arguments }
                    index += 4; self.actions.append(.swipe(x: x, y: y, endX: endX, endY: endY, duration: duration))
                case "--tap":
                    guard self.tap == nil, let x = Double(value), index < arguments.count, let y = Double(arguments[index]) else { throw Failure.arguments }
                    index += 1; self.tap = (x, y)
                default: throw Failure.arguments
                }
            }
            guard self.device != nil || self.text == nil && self.tap == nil && self.actions.isEmpty && self.workspace == nil else { throw Failure.arguments }
            guard !self.install || self.workspace != nil else { throw Failure.arguments }
            if let workspace = self.workspace {
                // Developer acceptance cannot open a production checkout.
                guard workspace.path.hasPrefix("/private/tmp/MimicAppleProbe-"), FileManager.default.fileExists(atPath: workspace.path) else { throw Failure.arguments }
            }
            for action in self.actions { _ = try action.command() }
            if let value = self.text { _ = try AppleSimulatorAction.text(value).command() }
            if let (x, y) = self.tap { _ = try AppleSimulatorAction.tap(x: x, y: y).command() }
        }
    }
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("MimicAppleProbe [--developer /path/Xcode.app/Contents/Developer] [--device UUID] [--tap X Y] [--text TEXT] [--swipe X Y END_X END_Y SECONDS] [--orientation VALUE] [--home] [--workspace FIXTURE_PROJECT --install]\nDefault: inspect native Xcode 27 MCP schemas. Device mode accepts only a disposable simulator named Mimic Apple Probe. Build/install only with --install on an explicit disposable fixture workspace. Never enables mcp-server or changes macOS/xcode-select. No automatic retries.")
            return
        }
        let connection = Xcode27SimulatorConnection(clientName: "Mimic Simulator Probe")
        var phase = "arguments"
        do {
            let options = try Options(arguments)
            let developer: String
            if let selected = options.developer { developer = selected }
            else {
                let detected = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]) }.value
                guard detected.0 == 0 else { throw AppleSimulatorError.unsupported }
                developer = detected.1
            }
            // Validate a disposable device before contacting a service that can boot it.
            if let device = options.device {
                var environment = ProcessInfo.processInfo.environment
                environment["DEVELOPER_DIR"] = developer
                let listing = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], environment: environment) }.value
                guard listing.0 == 0, let value = try? JSONDecoder().decode(BridgeValue.self, from: Data(listing.1.utf8)), let devices = value["devices"].object else { throw Failure.device }
                let found = devices.filter { $0.key.contains(".iOS-") }.values.flatMap { $0.array ?? [] }.first { $0["udid"].string.flatMap(UUID.init(uuidString:)) == device }
                guard found?["name"].string == "Mimic Apple Probe" else { throw Failure.device }
            }
            phase = "connect"
            try await connection.connect(developerDirectory: developer)
            var report: [String: BridgeValue] = ["status": .string("PASS"), "serverVersion": .string(connection.version), "acceptedTools": .array(connection.supportedTools.sorted().map(BridgeValue.string)), "scope": .string("tool schemas only")]
            if let device = options.device {
                if let workspace = options.workspace {
                    phase = "workspace_access"
                    try await connection.authorize(workspace: workspace)
                }
                let session = connection.session
                phase = "start_session"
                let descriptor = try await connection.startSession(deviceID: device, workspace: options.workspace)
                do {
                    phase = "install_or_capture"
                    if options.install { try await session.installAndRun(sessionID: descriptor.id) }
                    var image = try await session.capture(sessionID: descriptor.id)
                    phase = "actions"
                    if let (x, y) = options.tap { image = try await session.perform(sessionID: descriptor.id, action: .tap(x: x, y: y), observedRevision: image.revision) }
                    if let value = options.text { image = try await session.perform(sessionID: descriptor.id, action: .text(value), observedRevision: image.revision) }
                    for action in options.actions { image = try await session.perform(sessionID: descriptor.id, action: action, observedRevision: image.revision) }
                    let boundedFrame = try await SimulatorArtifactReader.read(image)
                    report["frameBytes"] = .number(Double(try JSONEncoder().encode(boundedFrame.payload).count))
                    report["widthPoints"] = .number(boundedFrame.width)
                    report["heightPoints"] = .number(boundedFrame.height)
                    report["scope"] = .string("disposable device observation and explicitly supplied actions")
                    report["deviceID"] = .string(device.uuidString)
                    report["applicationState"] = .string(image.applicationState)
                    report["screenshotPath"] = .string(image.screenshot.path)
                    report["hierarchyPath"] = .string(image.hierarchy.path)
                    phase = "close_session"
                    try await session.close(sessionID: descriptor.id)
                } catch {
                    do { try await session.close(sessionID: descriptor.id) }
                    catch { throw Failure.cleanup }
                    throw error
                }
            }
            await connection.disconnect()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(BridgeValue.object(report)), as: UTF8.self))
        } catch {
            await connection.disconnect()
            let code: String
            switch error {
            case AppleSimulatorError.unsupported: code = "requires_supported_xcode_27_and_macos_26_6_with_native_agent_access"
            case Failure.arguments: code = "invalid_arguments_use_help"
            case Failure.device: code = "device_must_be_disposable_ios_simulator_named_mimic_apple_probe"
            case Failure.cleanup: code = "session_cleanup_unconfirmed_check_apple_device_sessions"
            default: code = "native_probe_failed_no_automatic_retry"
            }
            let status = code.hasPrefix("requires_") || code == "invalid_arguments_use_help" || code.hasPrefix("device_must_") ? "NOT_RUN" : "FAIL"
            print("{\"status\":\"\(status)\",\"code\":\"\(code)\",\"phase\":\"\(phase)\",\"category\":\"\(connection.failureCategory)\"}")
            exit(2)
        }
    }
}
