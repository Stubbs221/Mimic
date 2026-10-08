// Created by Василий Маслов on 07.10.2026.
import Foundation

/// Stable tool families, independent of profile action IDs and generator templates.
public enum ProjectTool: String, Codable, CaseIterable, Sendable {
    case generation, localization, proto, format, fullCleanup, derivedDataCleanup
    public var action: MimicAction { MimicAction(rawValue: rawValue)! }
    public var titleKey: String { "tool.name." + rawValue }
    public var descriptionKey: String { "tools.description." + rawValue }
    public var isCleanup: Bool { action.isCleanup }
    /// Built-in cleanup steps have a known global scope; arbitrary scripts retain profile wording.
    public func effectsKey(execution: ProfileExecution?) -> String {
        let cleanups = execution?.action?.steps.compactMap(\.cleanup) ?? []
        if cleanups.contains("full") { return "tools.effects.full" }
        if cleanups.contains("derivedData") { return "tools.effects.derivedData" }
        return "tools.effects." + rawValue
    }
    public var roles: [ProfileToolRole] {
        switch self {
        case .generation: [.generateUI, .generateSicilia, .generateGalera]
        case .localization: [.localization]
        case .proto: [.protocols]
        case .format: [.format]
        case .fullCleanup: [.fullCleanup]
        case .derivedDataCleanup: [.derivedDataCleanup]
        }
    }
    public static func identify(_ record: TaskRecord) -> Self? {
        if let role = record.profileExecution?.binding?.role { return allCases.first { $0.roles.contains(role) } }
        // Unbound custom profile actions must not masquerade as a built-in tool.
        guard record.profileExecution == nil else { return nil }
        return Self(rawValue: record.action.rawValue)
    }
    /// Running wins over FIFO waiting; previews never stand in for file creation.
    public func record(in records: [TaskRecord], checkout: String?) -> TaskRecord? {
        let matching = records.filter { $0.project.path == checkout && Self.identify($0) == self && $0.profileExecution?.preview != true }
        return matching.filter { $0.status == .running }.min { $0.createdAt < $1.createdAt }
            ?? matching.filter { $0.status == .queued }.min { $0.createdAt < $1.createdAt }
            ?? matching.max { ($0.finishedAt ?? $0.createdAt) < ($1.finishedAt ?? $1.createdAt) }
    }
}

/// A Mac-wide ordered selection. Empty selections restore the initial three tools.
public struct ToolsPreferences: Codable, Equatable, Sendable {
    public var revision: Int
    public var favorites: [ProjectTool]
    public static let standard: [ProjectTool] = [.generation, .localization, .format]
    public init(revision: Int = 0, favorites: [ProjectTool] = Self.standard) {
        self.revision = revision; self.favorites = favorites
    }
    public func validate() throws {
        guard revision >= 0, favorites.count <= 3, Set(favorites).count == favorites.count else { throw PanelLayoutError.invalid }
    }
}

/// Synchronous compare-and-save on the native owner prevents stale panels overwriting each other.
@MainActor public final class ToolsPreferencesStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> ToolsPreferences {
        guard let data = defaults.data(forKey: "toolsPreferences"), let value = try? JSONDecoder().decode(ToolsPreferences.self, from: data),
              (try? value.validate()) != nil, !value.favorites.isEmpty else { return ToolsPreferences() }
        return value
    }
    @discardableResult public func save(_ favorites: [ProjectTool], expectedRevision: Int) throws -> ToolsPreferences {
        let current = load()
        guard current.revision == expectedRevision else { throw PanelLayoutError.conflict }
        let value = ToolsPreferences(revision: current.revision + 1, favorites: favorites.isEmpty ? ToolsPreferences.standard : favorites)
        try value.validate()
        defaults.set(try JSONEncoder().encode(value), forKey: "toolsPreferences")
        return value
    }
}
