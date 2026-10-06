// Created by Василий Маслов on 04.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

/// Opt-in smoke against a generated simulator-only workspace, never the working ios3 checkout.
@Suite(.serialized, .timeLimit(.minutes(10))) @MainActor struct BuildLiveAcceptanceTests {
    @Test func buildFailureAndOneExplicitTestOnIsolatedProject() async throws {
        guard let path = ProcessInfo.processInfo.environment["MIMIC_BUILD_FIXTURE"], let destination = ProcessInfo.processInfo.environment["MIMIC_BUILD_DESTINATION"] else { return }
        #expect(path.hasPrefix("/private/tmp/MimicXcodeAcceptance-")); guard path.hasPrefix("/private/tmp/MimicXcodeAcceptance-") else { return }
        let developer = EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
        let project = try EnvironmentInspector.project(path: path, developerDirectory: developer, appleTarget: AppleTarget(path: "App/App.xcworkspace", configurationProject: "App/App.xcodeproj"))
        let root = URL(fileURLWithPath: path).appendingPathComponent("AcceptanceHistory")
        let suite = "MimicLiveAcceptance-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = BuildCoordinator(directory: root, helper: URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"]!), defaults: defaults)
        coordinator.currentProject = { project }
        let parameters = BuildParameters(scheme: "Fixture", destinationID: destination)
        let catalogue = try await Task.detached { try BuildCatalogue.inspect(project: project, scheme: "Fixture") }.value
        try catalogue.validate(parameters)
        func execute(_ parameters: BuildParameters) async throws -> BuildActivity {
            let admitted = try await coordinator.submit(id: UUID(), project: project, parameters: parameters, source: "Acceptance")
            coordinator.start(admitted)
            for _ in 0..<1200 {
                if !coordinator.busy { return try #require(coordinator.records.last) }
                try await Task.sleep(for: .milliseconds(250))
            }
            coordinator.cancel(admitted.id); throw BuildError.unavailable
        }
        let success = try await execute(parameters); #expect(success.status == .succeeded); #expect(success.exitCode == 0)
        let source = URL(fileURLWithPath: path).appendingPathComponent("App/Value.swift")
        let original = try Data(contentsOf: source)
        try Data((String(decoding: original, as: UTF8.self) + "\nlet intentionalMimicCompilerError: Int = \"error\"\n").utf8).write(to: source)
        let failure = try await execute(parameters); #expect(failure.status == .failed); #expect(failure.exitCode != 0)
        try original.write(to: source)
        var tests = parameters; tests.operation = .test; tests.testIdentifiers = ["FixtureTests/FixtureTests/testValue"]
        let tested = try await execute(tests); #expect(tested.status == .succeeded); #expect(tested.resultBundlePath != nil)
        #expect(coordinator.records.count == 3)
    }
}
