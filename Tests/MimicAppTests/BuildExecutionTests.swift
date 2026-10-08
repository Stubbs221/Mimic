// Created by Василий Маслов on 04.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor private struct BuildFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildExecution-" + UUID().uuidString)
    let suite = "BuildExecution-" + UUID().uuidString
    let defaults: UserDefaults
    let project = ProjectContext(path: "/private/tmp", branch: "fixture", commit: "original", developerDirectory: "/fixture/Developer")
    let coordinator: BuildCoordinator
    var parameters: BuildParameters { .init(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") }
    init(script: String = "printf 'TAIL'; exit 0", inspect: (@Sendable (ProjectContext) async throws -> ProjectContext)? = nil) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? "/private/tmp/MimicBuildImplementation-20261004/debug/TaskHost")
        coordinator = BuildCoordinator(directory: root, helper: helper, defaults: defaults, inspect: inspect ?? { $0 }, resolveDeveloper: { $0.developerDirectory! }, makeCommand: { _, _ in .init(executable: "/bin/bash", arguments: ["-c", script], directory: "/private/tmp", environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]) }, discover: { _, _, _, _, _ in
            var catalogue = BuildCatalogue(); catalogue.schemes = ["Fixture"]; catalogue.configurations = ["Debug"]; catalogue.destinations = [.init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Fixture iPhone")]; return catalogue
        })
        let context = project
        coordinator.currentProject = { context }
    }
    func cleanup() { coordinator.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func wait(timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while coordinator.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let finished = !coordinator.busy
        try #require(finished, "operation did not finish")
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct BuildExecutionTests {
    @Test func privatePTYInputCannotReachSavedLogsOrDiagnostics() async throws {
        let fixture = try BuildFixture(script: "printf 'Ready\\n'; read -r value; printf 'Echo: %s\\n' \"$value\"; sleep 0.2; exit 7")
        defer { fixture.cleanup() }
        let record = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "fixture")
        fixture.coordinator.start(record)
        for _ in 0..<200 {
            if fixture.coordinator.output(record.id).contains(Data("Ready".utf8)) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.coordinator.canInput(record.id))
        try await fixture.coordinator.privateInput(record.id, bytes: Data("PRIVATE-ORDINARY-INPUT\n".utf8))
        #expect(try fixture.coordinator.readLog(record.id, after: 0).text.isEmpty)
        try await fixture.wait()
        #expect(fixture.coordinator.records.last?.hasPrivateInput == true)
        #expect(fixture.coordinator.savedLogURL(record.id) == nil)
        #expect(fixture.coordinator.output(record.id).isEmpty)
        #expect(throws: BuildError.diagnostic) { try fixture.coordinator.diagnostic(record.id) }
        let history = try Data(contentsOf: BuildHistoryStore(directory: fixture.root).directory.appendingPathComponent("history.json"))
        #expect(!String(decoding: history, as: UTF8.self).contains("PRIVATE-ORDINARY-INPUT"))
    }
    @Test func idempotencyPersistsAndChangedParametersCannotStartAgain() async throws {
        let fixture = try BuildFixture(); defer { fixture.cleanup() }
        let id = UUID()
        let first = try await fixture.coordinator.submit(id: id, project: fixture.project, parameters: fixture.parameters, source: "test")
        let second = try await fixture.coordinator.submit(id: id, project: fixture.project, parameters: fixture.parameters, source: "test")
        #expect(first.id == second.id); #expect(fixture.coordinator.records.count == 1)
        var changed = fixture.parameters; changed.configuration = "Release"
        await #expect(throws: BuildError.duplicate) { try await fixture.coordinator.submit(id: id, project: fixture.project, parameters: changed, source: "test") }
        fixture.coordinator.cancel(id)
        let restored = BuildCoordinator(directory: fixture.root, helper: URL(fileURLWithPath: "/missing"), defaults: fixture.defaults)
        let replay = try await restored.submit(id: id, project: fixture.project, parameters: fixture.parameters, source: "test")
        #expect(replay.status == .cancelled); #expect(!restored.hasPending)
    }
    @Test(arguments: [0, 7]) func exitCodeAndTrailingOutputAreAuthoritative(code: Int) async throws {
        let fixture = try BuildFixture(script: "printf 'BUILD SUCCEEDED\\nTAIL'; exit \(code)"); defer { fixture.cleanup() }
        let record = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "test")
        fixture.coordinator.start(record); try await fixture.wait()
        let final = try #require(fixture.coordinator.records.last)
        #expect(final.status == (code == 0 ? .succeeded : .failed)); #expect(final.exitCode == code)
        #expect(String(decoding: fixture.coordinator.output(record.id), as: UTF8.self).contains("TAIL"))
        #expect(final.errorCount == nil)
    }
    @Test(arguments: 0..<5) func observerDetachmentDoesNotCancelAndExplicitCancellationIsOwned(attempt: Int) async throws {
        let fixture = try BuildFixture(script: "printf 'READY\\n'; sleep 0.2; printf 'DONE\\n'"); defer { fixture.cleanup() }
        let record = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "test")
        let owner = UUID(); fixture.coordinator.attachTerminal(owner: owner) { _, _ in }; fixture.coordinator.start(record)
        fixture.coordinator.detachTerminal(owner: owner); try await fixture.wait()
        #expect(fixture.coordinator.records.last?.status == .succeeded)
        let long = try BuildFixture(script: "printf 'READY\\n'; sleep 30"); defer { long.cleanup() }
        let running = try await long.coordinator.submit(id: UUID(), project: long.project, parameters: long.parameters, source: "test")
        long.coordinator.start(running)
        for _ in 0..<100 { if long.coordinator.active?.status == .running { break }; try await Task.sleep(for: .milliseconds(10)) }
        long.coordinator.cancel(running.id); try await long.wait(); #expect(long.coordinator.records.last?.status == .cancelled)
    }
    @Test(arguments: [0, 1, 5]) func cancelledPreparationNeverBecomesFailed(delay: Int) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("MimicPrepare-" + UUID().uuidString)
        let fixture = try BuildFixture(inspect: { project in
            if FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .seconds(2)) }
            return project
        })
        defer { fixture.cleanup(); try? FileManager.default.removeItem(at: marker) }
        let record = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "fixture")
        try Data().write(to: marker)
        fixture.coordinator.start(record)
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        fixture.coordinator.cancel(record.id); try await fixture.wait()
        try await Task.sleep(for: .milliseconds(20))
        let completed = try #require(fixture.coordinator.records.first { $0.id == record.id })
        #expect(completed.status == .cancelled && completed.startedAt == nil && completed.errorCode == nil)
    }

    @Test func contextIsCheckedAgainBeforeStart() async throws {
        let fixture = try BuildFixture(); defer { fixture.cleanup() }
        let record = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "test")
        fixture.coordinator.currentProject = { ProjectContext(path: "/private/tmp", branch: "changed", commit: "changed") }
        fixture.coordinator.start(record); try await fixture.wait()
        #expect(fixture.coordinator.records.last?.status == .failed); #expect(fixture.coordinator.records.last?.startedAt == nil)
    }
    @Test func evictedHistoryKeepsIdempotencyAndIndependentObservers() async throws {
        let fixture = try BuildFixture(); defer { fixture.cleanup() }
        let id = UUID()
        let first = try await fixture.coordinator.submit(id: id, project: fixture.project, parameters: fixture.parameters, source: "Codex")
        fixture.coordinator.cancel(id)
        for _ in 0..<101 {
            let record = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "fixture")
            fixture.coordinator.cancel(record.id)
        }
        #expect(fixture.coordinator.records.count == 100)
        #expect(!fixture.coordinator.records.contains { $0.id == first.id })
        let restored = BuildCoordinator(directory: fixture.root, helper: URL(fileURLWithPath: "/missing"), defaults: fixture.defaults)
        let retry = try await restored.submit(id: id, project: fixture.project, parameters: fixture.parameters, source: "Terminal")
        #expect(retry.id == id); #expect(retry.status == .cancelled); #expect(retry.source == "Codex"); #expect(!restored.hasPending)
        let active = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "fixture")
        fixture.coordinator.start(active); try await fixture.wait()
        let firstObserver = try fixture.coordinator.readLog(active.id, after: 0)
        let secondObserver = try fixture.coordinator.readLog(active.id, after: 0)
        #expect(firstObserver.text == secondObserver.text); #expect(firstObserver.nextCursor == secondObserver.nextCursor)
        #expect(try fixture.coordinator.readLog(active.id, after: firstObserver.nextCursor).text.isEmpty)
    }
    @Test func restoredUnknownOperationBlocksStartsUntilExplicitAcknowledgement() async throws {
        let fixture = try BuildFixture(); defer { fixture.cleanup() }
        var unknown = BuildActivity(project: fixture.project, parameters: .init(backend: .xcodeMCP, configuration: "", workspaceTab: "tab1"), source: "fixture")
        unknown.status = .unknown; unknown.startedAt = Date(); unknown.finishedAt = Date(); unknown.tracking = .lost
        try BuildHistoryStore(directory: fixture.root).save([unknown])
        let restored = BuildCoordinator(directory: fixture.root, helper: URL(fileURLWithPath: "/missing"), defaults: fixture.defaults)
        #expect(restored.busy); #expect(restored.active == nil)
        let queued = BuildActivity(project: fixture.project, parameters: fixture.parameters, source: "fixture")
        restored.start(queued); #expect(restored.active == nil)
        restored.cancel(unknown.id); #expect(restored.records.first?.status == .unknown); #expect(restored.busy)
        restored.acknowledgeUnknown(unknown.id); #expect(!restored.busy); #expect(restored.records.first?.status == .unknown)
    }
    @Test func buildBridgeQueuesBehindOldToolsAndKeepsOutputLocal() async throws {
        let fixture = try BuildFixture(script: "printf 'TOKEN=glpat-fixture-secret\\nFAILURE\\n'; exit 7"); defer { fixture.cleanup() }
        let model = TaskCoordinator(directory: fixture.root.appendingPathComponent("native"), buildCoordinator: fixture.coordinator, defaults: fixture.defaults)
        model.projects = [fixture.project]; model.selectedProjectPath = fixture.project.path
        var barrier = TaskRecord(action: .format, project: fixture.project); barrier.status = .running; model.records = [barrier]
        let integration = MimicIntegration(model: model, defaults: fixture.defaults)
        let id = UUID(); var parameters = try #require(BridgeValue.encode(fixture.parameters).object); parameters["operation"] = nil
        let request = MimicBridgeRequest(method: "build_project", parameters: ["requestID": .string(id.uuidString), "context": MimicIntegration.context(fixture.project), "parameters": .object(parameters), "simulatorConfirmed": .bool(false)])
        let admitted = try await integration.handle(request)
        #expect(admitted["status"].string == "queued"); #expect(model.builds.active == nil)
        #expect(try await integration.handle(request)["id"].string == id.uuidString)
        #expect(model.builds.records.count == 1)
        var unsafe = parameters; unsafe["executable"] = .string("/bin/sh")
        var rejected = request.parameters; rejected["parameters"] = .object(unsafe)
        await #expect(throws: BuildError.arguments) { try await integration.buildRequest(.init(method: "build_project", parameters: rejected)) }
        model.records[0].status = .succeeded
        let record = try #require(model.builds.records.first); model.builds.start(record); try await fixture.wait()
        let metadata = try await integration.handle(.init(method: "get_build_activity", parameters: ["activityID": .string(id.uuidString)]))
        #expect(!String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self).contains("FAILURE"))
        let diagnostic = try await integration.handle(.init(method: "get_build_diagnostic", parameters: ["activityID": .string(id.uuidString)]))
        #expect(diagnostic["analysisPrompt"].string?.contains("FAILURE") == true)
        #expect(diagnostic["analysisPrompt"].string?.contains("fixture-secret") == false)
    }
    @Test func completedLogRemainsAvailableBeyondLiveBufferLimit() async throws {
        let line = "SwiftCompile " + String(repeating: "fixture/File.swift ", count: 40)
        let fixture = try BuildFixture(script: "for ((i=0;i<1200;i++)); do printf '%s\\n' '\(line)'; done"); defer { fixture.cleanup() }
        let record = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "fixture")
        fixture.coordinator.start(record); try await fixture.wait(timeout: .seconds(20))
        #expect(fixture.coordinator.records.last?.status == .succeeded)
        #expect(fixture.coordinator.output(record.id).count <= 512 * 1024)
        #expect(fixture.coordinator.savedLogURL(record.id) != nil)
        var cursor = 0; var bytes = 0
        for _ in 0..<30 {
            let slice = try fixture.coordinator.readLog(record.id, after: cursor)
            #expect(!slice.gap); #expect(slice.text.utf8.count <= 64 * 1024)
            cursor = slice.nextCursor; bytes += slice.text.utf8.count
            if slice.text.isEmpty { break }
        }
        #expect(bytes > 512 * 1024)
    }
    @Test func fakePTYDeliversOrderedBoundedSanitizedOutputBeforeCompletion() async throws {
        let fixture = try BuildFixture(script: "for ((i=0;i<1500;i++)); do printf 'row-%04d Привет🙂 %0500d\\n' \"$i\" 0; done; printf 'TOKEN=split'; printf '%s\\n' '-secret'; printf 'TAIL🙂'")
        defer { fixture.cleanup() }
        var delivered = Data(), maximumBatch = 0
        fixture.coordinator.attachTerminal(owner: UUID()) { _, bytes in
            maximumBatch = max(maximumBatch, bytes.count); delivered.append(bytes)
        }
        let record = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "fixture")
        fixture.coordinator.start(record); try await fixture.wait(timeout: .seconds(20))
        #expect(fixture.coordinator.records.last?.status == .succeeded)
        #expect(maximumBatch <= 64 * 1024)
        let disk = try String(contentsOf: BuildHistoryStore(directory: fixture.root).logURL(record.id), encoding: .utf8)
        let lines = disk.split(separator: "\n")
        try #require(lines.count == 1502)
        for index in 0..<1500 { #expect(lines[index].hasPrefix(String(format: "row-%04d", index))) }
        #expect(lines[1500] == "TOKEN=[REDACTED]" && lines[1501] == "TAIL🙂")
        let terminal = String(decoding: delivered, as: UTF8.self)
        #expect(!terminal.contains("split-secret") && !terminal.contains("�") && terminal.hasSuffix("TAIL🙂\n"))
        #expect(fixture.coordinator.lastLines(record.id).last == "TAIL🙂")
    }

    @Test func diagnosticAndPollingStayBoundedWithManySelectedTestsAndShortLines() async throws {
        let fixture = try BuildFixture(script: "/usr/bin/yes short | /usr/bin/head -n 8000; exit 7"); defer { fixture.cleanup() }
        var parameters = fixture.parameters; parameters.operation = .test; parameters.testIdentifiers = Array(repeating: "T/" + String(repeating: "C", count: 1000), count: 100)
        let record = try await fixture.coordinator.submit(id: UUID(), project: fixture.project, parameters: parameters, source: "fixture")
        fixture.coordinator.start(record); try await fixture.wait()
        let final = try #require(fixture.coordinator.records.last)
        let diagnostic = try fixture.coordinator.diagnosticPayload(record.id)
        #expect(diagnostic.truncated); #expect(diagnostic.prompt.utf8.count <= 64 * 1024)
        #expect(diagnostic.prompt.contains(record.id.uuidString)); #expect(diagnostic.prompt.hasSuffix("</diagnostic-data>"))
        let summary = BuildBridge.summary(final)
        #expect(summary["parameters"]["testCount"].integer == 100); #expect(summary["parameters"]["testIdentifiers"] == .null)
        #expect(try JSONEncoder().encode(summary).count < 8192)
        let model = TaskCoordinator(directory: fixture.root.appendingPathComponent("native"), buildCoordinator: fixture.coordinator, defaults: fixture.defaults)
        model.projects = [fixture.project]; model.selectedProjectPath = fixture.project.path
        let state = try await MimicIntegration(model: model, defaults: fixture.defaults).handle(.init(method: "get_state"))
        #expect(state["builds"].array?.first?["parameters"]["testCount"].integer == 100)
        #expect(try JSONEncoder().encode(state).count < 8192)
        #expect(BuildBridge.metadata(final)["parameters"]["testIdentifiers"].array?.count == 100)
    }
    @Test func overlayHidingPinAndNewTimerDoNotOwnExecutionOrFocus() async throws {
        let fixture = try BuildFixture(script: "printf 'READY\\n'; sleep 0.1; printf 'DONE\\n'"); defer { fixture.cleanup() }
        let model = TaskCoordinator(directory: fixture.root.appendingPathComponent("native"), buildCoordinator: fixture.coordinator, defaults: fixture.defaults)
        model.projects = [fixture.project]; model.selectedProjectPath = fixture.project.path
        let panel = BuildActivityPanel(model: model, defaults: fixture.defaults); defer { panel.stop() }
        panel.anchor = { NSRect(x: 0, y: 0, width: 1280, height: 800) }
        let key = NSApp?.keyWindow
        let first = try await model.builds.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "fixture")
        for _ in 0..<100 { if model.builds.active?.startedAt != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        panel.update(); #expect(panel.window.isVisible); #expect(NSApp?.keyWindow === key)
        panel.hide(); try await Task.sleep(for: .milliseconds(200)); panel.update()
        #expect(!panel.window.isVisible); #expect(model.builds.records.first { $0.id == first.id }?.status == .succeeded)
        model.builds.pinned = true
        _ = try await model.builds.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "fixture")
        try await fixture.wait(); panel.update(); #expect(panel.window.isVisible)
        try await Task.sleep(for: .milliseconds(5200)); panel.update(); #expect(panel.window.isVisible)
        model.builds.pinned = false; panel.update()
        try await Task.sleep(for: .milliseconds(5200)); #expect(!panel.isPresented)
        #expect(NSApp?.keyWindow === key)
    }
    @Test func panelPositionAndReadOnlyResultUseExistingSingleSection() throws {
        let fixture = try BuildFixture(); defer { fixture.cleanup() }
        let model = TaskCoordinator(directory: fixture.root.appendingPathComponent("native"), defaults: fixture.defaults)
        model.toggleSection(.builds); #expect(model.expandedSection == .builds)
        model.toggleSection(.tasks); #expect(model.expandedSection == .tasks)
        let frame = BootstrapActivityPanel.clamped(NSRect(x: 3000, y: -100, width: 360, height: 302), to: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(frame.maxX <= 1920); #expect(frame.minY == 0)
        let panel = BuildActivityPanel(model: model, defaults: fixture.defaults)
        #expect(!panel.window.canBecomeKey); #expect(!panel.window.canBecomeMain); panel.stop()
    }
}
