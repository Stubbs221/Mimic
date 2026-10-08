// Created by Василий Маслов on 06.10.2026.
import Foundation

/// Per-chat navigation and ordinary form drafts. Secrets and terminal input never belong in this value.
public struct PanelWorkspace: Codable, Equatable, Sendable {
    public var checkout: String?
    public var expanded: PanelBlockKind?
    public var selection: String?
    public var toolSelection: ProjectTool?
    public var toolGenerator: GeneratorKind?
    public var drafts: [String: [String: String]]
    public init(checkout: String? = nil, expanded: PanelBlockKind? = nil, selection: String? = nil, drafts: [String: [String: String]] = [:], toolSelection: ProjectTool? = nil, toolGenerator: GeneratorKind? = nil) {
        self.toolSelection = toolSelection; self.toolGenerator = toolGenerator
        self.checkout = checkout; self.expanded = expanded; self.selection = selection; self.drafts = drafts
    }
    public func validate() throws {
        guard drafts.count <= 50, selection?.utf8.count ?? 0 <= 100,
              drafts.allSatisfy({ $0.key.utf8.count <= 100 && $0.value.count <= 50 && $0.value.allSatisfy({ $0.key.utf8.count <= 100 && $0.value.utf8.count <= 16384 }) }) else { throw PanelLayoutError.invalid }
    }
}

/// Thread IDs come from host call metadata, not action arguments. Bindings never change desktop selection.
@MainActor public final class PanelWorkspaceStore {
    private let defaults: UserDefaults
    private var workspaces: [String: PanelWorkspace]
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspaces = defaults.data(forKey: "panelWorkspaces").flatMap { try? JSONDecoder().decode([String: PanelWorkspace].self, from: $0) } ?? [:]
    }
    public func load(_ threadID: String) -> PanelWorkspace { workspaces[threadID] ?? PanelWorkspace() }
    public func save(_ workspace: PanelWorkspace, for threadID: String) throws {
        guard !threadID.isEmpty, threadID.utf8.count <= 256, workspaces.count < 10000 || workspaces[threadID] != nil else { throw PanelLayoutError.invalid }
        try workspace.validate()
        var next = workspaces; next[threadID] = workspace
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: "panelWorkspaces"); workspaces = next
    }
}
