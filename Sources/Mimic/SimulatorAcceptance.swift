//
//  SimulatorAcceptance.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
#if DEBUG
import Foundation
import MimicCore

/// Developer-only, disposable acceptance through the real native owner and facade. No user checkout is accepted.
@MainActor enum SimulatorAcceptance {
    static func run() async {
        var owner: SimulatorCoordinator?
        let suite = "MimicSimulatorAcceptance-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { print("{\"status\":\"FAIL\",\"phase\":\"defaults\"}"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        var phase = "arguments"
        var report = ""
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 8, arguments[1] == "--simulator-acceptance", arguments[3] == "--device", arguments[5] == "--developer", arguments[7] == "--fixture-only", let device = UUID(uuidString: arguments[4]) else { throw AppleSimulatorError.arguments }
            phase = "fixture_root"
            let root = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath()
            guard root.deletingLastPathComponent() == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath(), root.lastPathComponent.hasPrefix("MimicAppleProbe-") else { throw AppleSimulatorError.arguments }
            phase = "fixture_context"
            let project = try EnvironmentInspector.project(path: root.path, developerDirectory: arguments[6])
            let model = TaskCoordinator(directory: root.appendingPathComponent("MimicAcceptance"), defaults: defaults)
            model.projects = [project]; model.selectedProjectPath = project.path
            owner = model.simulatorScreen
            let facade = MimicIntegration(model: model, defaults: defaults)
            let context = MimicIntegration.context(project)
            func call(_ name: String, _ p: [String: BridgeValue]) async throws -> BridgeValue { try await facade.handle(.init(method: name, parameters: p)) }
            func wait(_ activity: BridgeValue) async throws {
                let id = try require(activity["id"].string)
                for _ in 0..<1800 {
                    let value = try await call("get_simulator_activity", ["activityID": .string(id)])
                    let status = value["activity"]["status"].string
                    if status == "succeeded" { return }
                    guard ["queued", "preparing", "running"].contains(status ?? "") else { throw AppleSimulatorError.connectionLost }
                    try await Task.sleep(for: .seconds(1))
                }
                throw AppleSimulatorError.connectionLost
            }
            phase = "catalogue"
            let configuration = try await call("get_simulator_configuration", ["context": context])
            guard configuration["devices"].array?.contains(where: { $0["id"].string == device.uuidString && $0["name"].string == "Mimic Apple Probe" }) == true else { throw AppleSimulatorError.wrongDevice }
            var barrier = TaskRecord(action: .format, project: project); barrier.status = .running; model.records = [barrier]
            phase = "queued_start"
            let startID = UUID()
            let start = try await call("start_simulator_session", ["context": context, "requestID": .string(startID.uuidString), "deviceID": .string(device.uuidString)])
            guard start["status"].string == "queued", owner?.descriptor == nil else { throw AppleSimulatorError.invalidResponse }
            model.records = []; owner?.schedule()
            phase = "start"
            try await wait(start)
            let id = try require(owner?.descriptor?.id.uuidString)
            phase = "install"
            try await wait(call("install_simulator_app", ["context": context, "requestID": .string(UUID().uuidString), "sessionID": .string(id)]))
            phase = "refresh_after_install"
            try await Task.sleep(for: .seconds(2))
            try await wait(call("refresh_simulator_screen", ["context": context, "requestID": .string(UUID().uuidString), "sessionID": .string(id)]))
            phase = "private_observation"
            let image = try await call("simulator_ui_observe", ["sessionID": .string(id)])
            phase = "frame_geometry"
            guard image["width"].integer != nil, image["height"].integer != nil else { throw AppleSimulatorError.invalidResponse }
            phase = "frame_size"
            guard try JSONEncoder().encode(image).count < MimicSocket.maximumBytes else { throw AppleSimulatorError.invalidResponse }
            phase = "frame_hierarchy"
            let hierarchy = try require(image["hierarchy"].string)
            let regex = try NSRegularExpression(pattern: #"identifier: 'probe.increment'.*hitPoint: \{([0-9.]+), ([0-9.]+)\}"#)
            let ns = hierarchy as NSString
            guard let match = regex.firstMatch(in: hierarchy, range: NSRange(location: 0, length: ns.length)), let x = Double(ns.substring(with: match.range(at: 1))), let y = Double(ns.substring(with: match.range(at: 2))) else { throw AppleSimulatorError.invalidResponse }
            phase = "counter_tap"
            let tapID = UUID(), tapParameters: [String: BridgeValue] = ["context": context, "requestID": .string(tapID.uuidString), "sessionID": .string(id), "revision": image["revision"], "action": .object(["type": .string("tap"), "x": .number(x), "y": .number(y)])]
            try await wait(call("perform_simulator_action", tapParameters))
            _ = try await call("perform_simulator_action", tapParameters)
            let after = try await call("simulator_ui_observe", ["sessionID": .string(id)])
            guard after["hierarchy"].string?.contains("Счётчик: 1") == true else { throw AppleSimulatorError.invalidResponse }
            phase = "metadata_privacy"
            let state = try await call("get_state", [:]), stateData = try JSONEncoder().encode(state)
            let serialized = String(decoding: stateData, as: UTF8.self)
            guard !serialized.contains("screenshot"), !serialized.contains("hierarchy"), !serialized.contains("interactionSessionKey"), !serialized.contains("image/jpeg") else { throw AppleSimulatorError.invalidResponse }
            phase = "close"
            try await wait(call("close_simulator_session", ["context": context, "requestID": .string(UUID().uuidString), "sessionID": .string(id)]))
            guard owner?.descriptor == nil else { throw AppleSimulatorError.invalidResponse }
            report = "{\"status\":\"PASS\",\"scope\":\"native Mac owner, facade, FIFO, install, counter tap, duplicate, private bounded image, metadata, close\",\"frameBytes\":\(try JSONEncoder().encode(after).count),\"widthPoints\":\(after["width"].integer ?? 0),\"heightPoints\":\(after["height"].integer ?? 0)}"
        } catch { report = "{\"status\":\"FAIL\",\"phase\":\"\(phase)\",\"category\":\"\(error is AppleSimulatorError ? String(describing: error) : "facade")\"}" }
        owner?.stop()
        while owner?.canExit == false { try? await Task.sleep(for: .milliseconds(20)) }
        print(report)
    }
    private static func require<T>(_ value: T?) throws -> T { guard let value else { throw AppleSimulatorError.invalidResponse }; return value }
}
#endif
