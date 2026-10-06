//
//  AIMimicIntegrationTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 02.10.2026.
import AppKit
import Foundation
import Testing
import MimicCore
@testable import Mimic

@MainActor
private final class HoldingAIRunner: AIProcessRunning {
    var completion: ((Result<AIProcessOutput, AIError>) -> Void)?
    func start(executable: String, arguments: [String], input: Data, environment: [String: String], completion: @escaping (Result<AIProcessOutput, AIError>) -> Void) throws { self.completion = completion }
    func cancel() { let callback = self.completion; self.completion = nil; callback?(.failure(.cancelled)) }
}

struct AIMimicIntegrationTests {
    private func record(_ status: TaskStatus = .failed) -> TaskRecord {
        var record = TaskRecord(action: .bootstrap, project: ProjectContext(path: "/fixture/original", branch: "original", commit: "original-sha"))
        record.status = status; record.error = "preparation error"; record.finishedAt = Date()
        return record
    }

    @Test @MainActor
    func failedBootstrapIsMemoryOnlyAndRestartHasMetadataAndError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AI-integration-" + UUID().uuidString)
        let suite = "AI-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(directory: root), record = self.record()
        try store.save([record])
        let model = TaskCoordinator(directory: root, defaults: defaults)
        model.captureBootstrapDiagnostic(id: record.id, output: Data("Authorization: Bearer fixture-only\nunique-diagnostic-marker".utf8))
        model.projects = [ProjectContext(path: "/other", branch: "current", commit: "new-sha")]; model.selectedProjectPath = "/other"
        model.prepareAnalysis(record)
        let session = try #require(model.analysis.sessions[record.id])
        #expect(session.fragment.contains("unique-diagnostic-marker")); #expect(!session.fragment.contains("fixture-only"))
        #expect(session.snapshot.project.branch == "original"); #expect(session.snapshot.project.commit == "original-sha")
        #expect(!model.diagnosticUnavailable(id: record.id)); #expect(model.replay(id: record.id).isEmpty)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: file)
            #expect(!String(decoding: data, as: UTF8.self).contains("unique-diagnostic-marker"))
        }
        let restarted = TaskCoordinator(directory: root, defaults: defaults)
        restarted.prepareAnalysis(record)
        #expect(restarted.diagnosticUnavailable(id: record.id))
        #expect(restarted.analysis.sessions[record.id]?.fragment == "preparation error")
        #expect(restarted.analysis.sessions[record.id]?.result.isEmpty == true)
        model.clearDiagnosticsForExit(); #expect(model.analysis.sessions.isEmpty)
    }

    @Test @MainActor
    func bootstrapLimitEvictsAnalysisAndIgnoresSuccessAndCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AI-integration-" + UUID().uuidString)
        let suite = "AI-test-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let model = TaskCoordinator(directory: root, defaults: defaults)
        let failed = (0 ..< 9).map { _ in self.record() }
        model.records = failed + [self.record(.succeeded), self.record(.cancelled)]
        for record in failed {
            model.captureBootstrapDiagnostic(id: record.id, output: Data("error".utf8)); model.prepareAnalysis(record)
        }
        #expect(model.diagnosticUnavailable(id: failed[0].id)); #expect(model.analysis.sessions[failed[0].id] == nil)
        for record in model.records.suffix(2) {
            model.captureBootstrapDiagnostic(id: record.id, output: Data("success-or-cancel-output".utf8))
            #expect(model.diagnosticUnavailable(id: record.id))
        }
        #expect(model.analysis.sessions.count == 8)
    }

    @Test @MainActor
    func analysisDoesNotHoldCommandQueueOrBranchGateAndExitWaits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AI-integration-" + UUID().uuidString)
        let suite = "AI-test-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let runner = HoldingAIRunner(), analysis = AnalysisCoordinator(makeRunner: { runner })
        let model = TaskCoordinator(directory: root, defaults: defaults, analysis: analysis), record = self.record()
        model.records = [record]; model.gitSummary = GitSummary(porcelain: "")
        model.prepareAnalysis(record); model.analysis.submit(id: record.id, settings: AISettings(codexPath: "/bin/echo"))
        for _ in 0 ..< 1000 {
            if runner.completion != nil { break }; await Task.yield()
        }
        #expect(model.analysis.isActive); #expect(!model.busy); #expect(model.canSwitchBranch)
        var exitReplies = 0; model.afterStopped = { exitReplies += 1 }
        model.stopAndExit()
        for _ in 0 ..< 1000 {
            if !model.analysis.isActive { break }; await Task.yield()
        }
        #expect(exitReplies == 1); #expect(model.analysis.sessions.isEmpty)
    }
}

extension AIMimicIntegrationTests {
    @Test @MainActor
    func restartErrorRemainsEditableAfterMissingCLI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AI-integration-" + UUID().uuidString)
        let suite = "AI-test-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let model = TaskCoordinator(directory: root, defaults: defaults), record = self.record()
        model.records = [record]; model.prepareAnalysis(record)
        model.analysis.submit(id: record.id, settings: AISettings(codexPath: "/missing/fixture-cli"))
        for _ in 0 ..< 1000 {
            if !model.analysis.isActive { break }; await Task.yield()
        }
        #expect(model.analysis.sessions[record.id]?.error == .missingCLI)
        model.analysis.edit(id: record.id, fragment: "manually inserted diagnostic")
        #expect(model.analysis.sessions[record.id]?.prompt.contains("manually inserted diagnostic") == true)
        #expect(model.diagnosticUnavailable(id: record.id))
    }
}

extension AIMimicIntegrationTests {
    @Test @MainActor
    func readingDoesNotPrepareAIAndCopyUsesExactlyThePreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AI-result-" + UUID().uuidString)
        let suite = "AI-result-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let model = TaskCoordinator(directory: root, defaults: defaults), original = self.record()
        model.records = [original]
        model.captureBootstrapDiagnostic(id: original.id, output: Data("error\nerror\nerror\ntoken=fixture-secret".utf8))
        let snapshot = model.diagnosticSnapshot(for: original)
        #expect(!snapshot.text.contains("fixture-secret")); #expect(model.analysis.sessions.isEmpty)
        model.prepareAnalysis(original)
        #expect(model.expandedAnalysisIDs.contains(original.id))
        model.analysis.edit(id: original.id, fragment: "edited\npassword=fixture-secret", comment: "extra")
        model.selectedProjectPath = "/another-checkout"
        let preview = try #require(model.analysis.sessions[original.id]?.prompt)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(model.copyAnalysisRequest(id: original.id, pasteboard: pasteboard))
        #expect(pasteboard.string(forType: .string) == preview)
        #expect(preview.contains("original-sha") && !preview.contains("another-checkout"))
        #expect(model.diagnosticSnapshot(for: original).text == snapshot.text)
        model.expandedAnalysisIDs.remove(original.id)
        #expect(model.analysis.sessions[original.id]?.fragment.contains("edited") == true)
        #expect(!model.analysis.isActive)
    }
}
