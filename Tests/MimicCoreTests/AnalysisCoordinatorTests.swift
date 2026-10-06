//
//  AnalysisCoordinatorTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation
import Testing
@testable import MimicCore

@MainActor
private final class AnalysisFixtureRunner: AIProcessRunning {
    var completion: ((Result<AIProcessOutput, AIError>) -> Void)?
    var inferenceCount = 0
    var input = Data()
    var environment: [String: String] = [:]
    var wasCancelled = false
    var holdProbe = false
    var startsCount = 0
    func start(executable _: String, arguments: [String], input: Data, environment: [String: String], completion: @escaping (Result<AIProcessOutput, AIError>) -> Void) throws {
        self.startsCount += 1
        if self.holdProbe { self.completion = completion; return }
        if arguments == ["--version"] { completion(.success(AIProcessOutput(stdout: Data("fixture 1.0".utf8), stderr: Data(), exitCode: 0))) }
        else if arguments == ["exec", "--help"] {
            let help = "--json --ephemeral --ignore-user-config --ignore-rules --strict-config --sandbox read-only --disable --enable --skip-git-repo-check"
            completion(.success(AIProcessOutput(stdout: Data(help.utf8), stderr: Data(), exitCode: 0)))
        } else if arguments.contains("features") {
            let features = CodexAIAdapter.disabledFeatures.map { $0 + " stable false" } + ["skip_host_skill_discovery experimental true"]
            completion(.success(AIProcessOutput(stdout: Data(features.joined(separator: "\n").utf8), stderr: Data(), exitCode: 0)))
        } else { self.inferenceCount += 1; self.input = input; self.environment = environment; self.completion = completion }
    }

    func cancel() {
        self.wasCancelled = true
        let completion = self.completion; self.completion = nil; completion?(.failure(.cancelled))
    }

    func finish(_ output: AIProcessOutput) {
        let completion = self.completion; self.completion = nil; completion?(.success(output))
    }
}

struct AnalysisCoordinatorTests {
    @MainActor
    private func waitForRun(_ coordinator: AnalysisCoordinator, id: UUID) async {
        for _ in 0 ..< 1000 {
            if coordinator.sessions[id]?.state == .running || !coordinator.isActive { return }
            await Task.yield()
        }
    }

    private func record() -> TaskRecord {
        var record = TaskRecord(action: .format, project: ProjectContext(path: "/original", branch: "old-branch", commit: "old-sha"))
        record.status = .failed
        return record
    }

    @Test @MainActor
    func duplicateSubmitAndOriginalTaskIdentity() async throws {
        let runner = AnalysisFixtureRunner(), coordinator = AnalysisCoordinator(makeRunner: { runner })
        var activity: [AIProvider] = []
        coordinator.onInferenceStarted = { provider, _ in activity.append(provider) }
        let original = self.record(), other = self.record()
        coordinator.prepare(snapshot: DiagnosticSnapshot(record: original, output: "error"), provider: .codex)
        coordinator.prepare(snapshot: DiagnosticSnapshot(record: other, output: "other error"), provider: .codex)
        let settings = AISettings(codexPath: "/bin/echo")
        coordinator.submit(id: original.id, settings: settings); coordinator.submit(id: other.id, settings: settings)
        await self.waitForRun(coordinator, id: original.id)
        #expect(activity == [.codex])
        #expect(runner.inferenceCount == 1); #expect(coordinator.activeTaskID == original.id)
        #expect(String(decoding: runner.input, as: UTF8.self).contains("old-branch"))
        coordinator.edit(id: original.id, fragment: "cannot edit during run")
        #expect(coordinator.sessions[original.id]?.fragment == "error")
        runner.finish(AIProcessOutput(stdout: Data("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Reason\"}}\n{\"type\":\"turn.completed\"}\n".utf8), stderr: Data(), exitCode: 0))
        for _ in 0 ..< 1000 {
            if !coordinator.isActive { break }; await Task.yield()
        }
        #expect(coordinator.sessions[original.id]?.state == .succeeded); #expect(coordinator.sessions[other.id]?.result == "")
        #expect(coordinator.sessions[original.id]?.prompt.contains("Reason") == false)
        #expect(coordinator.sessions[original.id]?.requestExpanded == false)
    }

    @Test @MainActor
    func exitCancelsAndClearsMemoryOnlyAfterHostCompletion() async throws {
        let runner = AnalysisFixtureRunner(), coordinator = AnalysisCoordinator(makeRunner: { runner })
        let task = self.record(); coordinator.prepare(snapshot: DiagnosticSnapshot(record: task, output: "diagnostic"), provider: .codex)
        coordinator.submit(id: task.id, settings: AISettings(codexPath: "/bin/echo"))
        await self.waitForRun(coordinator, id: task.id); coordinator.clearForExit()
        for _ in 0 ..< 1000 {
            if !coordinator.isActive { break }; await Task.yield()
        }
        #expect(runner.wasCancelled); #expect(coordinator.sessions.isEmpty); #expect(!coordinator.isActive)
    }

