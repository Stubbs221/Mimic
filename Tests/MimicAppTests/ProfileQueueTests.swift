//
//  ProfileQueueTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
import ZIPFoundation
import MimicCore
@testable import Mimic

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor struct ProfileQueueTests {
    @Test func pipelineFailureStopsLaterStepsAndReleasesFIFOWithoutWritingOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileQueue-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Disposable fixture"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", arguments, directory: root.path).0 == 0)
        }
        let profileJSON = #"{"schemaVersion":1,"id":"fixture","version":"1","title":"Fixture","requiredFiles":[],"actions":[{"id":"fail","title":"Pipeline","presentation":"regular","mcpAllowed":true,"requiresXcodeQuit":false,"requiredFiles":[],"requiredTools":[],"parameters":[],"steps":[{"executable":"/usr/bin/printf","arguments":["fixture-%s-output","sensitive"],"directory":"${checkout}"},{"executable":"/usr/bin/false","arguments":[],"directory":"${checkout}"},{"executable":"/usr/bin/touch","arguments":["${checkout}/unexpected"],"directory":"${checkout}"}]},{"id":"next","title":"Next","presentation":"regular","requiresXcodeQuit":false,"requiredFiles":[],"requiredTools":[],"parameters":[],"steps":[{"executable":"/usr/bin/true","arguments":[],"directory":"${checkout}"}]}]}"#
        let archiveURL = root.appendingPathComponent("fixture.mimicprofile")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])
        var actions = try #require(manifest["actions"] as? [[String: Any]])
        actions.append(["id": "slow", "title": "Slow", "presentation": "regular", "requiresXcodeQuit": false, "requiredFiles": [], "requiredTools": [], "parameters": [], "steps": [["executable": "/bin/sleep", "arguments": ["30"], "directory": "${checkout}"], ["executable": "/usr/bin/touch", "arguments": ["${checkout}/after-cancel"], "directory": "${checkout}"]]])
        actions.append(["id": "log", "title": "Log", "presentation": "regular", "logPolicy": "boundedSanitized", "requiresXcodeQuit": false, "requiredFiles": [], "requiredTools": [], "parameters": [], "steps": [["executable": "/usr/bin/printf", "arguments": ["glpat-%s\nAuthorization: %s\nsafe-line\n", "fixture-sanitizer", String(repeating: "x", count: 100_000) + "credential-tail"], "directory": "${checkout}"]]])
        manifest["actions"] = actions
        let bytes = try JSONSerialization.data(withJSONObject: manifest)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "profile.json", type: .file, uncompressedSize: Int64(bytes.count), provider: { offset, size in bytes.subdata(in: Int(offset)..<Int(offset) + size) })
        let directory = root.appendingPathComponent("Storage")
        let snapshot = try ProfileStore(directory: directory.appendingPathComponent("Profiles")).importArchive(archiveURL)
        let suite = "ProfileQueue-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TaskHost")
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
        let model = TaskCoordinator(directory: directory, helperURL: helper, defaults: defaults)
        let project = try EnvironmentInspector.project(path: root.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        let first = try #require(await withCheckedContinuation { continuation in
            model.requestProfile(execution: ProfileExecution(snapshot: snapshot, actionID: "fail", parameters: [:])) { continuation.resume(returning: $0) }
        })
        let second = try #require(await withCheckedContinuation { continuation in
            model.requestProfile(execution: ProfileExecution(snapshot: snapshot, actionID: "next", parameters: [:])) { continuation.resume(returning: $0) }
        })
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.records.contains(where: { $0.status == .queued || $0.status == .running }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.records.first { $0.id == first.id }?.status == .failed)
        #expect(model.records.first { $0.id == second.id }?.status == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
        let failed = try #require(model.records.first { $0.id == first.id })
        let diagnostic = model.diagnosticSnapshot(for: failed)
        #expect(diagnostic.text.contains("fixture-sensitive-output"))
        #expect(diagnostic.parameters.contains(snapshot.revision))
        #expect(diagnostic.displayAction == "Pipeline")
        #expect(model.replay(id: first.id).isEmpty)
        #expect(model.records.allSatisfy { $0.logPath == nil })
        #expect(!String(decoding: try Data(contentsOf: directory.appendingPathComponent("history.json")), as: UTF8.self).contains("fixture-sensitive-output"))
        let slow = try #require(await withCheckedContinuation { continuation in
            model.requestProfile(execution: ProfileExecution(snapshot: snapshot, actionID: "slow", parameters: [:])) { continuation.resume(returning: $0) }
        })
        let cancelDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.records.first(where: { $0.id == slow.id })?.status == .queued, ContinuousClock.now < cancelDeadline { try await Task.sleep(for: .milliseconds(5)) }
        model.cancel(id: slow.id)
        while model.records.first(where: { $0.id == slow.id })?.status == .running, ContinuousClock.now < cancelDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.records.first { $0.id == slow.id }?.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("after-cancel").path))
        let logged = try #require(await withCheckedContinuation { continuation in
            model.requestProfile(execution: ProfileExecution(snapshot: snapshot, actionID: "log", parameters: [:])) { continuation.resume(returning: $0) }
        })
        let logDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.records.first(where: { $0.id == logged.id })?.status == .queued || model.records.first(where: { $0.id == logged.id })?.status == .running, ContinuousClock.now < logDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let path = try #require(model.records.first { $0.id == logged.id }?.logPath)
        let output = try String(contentsOfFile: path, encoding: .utf8)
        #expect(output.contains("[REDACTED]")); #expect(!output.contains("glpat-fixture-sanitizer"))
        #expect(output.contains("safe-line")); #expect(!output.contains("credential-tail"))
        #expect(model.records.first { $0.id == logged.id }?.truncated == true)
        model.stopAndExit()
    }
}
