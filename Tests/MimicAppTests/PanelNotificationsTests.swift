// Created by Василий Маслов on 06.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct PanelNotificationsTests {
    @Test func visibleCheckoutReceivesEachTransitionOnceWithoutHistoricalNotifications() async throws {
        let suite = "PanelNotices-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path)
        var old = TaskRecord(action: .format, project: project); old.status = .failed; model.records = [old]
        let notices = PanelNotifications(model: model, defaults: defaults)
        #expect(notices.poll(checkout: project.path).isEmpty)
        var task = TaskRecord(action: .format, project: project); task.status = .running; model.records.append(task)
        try await Task.sleep(for: .milliseconds(20))
        model.awaitingInput.insert(task.id)
        try await Task.sleep(for: .milliseconds(20))
        let input = notices.poll(checkout: project.path)
        #expect(input.count == 1); #expect(input.first?["taskID"].string == task.id.uuidString)
        model.awaitingInput.remove(task.id); model.records[1].status = .failed
        try await Task.sleep(for: .milliseconds(20))
        #expect(notices.poll(checkout: "/other-checkout").isEmpty)
        #expect(notices.poll(checkout: project.path).count == 1)
        model.objectWillChange.send(); try await Task.sleep(for: .milliseconds(20))
        #expect(notices.poll(checkout: project.path).isEmpty)
    }
}
