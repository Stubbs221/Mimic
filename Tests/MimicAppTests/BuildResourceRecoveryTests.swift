//
//  BuildResourceRecoveryTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation
import Testing
import ZIPFoundation
import MimicCore
@testable import Mimic

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct BuildResourceRecoveryTests {
    @MainActor private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let project: ProjectContext
        let model: TaskCoordinator
        let builds: BuildCoordinator
        let snapshot: ProfileSnapshot
        var parameters: BuildParameters { .init(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", platform: .ios) }

        init(mode: String = "success") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ResourceRecovery-" + UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Fixture.xcodeproj"), withIntermediateDirectories: true)
            for args in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Disposable fixture"]] {
                #expect(EnvironmentInspector.capture("/usr/bin/git", args, directory: root.path).0 == 0)
            }
            project = try EnvironmentInspector.project(path: root.path, developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
            var manifest = try #require(JSONSerialization.jsonObject(with: Profile11Fixture.data()) as? [String: Any])
            var actions = try #require(manifest["actions"] as? [[String: Any]])
            actions.append(["id": "restore-resources", "title": "Restore fixture resources", "presentation": "regular", "mcpAllowed": true, "logPolicy": "boundedSanitized", "requiresXcodeQuit": false, "requiredFiles": [], "requiredTools": [], "parameters": [],
                            "steps": [["executable": "/bin/bash", "arguments": ["${profile}/adapters/restore.sh", "${checkout}", mode], "directory": "${checkout}"]]])
            manifest["actions"] = actions
            let requirements = [BuildResourceRequirement(id: "assets", title: "Assets", platform: .ios, paths: ["Generated/asset.txt"], recoveryActionID: "restore-resources")]
            manifest["buildResources"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requirements))
            let bytes = try JSONSerialization.data(withJSONObject: manifest)
            let adapter = Data("""
            # Created by Василий Маслов on 27.10.2026.
            if [ "$2" = 'slow' ]; then sleep 30; fi
            if [ "$2" != 'noop' ]; then
                mkdir -p "$1/Generated"
                printf 'restored' > "$1/Generated/asset.txt"
            fi
            """.utf8)
            let archiveURL = root.appendingPathComponent("fixture.mimicprofile"), archive = try Archive(url: archiveURL, accessMode: .create)
            for (path, data) in [("profile.json", bytes), ("adapters/restore.sh", adapter)] {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { offset, size in data.subdata(in: Int(offset)..<Int(offset) + size) })
            }
            let storage = root.appendingPathComponent("Storage")
            snapshot = try ProfileStore(directory: storage.appendingPathComponent("Profiles")).importArchive(archiveURL, requireInterface: true)
            suite = "ResourceRecovery-" + UUID().uuidString; defaults = try #require(UserDefaults(suiteName: suite))
            let checkout = root
            let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
            builds = BuildCoordinator(directory: storage, helper: helper, defaults: defaults, inspect: { $0 }, resolveDeveloper: { _ in "/fixture/Developer" }, makeCommand: { _, _ in
                try Data("compiler invoked".utf8).write(to: checkout.appendingPathComponent("compiler-marker"))
                return .init(executable: "/usr/bin/true", arguments: [], directory: checkout.path, environment: ["PATH": "/usr/bin:/bin"])
            }, discover: { _, _, _, _, _ in
                var catalog = BuildCatalogue(); catalog.schemes = ["Fixture"]; catalog.configurations = ["Debug"]
                catalog.destinations = [.init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Fixture", platform: .ios)]; return catalog
            })
            model = TaskCoordinator(directory: storage, helperURL: helper, buildCoordinator: builds, defaults: defaults)
            model.projects = [project]; model.selectedProjectPath = project.path; model.aiUsage.stop()
        }
        func wait(_ id: UUID) async throws -> TaskRecord {
            for _ in 0..<1000 {
                if let record = model.records.first(where: { $0.id == id }), ![.queued, .running].contains(record.status), !model.agentMetadataPending.contains(id) { return record }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw BuildError.unavailable
        }
        func cleanup() { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }

    @Test func readinessAndAdmissionBlockMissingResourcesWithoutLaunchingCompiler() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(try await f.model.refreshBuildResources(project: f.project, platform: .ios).blocking)
        await #expect(throws: BuildError.resourcesRequired) { try await f.builds.submit(id: UUID(), project: f.project, parameters: f.parameters, source: "Fixture") }
        let bridge = MimicIntegration(model: f.model, defaults: f.defaults)
        var fields = try #require(BridgeValue.encode(f.parameters).object); fields["operation"] = nil; fields["intent"] = nil
        let response = try await bridge.buildRequest(.init(method: "get_build_readiness", parameters: ["context": MimicIntegration.context(f.project, profile: f.snapshot), "operation": .string("build"), "parameters": .object(fields), "simulatorConfirmed": .bool(false)]))
        #expect(response["status"] == .string("blocked"))
        #expect(response["resources"]["nextStep"]["actionID"] == .string("restore-resources"))
        #expect(f.builds.records.isEmpty && f.model.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("compiler-marker").path))
    }

    @Test func explicitRecoveryUsesOneQueuedActionAndNeverAutomaticallyBuilds() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = UUID()
        async let first = f.model.restoreBuildResources(project: f.project, platform: .ios, resourceID: "assets", requestID: id)
        async let second = f.model.restoreBuildResources(project: f.project, platform: .ios, resourceID: "assets", requestID: id)
        let values = try await [first, second]
        #expect(values == [id, id])
        #expect(try await f.wait(id).status == .succeeded)
        #expect(f.model.records.count == 1 && f.builds.records.isEmpty)
        #expect(try await !f.model.refreshBuildResources(project: f.project, platform: .ios).blocking)
        #expect(try await f.model.restoreBuildResources(project: f.project, platform: .ios, resourceID: "assets", requestID: id) == id)
    }

    @Test func zeroExitWithoutResourcesIsRecordedAsFailed() async throws {
        let f = try Fixture(mode: "noop"); defer { f.cleanup() }
        let id = try await f.model.restoreBuildResources(project: f.project, platform: .ios, resourceID: "assets", requestID: UUID())
        let result = try await f.wait(id)
        #expect(result.exitCode == 0 && result.status == .failed)
        #expect(result.error == text("build.resources.verificationFailed"))
        #expect(f.model.cachedBuildResources(project: f.project, platform: .ios).blocking)
    }

    @Test func cancellationStopsRecoveryAndLeavesBuildBlocked() async throws {
        let f = try Fixture(mode: "slow"); defer { f.cleanup() }
        let id = try await f.model.restoreBuildResources(project: f.project, platform: .ios, resourceID: "assets", requestID: UUID())
        for _ in 0..<200 { if f.model.records.first(where: { $0.id == id })?.status == .running { break }; try await Task.sleep(for: .milliseconds(10)) }
        f.model.cancel(id: id)
        #expect(try await f.wait(id).status == .cancelled)
        #expect(f.model.cachedBuildResources(project: f.project, platform: .ios).blocking)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Generated/asset.txt").path))
    }

    @Test func queuedBuildRechecksResourcesBeforeAnyCompilerCommand() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.model.restoreBuildResources(project: f.project, platform: .ios, resourceID: "assets", requestID: UUID())
        _ = try await f.wait(id)
        f.builds.schedule = {}
        let build = try await f.builds.submit(id: UUID(), project: f.project, parameters: f.parameters, source: "Fixture")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Generated/asset.txt"))
        f.builds.start(build)
        for _ in 0..<300 { if f.builds.activity(build.id)?.status == .failed { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.builds.activity(build.id)?.errorCode == "resourcesRequired")
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("compiler-marker").path))
    }

    @Test func queuedBuildCannotBypassRequirementsByChangingProfile() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.model.restoreBuildResources(project: f.project, platform: .ios, resourceID: "assets", requestID: UUID())
        _ = try await f.wait(id)
        f.builds.schedule = {}
        let build = try await f.builds.submit(id: UUID(), project: f.project, parameters: f.parameters, source: "Fixture")
        f.model.activeProfile = nil
        f.builds.start(build)
        for _ in 0..<300 { if f.builds.activity(build.id)?.status == .failed { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.builds.activity(build.id)?.errorCode == "context")
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("compiler-marker").path))
    }
}
