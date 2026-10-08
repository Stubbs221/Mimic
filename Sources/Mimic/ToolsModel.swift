// Created by Василий Маслов on 07.10.2026.
import Combine
import Foundation
import MimicCore

@MainActor final class ToolsPreferencesModel: ObservableObject {
    @Published private(set) var value: ToolsPreferences
    @Published private(set) var message = ""
    private let store: ToolsPreferencesStore
    init(defaults: UserDefaults) { store = ToolsPreferencesStore(defaults: defaults); value = store.load() }
    @discardableResult func save(_ favorites: [ProjectTool], expectedRevision: Int) throws -> ToolsPreferences {
        do {
            value = try store.save(favorites, expectedRevision: expectedRevision)
            message = favorites.isEmpty ? text("tools.favorites.restored") : ""
            return value
        } catch {
            value = store.load(); message = text("tools.favorites.conflict"); throw error
        }
    }
    func toggle(_ tool: ProjectTool) {
        var favorites = value.favorites
        if favorites.contains(tool) { favorites.removeAll { $0 == tool } }
        else if favorites.count < 3 { favorites.append(tool) }
        else { return }
        _ = try? save(favorites, expectedRevision: value.revision)
    }
    func move(_ tool: ProjectTool, by offset: Int) {
        guard let index = value.favorites.firstIndex(of: tool), value.favorites.indices.contains(index + offset) else { return }
        var favorites = value.favorites; favorites.swapAt(index, index + offset)
        _ = try? save(favorites, expectedRevision: value.revision)
    }
}

extension TaskCoordinator {
    func toolRecord(_ tool: ProjectTool) -> TaskRecord? { tool.record(in: records, checkout: selectedProjectPath) }
    func toolActive(_ tool: ProjectTool) -> Bool {
        toolAdmissions.contains(selectedProjectPath + "|" + tool.rawValue) || records.contains { $0.project.path == selectedProjectPath && ProjectTool.identify($0) == tool && [.queued, .running].contains($0.status) }
    }
    func canLaunchTool(_ tool: ProjectTool) -> Bool {
        project != nil && !switchingBranch && !admissionsClosed && pendingCount < 100 && readiness[tool.action] == [] && !toolActive(tool)
    }
    /// UI launches retain the form; the execution owner still validates profile and checkout.
    func launchTool(_ tool: ProjectTool, generation: GenerationRequest? = nil) {
        guard canLaunchTool(tool) else { return }
        let key = selectedProjectPath + "|" + tool.rawValue
        toolAdmissions.insert(key)
        request(tool.action, generation: generation, navigate: false) { [weak self] _ in self?.toolAdmissions.remove(key) }
    }
    func openProjectTool(_ tool: ProjectTool, source: MimicMotionSource = .current) {
        if panelPage != .home { returnHome(source: source) }
        revealSection(.tool(.generation), source: source)
        selectedProjectTool = tool; panelLayout.expanded = .utils
        scrollPanel(to: PanelBlockKind.utils.scrollID, source: source)
    }
}
