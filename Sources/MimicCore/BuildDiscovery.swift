// Created by Василий Маслов on 07.10.2026.
import Foundation

/// Fresh validation never reuses completed results; presentation may reuse a bounded catalogue cache.
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
    private struct Cached {
        let project: ProjectContext
        let scheme: String
        let tests: Bool
        let profileID: String?
        let profileRevision: String?
        let value: BuildCatalogue
        let loadedAt: Date
    }
    private var cache: [Cached] = []
    private let inspect: Inspect?

    public init(inspect: Inspect? = nil) { self.inspect = inspect }

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

    /// Inspecting presentation cache never starts a subprocess or resolves the system Xcode.
    public func cachedCatalogue(project: ProjectContext, scheme: String, includeTestPlans: Bool = false, profileID: String? = nil, profileRevision: String? = nil) -> (value: BuildCatalogue, loadedAt: Date)? {
        guard let entry = cache.last(where: { $0.project == project && $0.scheme == scheme && ($0.tests || !includeTestPlans) && $0.profileID == profileID && $0.profileRevision == profileRevision }) else { return nil }
        return (entry.value, entry.loadedAt)
    }

    public func catalogue(project: ProjectContext, scheme: String, includeTestPlans: Bool = false, profileID: String? = nil, profileRevision: String? = nil, useCache: Bool = false) async throws -> BuildCatalogue {
        let project = try await Self.pinned(project)
        let interval = ResourceTrace.begin("Build discovery", cause: useCache ? "presentation" : "fresh validation")
        defer { ResourceTrace.end("Build discovery", interval) }
        if useCache, let index = cache.firstIndex(where: { $0.project == project && $0.scheme == scheme && ($0.tests || !includeTestPlans) && $0.profileID == profileID && $0.profileRevision == profileRevision }) {
            let cached = cache.remove(at: index); cache.append(cached)
            ResourceTrace.event("Build discovery cache hit")
            return cached.value
        }
        if let entry = entries.first(where: { $0.project == project && $0.scheme == scheme && $0.tests == includeTestPlans && $0.profileID == profileID && $0.profileRevision == profileRevision }) {
            ResourceTrace.event("Build discovery shared")
            return try await entry.task.value
        }
        let id = UUID(), inspect = self.inspect
        let base = useCache ? cache.last(where: { $0.project == project && $0.profileID == profileID && $0.profileRevision == profileRevision })?.value : nil
        let task = Task {
            if let inspect { return try await inspect(project, scheme, includeTestPlans) }
            return try await Task.detached { try BuildCatalogue.inspect(project: project, scheme: scheme, includeTestPlans: includeTestPlans, baseCatalogue: base) }.value
        }
        entries.append(Entry(id: id, project: project, scheme: scheme, tests: includeTestPlans, profileID: profileID, profileRevision: profileRevision, task: task))
        defer { entries.removeAll { $0.id == id } }
        let value = try await task.value
        cache.removeAll { $0.project == project && $0.scheme == scheme && $0.tests == includeTestPlans && $0.profileID == profileID && $0.profileRevision == profileRevision }
        cache.append(Cached(project: project, scheme: scheme, tests: includeTestPlans, profileID: profileID, profileRevision: profileRevision, value: value, loadedAt: Date()))
        if cache.count > 8 { cache.removeFirst(cache.count - 8) }
        return value
    }
}
