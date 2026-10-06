//
//  TaskResultDesignTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

/// In-memory CLI responses only; this runner never starts an executable.
@MainActor
private final class TaskResultFixtureRunner: AIProcessRunning {
    var completion: ((Result<AIProcessOutput, AIError>) -> Void)?
    func start(executable _: String, arguments: [String], input _: Data, environment _: [String: String], completion: @escaping (Result<AIProcessOutput, AIError>) -> Void) throws {
        if arguments == ["--version"] { completion(.success(AIProcessOutput(stdout: Data("fixture 1.0".utf8), stderr: Data(), exitCode: 0))) }
        else if arguments == ["exec", "--help"] {
            completion(.success(AIProcessOutput(stdout: Data("--json --ephemeral --ignore-user-config --ignore-rules --strict-config --sandbox read-only --disable --enable --skip-git-repo-check".utf8), stderr: Data(), exitCode: 0)))
        } else if arguments.contains("features") {
            let features = CodexAIAdapter.disabledFeatures.map { $0 + " stable false" } + ["skip_host_skill_discovery experimental true"]
            completion(.success(AIProcessOutput(stdout: Data(features.joined(separator: "\n").utf8), stderr: Data(), exitCode: 0)))
        } else { self.completion = completion }
    }

    func cancel() { let callback = self.completion; self.completion = nil; callback?(.failure(.cancelled)) }
    func succeed() {
        let callback = self.completion; self.completion = nil
        let reply = String(repeating: "Объяснение на основе переданного фрагмента. Проверьте контекст запуска.\n", count: 16)
        let item: [String: Any] = ["type": "item.completed", "item": ["type": "agent_message", "text": reply]]
        let data = (try? JSONSerialization.data(withJSONObject: item)) ?? Data()
        callback?(.success(AIProcessOutput(stdout: data + Data("\n{\"type\":\"turn.completed\"}\n".utf8), stderr: Data(), exitCode: 0)))
    }
}

@Suite(.serialized)
@MainActor
struct TaskResultDesignTests {
    @Test
    func distinctStatusesAndBootstrapTitle() {
        var record = TaskRecord(action: .bootstrap, project: ProjectContext(path: "/fixture"), options: .standard(platform: .tvos))
        #expect(taskResultTitle(record) == "Bootstrap tvOS")
        record.status = .failed
        #expect(taskResultStatus(record) == text("task.result.launch.failed"))
        record.exitCode = 1
        #expect(taskResultStatus(record) == text("task.result.process.failed"))
        record.status = .cancelled
        #expect(taskResultStatus(record) == text("status.cancelled"))
        record.status = .interrupted
        #expect(taskResultStatus(record) == text("status.interrupted"))
    }

    /// No task can execute: only original records and memory-only diagnostics are supplied.
    @Test
    func renderInlineResultAtTwoHeightsAndEveryAppearance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskResultUI-" + UUID().uuidString)
        let suite = "TaskResultUI-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let runner = TaskResultFixtureRunner(), coordinator = AnalysisCoordinator(makeRunner: { runner })
        let model = TaskCoordinator(directory: root, defaults: defaults, analysis: coordinator)
        let output = ProcessInfo.processInfo.environment["MIMIC_RESULT_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let project = ProjectContext(path: "/private/tmp/Mimic-UI-fixture", branch: "feature/infrastructure/dependency-registry-bootstrap-diagnostics", commit: "fixture-sha")
        model.projects = [project]; model.selectedProjectPath = project.path
        for state in ["failed", "launch-failed", "interrupted", "cancelled", "success", "queued", "running", "truncated", "missing-output", "ai-ready", "ai-running", "ai-success", "ai-missing-cli", "ai-cancelled", "long-error"] {
            var record = TaskRecord(action: .bootstrap, project: project, options: .standard())
            record.status = state == "queued" ? .queued : state == "running" ? .running : state == "success" ? .succeeded : state == "cancelled" ? .cancelled : state == "interrupted" ? .interrupted : .failed
            record.startedAt = Date().addingTimeInterval(-12); record.finishedAt = Date()
            record.exitCode = state == "launch-failed" || state == "interrupted" ? nil : 1
            record.error = state == "launch-failed" ? "Не найден инструмент подготовки" : nil
            model.records = [record]; model.selectedTaskID = record.id
            let line = state == "long-error" ? "/Fastlane/fastfiles/project_dependency_registry_configuration:223: invalid multibyte char (US-ASCII)" : "fastlane/fastfiles/emcee:223: invalid multibyte char (US-ASCII)"
            if state != "missing-output", state != "launch-failed" { model.captureBootstrapDiagnostic(id: record.id, output: Data(Array(repeating: line, count: state == "truncated" ? 2000 : 8).joined(separator: "\n").utf8)) }
            if state.hasPrefix("ai-") { model.prepareAnalysis(record) }
            if state == "ai-missing-cli" {
                coordinator.submit(id: record.id, settings: AISettings(codexPath: "/nonexistent/fixture"))
                while coordinator.isActive {
                    await Task.yield()
                }
            } else if ["ai-running", "ai-success", "ai-cancelled"].contains(state) {
                coordinator.submit(id: record.id, settings: AISettings(codexPath: "/bin/echo"))
                for _ in 0 ..< 1000 {
                    if coordinator.sessions[record.id]?.state == .running { break }; await Task.yield()
                }
                if state == "ai-success" { runner.succeed() }
                if state == "ai-cancelled" { coordinator.cancel() }
                if state != "ai-running" { while coordinator.isActive {
                    await Task.yield()
                } }
            }
            model.revealSection(.tasks)
            for height in [CGFloat(420), 660] {
                let width = CGFloat(440)
                for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let view = NSHostingView(rootView: ScrollView { TaskDetails(model: model, record: record).padding(16) }.background(Color(nsColor: .windowBackgroundColor)).transaction { $0.disablesAnimations = true }.frame(width: width, height: height))
                    window.contentView = view; window.appearance = NSAppearance(named: appearance)
                    view.appearance = NSAppearance(named: appearance); view.frame = NSRect(x: 0, y: 0, width: width, height: height); view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(2))
                    view.layoutSubtreeIfNeeded()
                    #expect(view.fittingSize.width <= width + 1)
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide >= Int(width))
                    if let output { try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("task-\(state)-\(Int(height))-\(appearance.rawValue).png")) }
                    window.close()
                }
            }
            if coordinator.isActive { coordinator.cancel(); while coordinator.isActive {
                await Task.yield()
            } }
        }
    }
}
