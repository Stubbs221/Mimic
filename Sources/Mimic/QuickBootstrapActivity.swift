//
//  QuickBootstrapActivity.swift
//  Mimic
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation
import MimicCore

/// A menu request retains its identity before admission and after checkout changes.
struct QuickBootstrapActivity {
    var request: TaskRecord
    var error: String?
    var progress: BootstrapProgress?

    func record(in records: [TaskRecord]) -> TaskRecord {
        records.first { $0.id == self.request.id } ?? self.request
    }

    func isPreparing(in records: [TaskRecord]) -> Bool {
        self.request.status == .queued && self.error == nil && !records.contains { $0.id == self.request.id }
    }
}

/// Read-only admission is separate from process launch and can be replaced by fixtures.
enum BootstrapAdmissionResult: Sendable {
    case ready(ProjectContext)
    case failed(String)

    /// Tool and file requirements are validated by the pinned ProfileExecution after Git refresh.
    static func inspect(project: ProjectContext, options _: BootstrapOptions) async -> Self {
        await Task.detached {
            guard let checked = try? EnvironmentInspector.project(path: project.path, developerDirectory: project.developerDirectory, appleTarget: project.appleTarget) else { return failed("project.invalid") }
            return .ready(checked)
        }.value
    }
}
