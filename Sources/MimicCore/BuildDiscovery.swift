// Created by Василий Маслов on 07.10.2026.
import Foundation

/// Native, MCP and queued preparation share only identical in-flight queries. Results are never cached for a later build.
public actor BuildDiscovery {
    public static let shared = BuildDiscovery()
    public typealias Inspect = @Sendable (ProjectContext, String, Bool) async throws -> BuildCatalogue
    private struct Entry {
        let id: UUID
        let project: ProjectContext
        let scheme: String
        let tests: Bool
        let profileID: String?
        let profileRevision: String?
        let task: Task<BuildCatalogue, Error>
    }
    private var entries: [Entry] = []
    private let inspect: Inspect

    public init(inspect: @escaping Inspect = { project, scheme, tests in
        try await Task.detached { try BuildCatalogue.inspect(project: project, scheme: scheme, includeTestPlans: tests) }.value
    }) { self.inspect = inspect }

    /// Resolving the system choice pins it without changing xcode-select or the project's preference.
    public static func pinned(_ project: ProjectContext) async throws -> ProjectContext {
        var result = project
        if result.developerDirectory == nil {
            let directory = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1 }.value
            guard !directory.isEmpty else { throw BuildError.configuration }
            result.developerDirectory = directory
        }
        return result
    }

    public func catalogue(project: ProjectContext, scheme: String, includeTestPlans: Bool = false, profileID: String? = nil, profileRevision: String? = nil) async throws -> BuildCatalogue {
        let project = try await Self.pinned(project)
        if let entry = entries.first(where: { $0.project == project && $0.scheme == scheme && $0.tests == includeTestPlans && $0.profileID == profileID && $0.profileRevision == profileRevision }) {
            return try await entry.task.value
        }
        let id = UUID(), inspect = self.inspect
        let task = Task { try await inspect(project, scheme, includeTestPlans) }
        entries.append(Entry(id: id, project: project, scheme: scheme, tests: includeTestPlans, profileID: profileID, profileRevision: profileRevision, task: task))
        defer { entries.removeAll { $0.id == id } }
        return try await task.value
    }
}
