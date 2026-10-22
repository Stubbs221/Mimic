//
//  BuildCatalogueProgressTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 22.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct BuildCatalogueProgressTests {
    private let project = ProjectContext(path: "/private/tmp", branch: "fixture", commit: "one", developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcworkspace", configurationProject: "Fixture.xcodeproj"))

    @Test(arguments: [false, true]) func stagesFollowSuccessfulQueriesAndCachedMetadata(tests: Bool) throws {
        for reuse in [false, true] {
            var base = BuildCatalogue(); base.schemes = ["Fixture"]; base.configurations = ["Debug"]
            var events: [BuildCatalogueProgress] = []
            _ = try BuildCatalogue.inspect(project: project, scheme: "Fixture", includeTestPlans: tests, timeout: 120, baseCatalogue: reuse ? base : nil, progress: { events.append(.init(phase: $0, completed: $1, total: $2)) }) { args, _, _ in
                if args.contains("-showdestinations") { #expect(events.last?.phase == .destinations); return (0, "") }
                if args.contains("-showTestPlans") { #expect(events.last?.phase == .testPlans); return (0, "Test plans associated with the scheme:\n    Selected\n") }
                if args.contains("-workspace") { #expect(events.last?.completed == 0); return (0, #"{"workspace":{"schemes":["Fixture"]}}"#) }
                #expect(events.last?.completed == 1)
                return (0, #"{"project":{"configurations":["Debug"]}}"#)
            }
            let phases: [BuildCatalogueProgress.Phase] = (reuse ? [] : [.schemes, .configurations]) + [.destinations] + (tests ? [.testPlans] : []) + [.verifying]
            #expect(events.map(\.phase) == phases)
            #expect(events.map(\.completed) == Array(0..<phases.count))
            #expect(events.allSatisfy { $0.total == phases.count - 1 })
            #expect(events.last?.fraction == 1)
        }
    }

    @Test func failedStepNeverAdvancesAndProjectQueryCombinesMetadata() throws {
        var events: [BuildCatalogueProgress] = []
        #expect(throws: BuildError.catalogueResponse) {
            try BuildCatalogue.inspect(project: project, scheme: "Fixture", includeTestPlans: false, timeout: 120, progress: { events.append(.init(phase: $0, completed: $1, total: $2)) }) { args, _, _ in
                (0, args.contains("-workspace") ? #"{"workspace":{"schemes":["Fixture"]}}"# : "invalid")
            }
        }
        #expect(events.map(\.phase) == [.schemes, .configurations])
        #expect(events.last?.completed == 1 && events.last?.total == 3)
        var single = project; single.appleTarget = .init(path: "Fixture.xcodeproj")
        events = []
        _ = try BuildCatalogue.inspect(project: single, scheme: "", includeTestPlans: false, timeout: 120, progress: { events.append(.init(phase: $0, completed: $1, total: $2)) }) { _, _, _ in (0, #"{"project":{"schemes":["Fixture"],"configurations":["Debug"]}}"#) }
        #expect(events.map(\.phase) == [.metadata, .verifying])
        #expect(events.last?.completed == 1 && events.last?.total == 1)
    }

    @Test func snapshotsAreSharedAndScopedToExactRequest() async throws {
        let service = BuildDiscovery(inspect: { _, _, _ in try await Task.sleep(for: .milliseconds(200)); return BuildCatalogue() })
        async let first = service.catalogue(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "one")
        async let second = service.catalogue(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "one")
        var observed: BuildCatalogueProgress?
        for _ in 0..<100 {
            observed = await service.progress(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "one")
            if observed != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(observed != nil)
        #expect(await service.progress(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "one") == observed)
        #expect(await service.progress(project: project, scheme: "Other", profileID: "profile", profileRevision: "one") == nil)
        #expect(await service.progress(project: project, scheme: "Fixture", includeTestPlans: true, profileID: "profile", profileRevision: "one") == nil)
        #expect(await service.progress(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "two") == nil)
        _ = try await [first, second]
        #expect(await service.progress(project: project, scheme: "Fixture", profileID: "profile", profileRevision: "one") == nil)
    }
}
