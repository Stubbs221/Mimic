// Created by Василий Маслов on 07.10.2026.
import Foundation
import Testing
@testable import MimicCore

private actor DiscoveryProbe {
    var calls = 0
    func run(_ project: ProjectContext, _ scheme: String, _ tests: Bool) async throws -> BuildCatalogue {
        calls += 1
        try await Task.sleep(for: .milliseconds(80))
        var value = BuildCatalogue(); value.schemes = [scheme]; return value
    }
}

struct BuildDiscoveryTests {
    private let project = ProjectContext(path: "/private/tmp", branch: "fixture", commit: "one", developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))

    @Test func identicalSubscribersShareWorkButChangedContextDoesNot() async throws {
        let probe = DiscoveryProbe(), service = BuildDiscovery(inspect: { try await probe.run($0, $1, $2) })
        async let first = service.catalogue(project: project, scheme: "Fixture")
        async let second = service.catalogue(project: project, scheme: "Fixture")
        let values = try await [first, second]
        #expect(values.allSatisfy { $0.schemes == ["Fixture"] })
        #expect(await probe.calls == 1)
        var changed = project; changed.commit = "two"
        async let third = service.catalogue(project: changed, scheme: "Fixture")
        async let fourth = service.catalogue(project: project, scheme: "Fixture", includeTestPlans: true)
        _ = try await [third, fourth]
        #expect(await probe.calls == 3)
        async let oldProfile = service.catalogue(project: project, scheme: "Fixture", profileID: "apple", profileRevision: "one")
        async let newProfile = service.catalogue(project: project, scheme: "Fixture", profileID: "apple", profileRevision: "two")
        _ = try await [oldProfile, newProfile]
        #expect(await probe.calls == 5)
    }

    @Test func errorsAreDistinctAndTestPlansAreOptIn() throws {
        for code: Int32 in [ReadOnlyProcess.timeoutExitCode, 65, 0] {
            let expected: BuildError = code == ReadOnlyProcess.timeoutExitCode ? .catalogueTimeout : code == 65 ? .catalogueProcess : .catalogueResponse
            #expect(throws: expected) {
                try BuildCatalogue.inspect(project: project, scheme: "Fixture", includeTestPlans: false, timeout: 120) { _, _, _ in (code, "invalid") }
            }
        }
        for tests in [false, true] {
            var calls: [[String]] = []
            let value = try BuildCatalogue.inspect(project: project, scheme: "Fixture", includeTestPlans: tests, timeout: 120) { args, env, remaining in
                calls.append(args); #expect(remaining > 110 && remaining <= 120)
                #expect(env["DEVELOPER_DIR"] == project.developerDirectory)
                if args.contains("-showdestinations") { return (0, "") }
                if args.contains("-showTestPlans") { return (0, "Test plans associated with the scheme:\n    Selected\n") }
                return (0, #"{"project":{"schemes":["Fixture"],"configurations":["Debug"]}}"#)
            }
            #expect(calls.contains { $0.contains("-showTestPlans") } == tests)
            #expect(value.testPlans == (tests ? ["Selected"] : []))
        }
    }

    @Test func wholeCatalogueHasOneDeadline() throws {
        var count = 0
        #expect(throws: BuildError.catalogueTimeout) {
            try BuildCatalogue.inspect(project: project, scheme: "Fixture", includeTestPlans: false, timeout: 0.06) { _, _, remaining in
                count += 1
                _ = ReadOnlyProcess.capture("/bin/sleep", ["0.04"], directory: nil, environment: nil, timeout: remaining)
                return (0, #"{"project":{"schemes":["Fixture"],"configurations":["Debug"]}}"#)
            }
        }
        #expect(count == 2)
    }

    /// Real child-process waits cross both former bridge thresholds without using Xcode or building a user project.
    @Test(arguments: [8.2, 30.2]) func slowSuccessfulQueriesKeepCatalogueBudget(seconds: Double) throws {
        var calls = 0
        let value = try BuildCatalogue.inspect(project: project, scheme: "", includeTestPlans: false, timeout: 120) { _, _, remaining in
            calls += 1
            if calls == 1 {
                let result = ReadOnlyProcess.capture("/bin/sleep", [String(seconds)], directory: nil, environment: nil, timeout: remaining)
                #expect(result.0 == 0)
            }
            return (0, #"{"project":{"schemes":["Fixture"],"configurations":["Debug"]}}"#)
        }
        #expect(value.schemes == ["Fixture"] && calls == 2)
    }
}
