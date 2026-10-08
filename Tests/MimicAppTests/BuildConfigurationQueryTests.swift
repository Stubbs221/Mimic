// Created by Василий Маслов on 07.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

private actor CatalogueGate {
    private var continuation: CheckedContinuation<BuildCatalogue, Error>?
    var started = false
    func fetch() async throws -> BuildCatalogue {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() { var catalogue = BuildCatalogue(); catalogue.schemes = ["Fixture"]; continuation?.resume(returning: catalogue); continuation = nil }
}

@Suite(.serialized) @MainActor struct BuildConfigurationQueryTests {
    @Test func pollingIsImmediateAndLateResultRejectsChangedContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicCatalogueQuery-" + UUID().uuidString)
        let suite = "MimicCatalogueQuery-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.stopAndExit() }
        let gate = CatalogueGate(), discovery = BuildDiscovery(inspect: { _, _, _ in try await gate.fetch() })
        let integration = MimicIntegration(model: model, defaults: defaults, discovery: discovery)
        var project = ProjectContext(path: root.path, branch: "main", commit: "one", developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
        model.projects = [project]; model.selectedProjectPath = project.path
        let context = MimicIntegration.context(project)
        let start = try await integration.buildRequest(.init(method: "start_build_configuration", parameters: ["context": context, "scheme": .string("Fixture"), "includeTestPlans": .bool(false)]))
        let query = try #require(start["queryID"].string)
        let poll = MimicBridgeRequest(method: "get_build_configuration_state", parameters: ["queryID": .string(query)])
        #expect(try await integration.buildRequest(poll)["status"] == .string("pending"))
        for _ in 0..<100 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(2)) }
        await gate.finish()
        var ready = BridgeValue.null
        for _ in 0..<100 {
            ready = try await integration.buildRequest(poll)
            if ready["status"] == .string("ready") { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(ready["result"]["context"] == context)
        #expect(ready["result"]["cli"]["schemes"] == .array([.string("Fixture")]))
        project.commit = "two"; model.projects = [project]
        await #expect(throws: MimicIntegration.IntegrationError.self) { try await integration.buildRequest(poll) }
        await #expect(throws: BuildError.notFound) {
            try await integration.buildRequest(.init(method: "get_build_configuration_state", parameters: ["queryID": .string(query)], threadID: "another-chat"))
        }
    }
}
