// Created by Василий Маслов on 04.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

/// Explicit opt-in: Xcode is open only on the disposable fixture and the user approves its client.
@Suite(.serialized, .timeLimit(.minutes(6))) @MainActor struct BuildNativeAcceptanceTests {
    @Test func realSDKConnectionBuildAndSelectedTest() async throws {
        guard let path = ProcessInfo.processInfo.environment["MIMIC_NATIVE_FIXTURE"] else { return }
        guard path.hasPrefix("/private/tmp/MimicXcodeAcceptance-") else { throw BuildError.context }
        let project = try EnvironmentInspector.project(path: path, developerDirectory: EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1)
        let root = URL(fileURLWithPath: path).appendingPathComponent("NativeAcceptanceHistory-" + UUID().uuidString), suite = "MimicNative-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = BuildCoordinator(directory: root, helper: URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"]!), defaults: defaults)
        coordinator.currentProject = { project }
        await coordinator.xcode.connect(project: project)
        print("XCODE MCP:", coordinator.xcode.version, coordinator.xcode.message, coordinator.xcode.windows)
        #expect(coordinator.xcode.supports(.build)); #expect(coordinator.xcode.supports(.test))
        let tab = try #require(coordinator.xcode.windows.keys.first { coordinator.xcode.hasWorkspace($0, path: project.workspace) })
        for operation in [BuildOperation.build, .test] {
            let parameters = BuildParameters(operation: operation, backend: .xcodeMCP, configuration: "", testIdentifiers: operation == .test ? ["FixtureTests/FixtureTests/testValue()"] : [], workspaceTab: tab)
            let admitted = try await coordinator.submit(id: UUID(), project: project, parameters: parameters, source: "Native Acceptance", simulatorConfirmed: true)
            coordinator.start(admitted)
            for _ in 0..<1000 { if !coordinator.busy { break }; try await Task.sleep(for: .milliseconds(250)); if coordinator.active == nil { break } }
            let final = try #require(coordinator.records.last)
            print("MCP RESULT:", final.status.rawValue, String(decoding: coordinator.output(final.id), as: UTF8.self))
            #expect(final.status == .succeeded);
            guard final.status == .succeeded else { await coordinator.xcode.disconnect(); return }; #expect(final.xcodeRequestID != nil); #expect(!final.canCancel)
        }
        await coordinator.xcode.disconnect()
    }
}
