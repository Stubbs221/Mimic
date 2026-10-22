// Created by Василий Маслов on 07.10.2026.
import Foundation

/// One bounded, persistent catalogue is shared by desktop, panels and build preflight.
public actor BuildDiscovery {
    public static let shared = BuildDiscovery(cacheDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mimic/BuildCatalogue"))
    public typealias Inspect = @Sendable (ProjectContext, String, Bool) async throws -> BuildCatalogue
    public typealias Signature = @Sendable (ProjectContext) async throws -> BuildCatalogueSignature
    public typealias InspectSelection = @Sendable (ProjectContext, String, Bool, BuildCatalogue) async throws -> BuildCatalogue
    private struct Entry {
        let id: UUID
        let project: ProjectContext
        let scheme: String
        let tests: Bool
        let profileID: String?
        let profileRevision: String?
        let signature: BuildCatalogueSignature
        let progress: BuildCatalogueProgressState
        let task: Task<BuildCatalogue, Error>
    }
    private struct Cached: Codable {
        let project: ProjectContext
        let scheme: String
        let tests: Bool
        let profileID: String?
        let profileRevision: String?
        let signature: BuildCatalogueSignature
        let value: BuildCatalogue
        let loadedAt: Date
    }
    private struct Snapshot: Codable { let version: Int; let entries: [Cached] }
    private var entries: [Entry] = []
    private var cache: [Cached] = []
    private let inspect: Inspect?
    private let inspectSelection: InspectSelection?
    private let signature: Signature
    private let cacheDirectory: URL?
    private var stopped = false

    /// Injected discovery defaults to a context identity for isolated fixtures; production hashes build metadata.
    public init(inspect: Inspect? = nil, cacheDirectory: URL? = nil, signature: Signature? = nil, inspectSelection: InspectSelection? = nil) {
        self.inspect = inspect; self.inspectSelection = inspectSelection; self.cacheDirectory = cacheDirectory
        self.signature = signature ?? { project in
            if inspect != nil {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let value = SourceRevisionReader.hash(try encoder.encode(project))
                return BuildCatalogueSignature(configuration: value, destinations: value)
            }
            return try await Task.detached(priority: .utility) { try BuildCatalogueSignature.capture(project: project) }.value
        }
        if let path = cacheDirectory?.appendingPathComponent("catalogue.json"), let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
           let data = try? Data(contentsOf: path), let saved = try? JSONDecoder().decode(Snapshot.self, from: data), saved.version == 1 { cache = Array(saved.entries.suffix(8)) }
    }

    // MARK: - Presentation and discovery

    /// Resolving the system choice pins it without changing xcode-select or the project's preference.
    public static func pinned(_ project: ProjectContext) async throws -> ProjectContext {
        var result = project
        if result.developerDirectory == nil {
            let directory = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1 }.value
            guard !directory.isEmpty else { throw BuildError.configuration }; result.developerDirectory = directory
        }
        return result
    }
    private func matches(_ cached: Cached, project: ProjectContext, profileID: String?, profileRevision: String?) -> Bool {
        cached.project.path == project.path && cached.project.developerDirectory == project.developerDirectory && cached.project.appleTarget == project.appleTarget && cached.profileID == profileID && cached.profileRevision == profileRevision
    }
    /// Immediate saved presentation only. Its contents are revalidated asynchronously before use.
    public func cachedCatalogue(project: ProjectContext, scheme: String, includeTestPlans: Bool = false, profileID: String? = nil, profileRevision: String? = nil) -> (value: BuildCatalogue, loadedAt: Date)? {
        guard let entry = cache.last(where: { matches($0, project: project, profileID: profileID, profileRevision: profileRevision) && $0.scheme == scheme && ($0.tests || !includeTestPlans) }) else { return nil }
        return (entry.value, entry.loadedAt)
    }
    /// Polling reads shared in-flight state without starting processes or changing its lifetime.
    public func progress(project: ProjectContext, scheme: String, includeTestPlans: Bool = false, profileID: String? = nil, profileRevision: String? = nil) -> BuildCatalogueProgress? {
        entries.last { $0.project == project && $0.scheme == scheme && $0.tests == includeTestPlans && $0.profileID == profileID && $0.profileRevision == profileRevision }?.progress.snapshot
    }
    /// Explicit refresh discards only this environment; active identical read-only work may still be shared.
    public func invalidate(project: ProjectContext, profileID: String? = nil, profileRevision: String? = nil) {
        cache.removeAll { matches($0, project: project, profileID: profileID, profileRevision: profileRevision) }
        persist()
    }
    /// Only the native application's shutdown owner cancels shared read-only discovery.
    public func stop() { stopped = true; for entry in entries { entry.task.cancel() } }
    /// Reuse is proved against build metadata and simulator inventory, independently of Git SHA.
    /// Explicit refresh uses useCache=false and retains the shared 120-second Xcode deadline.
    public func catalogue(project: ProjectContext, scheme: String, includeTestPlans: Bool = false, profileID: String? = nil, profileRevision: String? = nil, useCache: Bool = false) async throws -> BuildCatalogue {
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        let project = try await Self.pinned(project), stamp = try await signature(project)
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        if useCache, let index = cache.firstIndex(where: { matches($0, project: project, profileID: profileID, profileRevision: profileRevision) && $0.scheme == scheme && ($0.tests || !includeTestPlans) && $0.signature.configuration == stamp.configuration && (scheme.isEmpty || $0.signature.destinations == stamp.destinations) }) {
            let cached = cache.remove(at: index); cache.append(cached)
            ResourceTrace.event("Build discovery cache hit"); return cached.value
        }
        if let entry = entries.first(where: { $0.project == project && $0.scheme == scheme && $0.tests == includeTestPlans && $0.profileID == profileID && $0.profileRevision == profileRevision && $0.signature == stamp }) { return try await entry.task.value }
        let base = useCache ? cache.last(where: { matches($0, project: project, profileID: profileID, profileRevision: profileRevision) && $0.signature.configuration == stamp.configuration })?.value : nil
        let id = UUID(), inspect = self.inspect, progress = BuildCatalogueProgressState()
        let task = Task {
            if let inspect { return try await inspect(project, scheme, includeTestPlans) }
            let worker = Task.detached(priority: .utility) { try BuildCatalogue.inspect(project: project, scheme: scheme, includeTestPlans: includeTestPlans, baseCatalogue: base, progress: { progress.update(phase: $0, completed: $1, total: $2) }) }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
        entries.append(Entry(id: id, project: project, scheme: scheme, tests: includeTestPlans, profileID: profileID, profileRevision: profileRevision, signature: stamp, progress: progress, task: task))
        defer { entries.removeAll { $0.id == id } }
        let value = try await task.value
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let snapshot = progress.snapshot
        progress.update(phase: .verifying, completed: snapshot.completed, total: snapshot.total)
        guard try await signature(project) == stamp else { throw BuildError.context }
        remember(project: project, scheme: scheme, tests: includeTestPlans, profileID: profileID, profileRevision: profileRevision, signature: stamp, value: value)
        return value
    }

    // MARK: - Selected build validation

    /// Reuses unchanged metadata and freshly checks only the selected scheme's destinations.
    /// Tests additionally validate test plans; this never enumerates or executes tests.
    public func selectionCatalogue(project: ProjectContext, scheme: String, includeTestPlans: Bool = false, profileID: String? = nil, profileRevision: String? = nil) async throws -> BuildCatalogue {
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        let project = try await Self.pinned(project)
        guard !stopped else { throw CancellationError() }
        let stamp = try await signature(project)
        let base = try await catalogue(project: project, scheme: "", profileID: profileID, profileRevision: profileRevision, useCache: true)
        guard try await signature(project) == stamp else { throw BuildError.context }
        let value: BuildCatalogue
        if let inspectSelection { value = try await inspectSelection(project, scheme, includeTestPlans, base) }
        else if let inspect { value = try await inspect(project, scheme, includeTestPlans) }
        else {
            let worker = Task.detached { try BuildCatalogue.inspect(project: project, scheme: scheme, includeTestPlans: includeTestPlans, baseCatalogue: base) }
            value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
        guard try await signature(project) == stamp else { throw BuildError.context }
        remember(project: project, scheme: scheme, tests: includeTestPlans, profileID: profileID, profileRevision: profileRevision, signature: stamp, value: value)
        return value
    }
    private func remember(project: ProjectContext, scheme: String, tests: Bool, profileID: String?, profileRevision: String?, signature: BuildCatalogueSignature, value: BuildCatalogue) {
        cache.removeAll { matches($0, project: project, profileID: profileID, profileRevision: profileRevision) && $0.scheme == scheme && $0.tests == tests }
        cache.append(Cached(project: project, scheme: scheme, tests: tests, profileID: profileID, profileRevision: profileRevision, signature: signature, value: value, loadedAt: Date()))
        if cache.count > 8 { cache.removeFirst(cache.count - 8) }
        persist()
    }
    private func persist() {
        guard let cacheDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = cacheDirectory.appendingPathComponent("catalogue.json")
            try JSONEncoder().encode(Snapshot(version: 1, entries: cache)).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch { ResourceTrace.event("Build catalogue persistence unavailable") }
    }
}
