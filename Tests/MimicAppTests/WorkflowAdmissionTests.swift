//
//  WorkflowAdmissionTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import os
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct WorkflowAdmissionTests {
    @MainActor private struct Fixture {
        let root: URL
        let project: ProjectContext
        let defaults: UserDefaults
        let suite: String
        let builds: BuildCoordinator
        let parameters = BuildParameters(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        init(helper: URL = .init(fileURLWithPath: "/missing"), reader: @escaping @Sendable (BuildActivity, Data) -> BuildResult = { BuildResultReader.read(record: $0, output: $1) }) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkflowAdmission-" + UUID().uuidString)
            let checkout = root.appendingPathComponent("checkout")
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Fixture"]] { try #require(EnvironmentInspector.capture("/usr/bin/git", arguments, directory: checkout.path).0 == 0) }
            project = try EnvironmentInspector.project(path: checkout.path, developerDirectory: "/fixture/Developer")
            suite = UUID().uuidString; defaults = try #require(UserDefaults(suiteName: suite))
            builds = BuildCoordinator(directory: root.appendingPathComponent("state"), helper: helper, defaults: defaults, inspect: { value in try await Task.sleep(for: .milliseconds(40)); return value }, resolveDeveloper: { _ in "/fixture/Developer" }, makeCommand: { record, _ in
                .init(executable: "/bin/bash", arguments: ["-c", "printf '** TEST SUCCEEDED **\\n'"], directory: record.project.path, environment: ["PATH": "/usr/bin:/bin"])
            }, discover: { _, _, _, _, _ in
                var catalogue = BuildCatalogue(); catalogue.schemes = ["Fixture"]; catalogue.configurations = ["Debug"]; catalogue.destinations = [.init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Fixture")]; return catalogue
            }, readResult: reader)
            let project = project
            builds.currentProject = { project }; builds.schedule = { }
        }
        func cleanup() { builds.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
    @Test func simultaneousIdenticalRequestsCoalesceAndAnotherIDIsBusy() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let id = UUID()
        let first = Task { try await fixture.builds.submit(id: id, project: fixture.project, parameters: fixture.parameters, source: "Fixture", owner: "one") }
        while fixture.builds.admittingCount == 0 { await Task.yield() }
        let repeated = Task { try await fixture.builds.submit(id: id, project: fixture.project, parameters: fixture.parameters, source: "Fixture", owner: "one") }
        do { _ = try await fixture.builds.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "Fixture", owner: "one"); Issue.record("duplicate queued") }
        catch let error as WorkflowFieldError { #expect(error.code == "busy" && error.existingActivityID == id) }
        #expect(try await first.value.id == repeated.value.id)
        #expect(fixture.builds.records.count == 1)
        await #expect(throws: BuildError.duplicate) { try await fixture.builds.submit(id: id, project: fixture.project, parameters: fixture.parameters, source: "Fixture", owner: "other") }
    }
    @Test func explicitEnqueueBudgetAndOwnerScopedCancellationSurviveRestart() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let workflow = UUID().uuidString
        var ids: [UUID] = []
        for _ in 0..<3 {
            let record = try await fixture.builds.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "Fixture", workflowID: workflow, owner: "one", enqueue: true)
            ids.append(record.id)
        }
        do { _ = try await fixture.builds.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "Fixture", workflowID: workflow, owner: "one", enqueue: true); Issue.record("fourth queued") }
        catch let error as WorkflowFieldError { #expect(error.code == "pendingBudget") }
        let foreign = try await fixture.builds.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "Fixture", workflowID: workflow, owner: "other", enqueue: true)
        let cancellation = UUID(), first = try fixture.builds.cancelWorkflowPending(workflow, owner: "one", requestID: cancellation)
        #expect(first["cancelled"].array?.count == 3)
        #expect(fixture.builds.activity(foreign.id)?.status == .queued)
        #expect(try fixture.builds.cancelWorkflowPending(workflow, owner: "one", requestID: cancellation) == first)
        #expect(throws: BuildError.duplicate) { try fixture.builds.cancelWorkflowPending(workflow, owner: "other", requestID: cancellation) }
        let restored = BuildCoordinator(directory: fixture.root.appendingPathComponent("state"), helper: .init(fileURLWithPath: "/missing"), defaults: fixture.defaults)
        #expect(try restored.cancelWorkflowPending(workflow, owner: "one", requestID: cancellation) == first)
        #expect(restored.activity(ids[0])?.owner == "one")
    }
    @Test func cancellationAfterProcessExitKeepsFactsAndExtractsOnlyOnceAcrossRestart() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? repo.appendingPathComponent(".build/debug/TaskHost").path)
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try Fixture(helper: helper, reader: { record, output in
            reads.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.3)
            return BuildResultReader.read(record: record, output: output)
        })
        defer { fixture.cleanup() }
        let record = try await fixture.builds.submit(id: UUID(), project: fixture.project, parameters: fixture.parameters, source: "Fixture", owner: "one")
        fixture.builds.start(record)
        let deadline = ContinuousClock.now + .seconds(10)
        while fixture.builds.activity(record.id)?.stage != .extractingResults && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(fixture.builds.busy && fixture.builds.activity(record.id)?.stage == .extractingResults)
        await #expect(throws: WorkflowFieldError.self) { try await fixture.builds.result(record.id) }
        let observer = Task { try await fixture.builds.waitForActivity(record.id, afterRevision: fixture.builds.activity(record.id)?.stateRevision, timeoutMs: 1000) }
        observer.cancel(); _ = try? await observer.value
        #expect(fixture.builds.busy)
        fixture.builds.cancel(record.id)
        while fixture.builds.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let finished = try #require(fixture.builds.activity(record.id))
        #expect(finished.status == .cancelled && finished.processOutcome == "succeeded" && finished.cancellationOutcome == "confirmed")
        #expect(finished.stageDurations?["extractingResults"] != nil && finished.stageDurations?["verifyingCoverage"] != nil)
        let result = try await fixture.builds.result(record.id)
        #expect(result.cancellationOutcome == "confirmed" && result.verification?.verdict != "passed")
        _ = try await fixture.builds.result(record.id)
        let restored = BuildCoordinator(directory: fixture.root.appendingPathComponent("state"), helper: helper, defaults: fixture.defaults, readResult: { record, output in
            reads.withLock { $0 += 1 }; return BuildResultReader.read(record: record, output: output)
        })
        #expect(try await restored.result(record.id).cancellationOutcome == "confirmed")
        #expect(reads.withLock { $0 } == 1)
    }
}
