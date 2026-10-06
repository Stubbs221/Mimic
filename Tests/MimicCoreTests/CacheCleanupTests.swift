//
//  CacheCleanupTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 03.10.2026.
import Foundation
import Testing
@testable import MimicCore

private struct CleanupFixture {
    let root: URL
    let home: URL
    let checkout: URL
    let targets = ["Library/org.swift.swiftpm", "Library/Caches/org.swift.swiftpm", "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/SourcePackages"]

    init(bootstrapExit: Int = 0) throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicCleanup-" + UUID().uuidString)
        self.home = self.root.appendingPathComponent("home ' $fixture")
        self.checkout = self.root.appendingPathComponent("checkout ' $fixture")
        try FileManager.default.createDirectory(at: self.checkout, withIntermediateDirectories: true)
        for path in self.targets + self.targets.map({ $0 + "-keep" }) {
            let directory = self.home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: directory.appendingPathComponent("marker"))
        }
        try Data("printf 'bootstrap:%s\\n' \"$#\" >> events\nexit \(bootstrapExit)\n".utf8).write(to: self.checkout.appendingPathComponent("bootstrap.sh"))
        try Data("printf 'login:%s\\n' \"$*\" >> events\n".utf8).write(to: self.checkout.appendingPathComponent("utils.sh"))
    }

    func run(_ action: MimicAction) throws -> (Int32, String) {
        let command = try CommandSpec.make(action: action, project: ProjectContext(path: self.checkout.path), options: .standard(), environment: [:], cleanupHome: self.home.path)
        return EnvironmentInspector.capture(command.executable, command.arguments, directory: command.directory, environment: command.environment)
    }
    var events: String { (try? String(contentsOf: self.checkout.appendingPathComponent("events"), encoding: .utf8)) ?? "" }
    func cleanUp() { try? FileManager.default.removeItem(at: self.root) }
}

struct CacheCleanupTests {
    @Test(arguments: [MimicAction.fullCleanup, .derivedDataCleanup])
    func removesOnlyRequestedCachesAndRunsScriptsInOrder(_ action: MimicAction) throws {
        let fixture = try CleanupFixture(); defer { fixture.cleanUp() }
        let result = try fixture.run(action)
        #expect(result.0 == 0)
        for target in fixture.targets {
            let shouldRemain = action == .derivedDataCleanup && !target.hasSuffix("DerivedData")
            #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(target + "/marker").path) == shouldRemain)
            #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(target + "-keep/marker").path))
        }
        #expect(fixture.events == (action == .fullCleanup ? "bootstrap:0\nlogin:--login-retry\n" : ""))
    }

    @Test
    func failedBootstrapStopsBeforeLogin() throws {
        let fixture = try CleanupFixture(bootstrapExit: 37); defer { fixture.cleanUp() }
        #expect(try fixture.run(.fullCleanup).0 == 37)
        #expect(fixture.events == "bootstrap:0\n")
    }

    @Test
    func cleanupUsesXcodeGateAndProtectsSensitiveOutput() {
        #expect(MimicAction.fullCleanup.requiresXcodeQuit)
        #expect(MimicAction.derivedDataCleanup.requiresXcodeQuit)
        #expect(MimicAction.fullCleanup.isSensitive)
        #expect(!MimicAction.derivedDataCleanup.isSensitive)
        #expect(EnvironmentInspector.missing(action: .derivedDataCleanup, options: .standard(), project: ProjectContext(path: "/fixture"), environment: [:]).isEmpty)
    }

    @Test
    @MainActor
    func failedFullCleanupKeepsDiagnosticOnlyInMemory() {
        var record = TaskRecord(action: .fullCleanup, project: ProjectContext(path: "/fixture"))
        record.status = .failed
        let store = DiagnosticMemory()
        store.capture(record: record, output: Data("fixture failure".utf8))
        #expect(store.fragment(id: record.id) == "fixture failure")
        #expect(record.logPath == nil)
        store.clear()
        #expect(store.fragment(id: record.id) == nil)
    }

    @Test(arguments: ["", "/", "/tmp/..", "relative"])
    func rejectsInvalidHome(_ home: String) {
        #expect(throws: MimicError.invalidCleanup) {
            try CommandSpec.make(action: .fullCleanup, project: ProjectContext(path: "/fixture"), options: .standard(), environment: [:], cleanupHome: home)
        }
    }
}
