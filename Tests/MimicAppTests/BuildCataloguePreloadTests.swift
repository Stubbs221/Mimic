// Created by Василий Маслов on 22.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

private actor PreloadProbe {
    var queries = 0
    func catalogue() -> BuildCatalogue {
        queries += 1
        var result = BuildCatalogue(); result.schemes = ["Fixture"]; result.configurations = ["Debug"]
        result.destinations = [.init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "iPhone", platform: .ios)]
        return result
    }
}

@Suite(.serialized) @MainActor struct BuildCataloguePreloadTests {
    @Test func buildUsesSelectedValidatorAndRejectsRemovedDeviceBeforeLaunching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "BuildSelectedValidation-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path, branch: "fixture", commit: "one", developerDirectory: "/fixture/Developer")
        let builds = BuildCoordinator(directory: root, helper: root.appendingPathComponent("unused"), defaults: defaults, inspect: { $0 }, resolveDeveloper: { _ in "/fixture/Developer" },
            makeCommand: { _, _ in Issue.record("Removed device must not launch a process"); throw BuildError.configuration },
            discover: { _, _, _, _, _ in Issue.record("Preflight must not reload the full catalogue"); throw BuildError.unavailable },
            validateSelection: { _, scheme, tests, _, _ in
                #expect(scheme == "Fixture" && !tests)
                var result = BuildCatalogue(); result.schemes = ["Fixture"]; result.configurations = ["Debug"]; return result
            })
        builds.currentProject = { project }
        defer { builds.stop() }
        let record = try await builds.submit(id: UUID(), project: project, parameters: .init(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"), source: "fixture")
        builds.start(record)
        for _ in 0..<200 { if !builds.busy { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(builds.records.last?.status == .failed)
        #expect(builds.records.last?.errorCode == "configuration")
        #expect(builds.records.last?.startedAt == nil)
    }

    @Test func latePreloadCannotReplaceNewCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "BuildPreloadContext-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let first = ProjectContext(path: root.appendingPathComponent("first").path, developerDirectory: "/fixture/Developer")
        let second = ProjectContext(path: root.appendingPathComponent("second").path, developerDirectory: "/fixture/Developer")
        var current = first
        let builds = BuildCoordinator(directory: root, helper: root.appendingPathComponent("unused"), defaults: defaults, resolveDeveloper: { _ in "/fixture/Developer" }, discover: { project, _, _, _, _ in
            try await Task.sleep(for: .milliseconds(project.path == first.path ? 120 : 20))
            var result = BuildCatalogue(); result.schemes = [URL(fileURLWithPath: project.path).lastPathComponent]; result.configurations = ["Debug"]; return result
        })
        builds.currentProject = { current }
        defer { builds.stop() }
        builds.preloadCatalogue(project: first)
        for _ in 0..<200 { if builds.loading { break }; try await Task.sleep(for: .milliseconds(2)) }
        current = second; builds.preloadCatalogue(project: second)
        try await Task.sleep(for: .milliseconds(200))
        #expect(builds.catalogue.schemes == ["second"])
        #expect(!builds.loading && builds.records.isEmpty)
    }

    @Test func startupRestoresPersistedCatalogueWithoutXcodeAndCoalescesRepeatedPreloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "BuildCataloguePreload-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let probe = PreloadProbe()
        let stamp: BuildDiscovery.Signature = { _ in .init(configuration: "config", destinations: "devices") }
        let project = ProjectContext(path: root.path, branch: "fixture", commit: "one", developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fixture.xcodeproj"), withIntermediateDirectories: true)
        let writer = BuildDiscovery(inspect: { _, _, _ in await probe.catalogue() }, cacheDirectory: root.appendingPathComponent("cache"), signature: stamp)
        _ = try await writer.catalogue(project: project, scheme: "Fixture", useCache: true)
        var draft = BuildParameters(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"); draft.platform = .ios
        defaults.set(try JSONEncoder().encode(draft), forKey: "build.configuration." + project.path + "|/fixture/Developer")
        defaults.set(try JSONEncoder().encode([project]), forKey: "projects"); defaults.set(project.path, forKey: "selectedProject")
        let reader = BuildDiscovery(inspect: { _, _, _ in Issue.record("Saved unchanged catalogue must avoid Xcode"); return await probe.catalogue() }, cacheDirectory: root.appendingPathComponent("cache"), signature: stamp)
        let builds = BuildCoordinator(directory: root, helper: root.appendingPathComponent("unused"), defaults: defaults, resolveDeveloper: { _ in "/fixture/Developer" }, discoveryService: reader)
        var simulators = SimulatorPanelServices()
        simulators.catalog = { _ in .init(devices: [], developer: "/fixture/Developer") }; simulators.inspect = { $0 }
        let model = TaskCoordinator(directory: root, simulatorServices: simulators, buildCoordinator: builds, defaults: defaults, inspectProject: { ($0, [], nil) })
        defer { model.stopAndExit() }
        for _ in 0..<200 { if builds.catalogueLoadedAt != nil && !builds.loading { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(builds.catalogue.schemes == ["Fixture"])
        #expect(builds.draft.destinationID == draft.destinationID)
        #expect(builds.draftCompatible)
        builds.preloadCatalogue(project: project); builds.preloadCatalogue(project: project)
        await builds.refreshCatalogue(project: project)
        #expect(await probe.queries == 1)
        #expect(builds.records.isEmpty)
    }
}