    @Test @MainActor
    func missingCLILeavesCopyContextAvailable() async throws {
        let runner = AnalysisFixtureRunner(), coordinator = AnalysisCoordinator(makeRunner: { runner })
        var activity: [AIProvider] = []
        coordinator.onInferenceStarted = { provider, _ in activity.append(provider) }
        let task = self.record(); coordinator.prepare(snapshot: DiagnosticSnapshot(record: task, output: "diagnostic"), provider: .codex)
        coordinator.submit(id: task.id, settings: AISettings(codexPath: "/nonexistent/fixture-cli"))
        for _ in 0 ..< 1000 {
            if !coordinator.isActive { break }; await Task.yield()
        }
        #expect(coordinator.sessions[task.id]?.error == .missingCLI)
        #expect(coordinator.sessions[task.id]?.prompt.contains("diagnostic") == true)
        #expect(runner.inferenceCount == 0 && activity.isEmpty)
    }

    @Test @MainActor
    func providerFailureDoesNotSavePartialAnswer() async throws {
        let runner = AnalysisFixtureRunner(), coordinator = AnalysisCoordinator(makeRunner: { runner })
        let task = self.record(); coordinator.prepare(snapshot: DiagnosticSnapshot(record: task, output: "diagnostic"), provider: .codex)
        coordinator.submit(id: task.id, settings: AISettings(codexPath: "/bin/echo")); await self.waitForRun(coordinator, id: task.id)
        runner.finish(AIProcessOutput(stdout: Data("partial answer".utf8), stderr: Data("authentication failed".utf8), exitCode: 1))
        for _ in 0 ..< 1000 {
            if !coordinator.isActive { break }; await Task.yield()
        }
        #expect(coordinator.sessions[task.id]?.error == .authentication); #expect(coordinator.sessions[task.id]?.result == "")
    }
}

extension AnalysisCoordinatorTests {
    @Test @MainActor
    func deadlineIncludesPreparationAndStopsSubsequentProbes() async throws {
        let runner = AnalysisFixtureRunner(); runner.holdProbe = true
        let coordinator = AnalysisCoordinator(makeRunner: { runner }, timeLimit: 0.03)
        let task = self.record(); coordinator.prepare(snapshot: DiagnosticSnapshot(record: task, output: "failure"), provider: .codex)
        coordinator.submit(id: task.id, settings: AISettings(codexPath: "/bin/echo"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while coordinator.isActive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(coordinator.sessions[task.id]?.error == .timeout)
        #expect(runner.startsCount == 1); #expect(runner.inferenceCount == 0); #expect(!coordinator.isActive)
    }

    @Test @MainActor
    func cancelledPreparationCannotStartInference() async throws {
        let runner = AnalysisFixtureRunner(); runner.holdProbe = true
        let coordinator = AnalysisCoordinator(makeRunner: { runner })
        let task = self.record(); coordinator.prepare(snapshot: DiagnosticSnapshot(record: task, output: "failure"), provider: .codex)
        coordinator.submit(id: task.id, settings: AISettings(codexPath: "/bin/echo"))
        for _ in 0 ..< 1000 {
            if runner.startsCount > 0 { break }; await Task.yield()
        }
        coordinator.cancel()
        for _ in 0 ..< 1000 {
            if !coordinator.isActive { break }; await Task.yield()
        }
        #expect(coordinator.sessions[task.id]?.state == .cancelled); #expect(runner.startsCount == 1)
        coordinator.edit(id: task.id, fragment: "edited fragment")
        #expect(coordinator.sessions[task.id]?.prompt.contains("edited fragment") == true)
    }
}

extension AnalysisCoordinatorTests {
    @Test @MainActor
    func removedSourceCancelsAndDropsResultWhenIdle() async throws {
        let runner = AnalysisFixtureRunner(), coordinator = AnalysisCoordinator(makeRunner: { runner })
        let task = self.record(); coordinator.prepare(snapshot: DiagnosticSnapshot(record: task, output: "failure"), provider: .codex)
        coordinator.onIdle = { [weak coordinator] in coordinator?.retain(ids: []) }
        coordinator.submit(id: task.id, settings: AISettings(codexPath: "/bin/echo")); await self.waitForRun(coordinator, id: task.id)
        coordinator.retain(ids: [])
        for _ in 0 ..< 1000 {
            if !coordinator.isActive { break }; await Task.yield()
        }
        #expect(runner.wasCancelled); #expect(coordinator.sessions.isEmpty); #expect(!coordinator.isActive)
    }
}

extension AnalysisCoordinatorTests {
    @Test @MainActor
    func exactPreviewIsSubmittedAndDoesNotIncludePreviousAnswer() async throws {
        let runner = AnalysisFixtureRunner(), coordinator = AnalysisCoordinator(makeRunner: { runner })
        let task = self.record()
        coordinator.prepare(snapshot: DiagnosticSnapshot(record: task, output: "original"), provider: .codex)
        coordinator.edit(id: task.id, fragment: "token=fixture-secret\nEdited failure", comment: "password=fixture-secret")
        let preview = try #require(coordinator.sessions[task.id]?.prompt)
        #expect(runner.startsCount == 0)
        #expect(!preview.contains("fixture-secret"))
        coordinator.submit(id: task.id, settings: AISettings(codexPath: "/bin/echo"))
        await self.waitForRun(coordinator, id: task.id)
        #expect(String(decoding: runner.input, as: UTF8.self) == preview)
        coordinator.setRequestExpanded(id: task.id, expanded: false)
        #expect(coordinator.isActive)
        coordinator.cancel()
        for _ in 0 ..< 1000 {
            if !coordinator.isActive { break }; await Task.yield()
        }
        #expect(coordinator.sessions[task.id]?.state == .cancelled)
        #expect(coordinator.sessions[task.id]?.prompt == preview)
    }
}
