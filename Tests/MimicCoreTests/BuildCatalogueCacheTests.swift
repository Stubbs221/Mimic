// Created by Василий Маслов on 22.10.2026.
import Foundation
import Testing
@testable import MimicCore

private actor CatalogueCacheProbe {
    var fullQueries = 0
    var selectedQueries = 0
    var configuration = "one"
    var devices = "one"
    var rejectDestination = false
    func signature() -> BuildCatalogueSignature { .init(configuration: configuration, destinations: devices) }
    func changeConfiguration() { configuration = "two" }
    func changeDevices() { devices = "two" }
    func removeDestination() { rejectDestination = true }
    func catalogue() -> BuildCatalogue {
        var value = BuildCatalogue(); value.schemes = ["Fixture"]; value.configurations = ["Debug"]
        value.destinations = [.init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "iPhone", platform: .ios)]
        return value
    }
    func full() -> BuildCatalogue { fullQueries += 1; return catalogue() }
    func selected(_ base: BuildCatalogue) -> BuildCatalogue {
        selectedQueries += 1; var value = base
        if rejectDestination { value.destinations = [] }
        return value
    }
}

struct BuildCatalogueCacheTests {
    private let project = ProjectContext(path: "/private/tmp", branch: "main", commit: "one", developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
    private func service(_ probe: CatalogueCacheProbe, directory: URL? = nil) -> BuildDiscovery {
        BuildDiscovery(inspect: { _, _, _ in await probe.full() }, cacheDirectory: directory, signature: { _ in await probe.signature() }, inspectSelection: { _, _, _, base in await probe.selected(base) })
    }

    @Test func savedCatalogueSurvivesRestartAndSourceCommitWithoutDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = CatalogueCacheProbe(), first = service(probe, directory: root)
        _ = try await first.catalogue(project: project, scheme: "Fixture", useCache: true)
        let restarted = service(probe, directory: root)
        var changed = project; changed.commit = "source-only"; changed.branch = "feature"
        let saved = await restarted.cachedCatalogue(project: changed, scheme: "Fixture")
        #expect(saved?.value.schemes == ["Fixture"])
        _ = try await restarted.catalogue(project: changed, scheme: "Fixture", useCache: true)
        #expect(await probe.fullQueries == 1)
        await probe.changeConfiguration()
        _ = try await restarted.catalogue(project: changed, scheme: "Fixture", useCache: true)
        #expect(await probe.fullQueries == 2)
    }

    @Test func preflightAlwaysChecksSelectedDestinationWithoutReloadingSchemes() async throws {
        let probe = CatalogueCacheProbe(), service = service(probe)
        _ = try await service.catalogue(project: project, scheme: "", useCache: true)
        var parameters = BuildParameters(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"); parameters.platform = .ios
        let ready = try await service.selectionCatalogue(project: project, scheme: "Fixture")
        try ready.validate(parameters)
        await probe.removeDestination(); await probe.changeDevices()
        let removed = try await service.selectionCatalogue(project: project, scheme: "Fixture")
        #expect(throws: BuildError.configuration) { try removed.validate(parameters) }
        #expect(await probe.fullQueries == 1)
        #expect(await probe.selectedQueries == 2)
    }

    @Test func manualRefreshAndProfileChangesCannotReuseSavedEntries() async throws {
        let probe = CatalogueCacheProbe(), service = service(probe)
        _ = try await service.catalogue(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "one", useCache: true)
        await service.invalidate(project: project, profileID: "profile", profileRevision: "one")
        #expect(await service.cachedCatalogue(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "one") == nil)
        _ = try await service.catalogue(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "one", useCache: true)
        _ = try await service.catalogue(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "two", useCache: true)
        #expect(await probe.fullQueries == 3)
    }

    @Test func corruptSavedCacheIsRebuiltAndCapacityStaysBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("catalogue.json"))
        let probe = CatalogueCacheProbe(), service = service(probe, directory: root)
        for index in 0..<10 { _ = try await service.catalogue(project: project, scheme: String(index), useCache: true) }
        #expect(await service.cachedCatalogue(project: project, scheme: "0") == nil)
        let restarted = self.service(probe, directory: root)
        #expect(await restarted.cachedCatalogue(project: project, scheme: "9")?.value.schemes == ["Fixture"])
        #expect(await restarted.cachedCatalogue(project: project, scheme: "0") == nil)
    }

    @Test func selectedInspectionUsesOnlyDestinationsAndOptInPlans() throws {
        var base = BuildCatalogue(); base.schemes = ["Fixture"]; base.configurations = ["Debug"]
        for tests in [false, true] {
            var calls: [[String]] = []
            let value = try BuildCatalogue.inspect(project: project, scheme: "Fixture", includeTestPlans: tests, timeout: 120, baseCatalogue: base) { arguments, _, _ in
                calls.append(arguments)
                if arguments.contains("-showTestPlans") { return (0, "Test plans associated with the scheme:\n    Selected\n") }
                return (0, "{ platform:iOS Simulator, id:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA, name:iPhone }")
            }
            #expect(!calls.contains { $0.contains("-list") })
            #expect(calls.count == (tests ? 2 : 1))
            #expect(value.destinations.count == 1)
        }
        #expect(throws: BuildError.configuration) {
            try BuildCatalogue.inspect(project: project, scheme: "Deleted", includeTestPlans: false, timeout: 120, baseCatalogue: base) { _, _, _ in Issue.record("Invalid scheme must not launch Xcode"); return (0, "") }
        }
    }

    @Test func metadataChangedDuringDiscoveryIsNeverSavedAsCurrent() async throws {
        let probe = CatalogueCacheProbe()
        let service = BuildDiscovery(inspect: { _, _, _ in await probe.changeConfiguration(); return await probe.full() }, signature: { _ in await probe.signature() })
        await #expect(throws: BuildError.context) { try await service.catalogue(project: project, scheme: "Fixture", useCache: true) }
        #expect(await service.cachedCatalogue(project: project, scheme: "Fixture") == nil)
    }

    @Test func shutdownCancelsSharedPendingDiscovery() async throws {
        let service = BuildDiscovery(inspect: { _, _, _ in try await Task.sleep(for: .seconds(30)); return BuildCatalogue() })
        let pending = Task { try await service.catalogue(project: project, scheme: "Fixture") }
        try await Task.sleep(for: .milliseconds(30))
        await service.stop()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await service.cachedCatalogue(project: project, scheme: "Fixture") == nil)
        await #expect(throws: CancellationError.self) { try await service.catalogue(project: project, scheme: "Fixture", useCache: true) }
    }
}
