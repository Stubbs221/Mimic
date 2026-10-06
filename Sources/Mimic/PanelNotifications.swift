// Created by Василий Маслов on 06.10.2026.
import Combine
import Foundation
import UserNotifications
import MimicCore

/// The native owner delivers each transition once. A visible checkout receives an inline notice instead.
@MainActor final class PanelNotifications {
    private var statuses: [String: String] = [:]
    private var delivered = Set<String>()
    private var visible: [String: Date] = [:]
    private var pending: [String: [BridgeValue]] = [:]
    private var observation: AnyCancellable?
    private let defaults: UserDefaults
    init(model: TaskCoordinator, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        statuses = snapshot(model).reduce(into: [:]) { $0[$1.id] = $1.status }
        observation = model.objectWillChange.sink { [weak self, weak model] _ in
            Task { @MainActor in guard let model else { return }; self?.update(model) }
        }
    }
    private struct Status { let id: String; let status: String; let title: String; let checkout: String }
    private func snapshot(_ model: TaskCoordinator) -> [Status] {
        model.records.map { Status(id: $0.id.uuidString, status: model.awaitingInput.contains($0.id) ? "input" : $0.status.rawValue, title: $0.displayTitle ?? text($0.action.titleKey), checkout: $0.project.path) } + model.builds.records.map { Status(id: $0.id.uuidString, status: $0.needsInput == true ? "input" : $0.status.rawValue, title: text("build.operation." + $0.parameters.operation.rawValue), checkout: $0.project.path) } + model.remoteTests.runs.map { Status(id: $0.id.uuidString, status: $0.status, title: text("panel.block.ci"), checkout: $0.checkout.path) } + model.profileRemote.runs.map { Status(id: $0.id.uuidString, status: $0.status, title: $0.execution.action?.title ?? $0.execution.actionID, checkout: $0.checkout.path) }
    }
    func poll(checkout: String) -> [BridgeValue] {
        visible[checkout] = Date(); let notices = pending.removeValue(forKey: checkout) ?? []; return notices
    }
    private func update(_ model: TaskCoordinator) {
        for item in snapshot(model) {
            let previous = statuses.updateValue(item.status, forKey: item.id)
            guard previous != nil, previous != item.status, ["succeeded", "success", "SUCCESS", "failed", "FAILURE", "interrupted", "unknown", "input"].contains(item.status) else { continue }
            let key = item.id + ":" + item.status
            guard delivered.insert(key).inserted else { continue }
            let title = text(item.status == "input" ? "panel.notice.input" : ["succeeded", "success", "SUCCESS"].contains(item.status) ? "panel.notice.completed" : "panel.notice.failed")
            if let seen = visible[item.checkout], Date().timeIntervalSince(seen) < 12 {
                pending[item.checkout, default: []].append(.object(["id": .string(key), "taskID": .string(item.id), "title": .string(title), "body": .string(item.title)]))
            } else if defaults.bool(forKey: "setupNotifications") && Bundle.main.bundleIdentifier == "local.vmaslov.Mimic" {
                let content = UNMutableNotificationContent(); content.title = title; content.body = item.title
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil)) { _ in }
            }
        }
    }
}
