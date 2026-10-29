//
//  BuildResourceTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct BuildResourceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_BUILD_RESOURCE_PROFILE"] != nil))
    func updatedTeamProfileImportsWithoutExecutingRecovery() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = try #require(ProcessInfo.processInfo.environment["MIMIC_BUILD_RESOURCE_PROFILE"])
        let snapshot = try ProfileStore(directory: root.appendingPathComponent("Profiles")).importArchive(URL(fileURLWithPath: path), requireInterface: true)
        let requirements = try #require(snapshot.profile.buildResources)
        #expect(!requirements.isEmpty)
        for requirement in requirements {
            #expect(snapshot.profile.actions.contains { $0.id == requirement.recoveryActionID && $0.presentation == .regular && $0.remote == nil })
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Generated").path))
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildResources-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func requirement(version: Bool = false) -> BuildResourceRequirement {
        .init(id: "assets", title: "Assets", platform: .ios, paths: ["Generated/Images", "Generated/Animations"],
              version: version ? .init(configurationFile: "config.yml", key: "version", repository: "Generated", tagPrefix: "ios_") : nil, recoveryActionID: "restore")
    }
    private func inspect(_ requirement: BuildResourceRequirement, _ root: URL, platform: BootstrapPlatform = .ios) -> BuildResourceState {
        BuildResourceInspector.inspect([requirement], project: .init(path: root.path), platform: platform)
    }
    @Test func absentAndEmptyResourcesBlockOnlyTheirPlatform() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let requirement = requirement()
        #expect(inspect(requirement, root).blocker?.status == .missing)
        #expect(!inspect(requirement, root, platform: .tvos).blocking)
        for path in requirement.paths { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        #expect(inspect(requirement, root).blocking)
        for path in requirement.paths { try Data("resource".utf8).write(to: root.appendingPathComponent(path + "/asset")) }
        #expect(!inspect(requirement, root).blocking)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
    }
    @Test func localTagAndConfigurationSelectVersionWithoutFetching() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let requirement = requirement(version: true), generated = root.appendingPathComponent("Generated")
        try Data("version: 1.2.3\n".utf8).write(to: root.appendingPathComponent("config.yml"))
        #expect(inspect(requirement, root).blocker?.expectedVersion == "1.2.3")
        for path in requirement.paths { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true); try Data("asset".utf8).write(to: root.appendingPathComponent(path + "/file")) }
        for arguments in [["init", "-b", "main"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Resources"], ["tag", "ios_1.2.3"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", arguments, directory: generated.path).0 == 0)
        }
        #expect(!inspect(requirement, root).blocking)
        try Data("version: '1.2.4' # new branch\n".utf8).write(to: root.appendingPathComponent("config.yml"))
        #expect(inspect(requirement, root).blocker?.status == .stale)
        try Data("local edit".utf8).write(to: generated.appendingPathComponent("Images/file"))
        #expect(inspect(requirement, root).blocker?.status == .modified)
        #expect(inspect(requirement, root).blocker?.canRecover == false)
    }
    @Test func ambiguousConfigurationAndEscapingSymlinksRemainUnknown() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for content in ["version: 1\nversion: 2\n", "version: $(anything)\n", String(repeating: "x", count: 65 * 1024)] {
            try Data(content.utf8).write(to: root.appendingPathComponent("config.yml"))
            #expect(inspect(requirement(version: true), root).blocker?.status == .unknown)
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Generated").path, withDestinationPath: "/private/tmp")
        #expect(inspect(requirement(), root).blocker?.status == .unknown)
    }
    @Test func recoveryMustReferenceLocalRegularActionAndConfinedPaths() throws {
        let json = #"{"schemaVersion":1,"id":"fixture","version":"1","title":"Fixture","requiredFiles":[],"actions":[{"id":"restore","title":"Restore","presentation":"regular","parameters":[],"logPolicy":"boundedSanitized","requiresXcodeQuit":false,"requiredFiles":[],"requiredTools":[],"steps":[{"executable":"/usr/bin/true","arguments":[],"directory":"${checkout}"}]}]}"#
        var profile = try JSONDecoder().decode(MimicProfile.self, from: Data(json.utf8)); profile.buildResources = [requirement()]
        try ProfileValidation.validate(profile, files: [])
        profile.buildResources = [.init(id: "bad", title: "Bad", platform: .ios, paths: ["../outside"], recoveryActionID: "restore")]
        #expect(throws: ProfileError.action) { try ProfileValidation.validate(profile, files: []) }
        profile.buildResources = [.init(id: "bad", title: "Bad", platform: .ios, paths: ["Generated"], recoveryActionID: "missing")]
        #expect(throws: ProfileError.action) { try ProfileValidation.validate(profile, files: []) }
    }
}
