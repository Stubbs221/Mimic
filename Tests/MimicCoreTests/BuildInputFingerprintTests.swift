//
//  BuildInputFingerprintTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct BuildInputFingerprintTests {
    @Test func sameContentsAcrossSHAReuseOnlyWithoutDeclaredGitDependency() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("BuildInput-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(EnvironmentInspector.capture("/usr/bin/git", ["init"], directory: root.path).0 == 0)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("Source.swift"))
        var project = ProjectContext(path: root.path, branch: "main", commit: "one", developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
        let parameters = BuildParameters(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        func capture(_ policy: CatalogueReusePolicy = .init(complete: true), settings: String = "flags", toolchain: String = "xcode", runtime: String = "runtime") throws -> BuildInputFingerprint {
            try .capture(project: project, parameters: parameters, profile: nil, policy: policy, settings: settings, toolchain: toolchain, runtime: runtime)
        }
        let before = try capture(), gitBefore = try capture(.init(complete: true, gitDependencies: ["HEAD"]))
        project.commit = "two"
        #expect(try capture() == before)
        #expect(try capture(.init(complete: true, gitDependencies: ["HEAD"])) != gitBefore)
        #expect(try capture(settings: "different") != before)
        #expect(try capture(toolchain: "different") != before)
        #expect(try capture(runtime: "different") != before)
        #expect(throws: BuildError.sourceUnavailable) { try capture(.init(complete: false)) }
        try Data("changed".utf8).write(to: root.appendingPathComponent("Source.swift"))
        #expect(try capture() != before)
    }
    @Test func ignoredInputsAndMissingResourcesInvalidateReuse() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(EnvironmentInspector.capture("/usr/bin/git", ["init"], directory: root.path).0 == 0)
        try Data("generated.txt\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("one".utf8).write(to: root.appendingPathComponent("generated.txt"))
        let project = ProjectContext(path: root.path, developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
        func capture() throws -> BuildInputFingerprint { try .capture(project: project, parameters: .init(), profile: nil, policy: .init(complete: true, inputPaths: ["generated.txt"]), settings: "flags", toolchain: "xcode", runtime: "runtime") }
        let first = try capture()
        try Data("two".utf8).write(to: root.appendingPathComponent("generated.txt")); #expect(try capture() != first)
        try FileManager.default.removeItem(at: root.appendingPathComponent("generated.txt"))
        #expect(throws: BuildError.sourceUnavailable) { try capture() }
    }
}
