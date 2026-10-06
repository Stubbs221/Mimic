// Created by Василий Маслов on 06.10.2026.
import Foundation
import Testing
import ZIPFoundation
import MimicCore
@testable import Mimic

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct PanelContextTests {
    private func checkout(_ root: URL, _ name: String) throws -> ProjectContext {
        let url = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for args in [["init", "-b", name], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Disposable fixture"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", args, directory: url.path).0 == 0)
        }
        return try EnvironmentInspector.project(path: url.path)
    }
    @Test func twoChatsBindWithoutSelectingDesktopAndAdmissionsPinBothCheckouts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PanelContext-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try checkout(root, "a"), b = try checkout(root, "b"), storage = root.appendingPathComponent("Storage")
        let data = Data(#"{"schemaVersion":1,"id":"fixture","version":"1","title":"Fixture","requiredFiles":[],"actions":[{"id":"allowed","title":"Fixture action","presentation":"regular","mcpAllowed":true,"requiresXcodeQuit":false,"requiredFiles":[],"requiredTools":[],"parameters":[],"steps":[{"executable":"/usr/bin/true","arguments":[],"directory":"${checkout}"}]}]}"#.utf8)
        let path = root.appendingPathComponent("fixture.mimicprofile"), archive = try Archive(url: path, accessMode: .create)
        try archive.addEntry(with: "profile.json", type: .file, uncompressedSize: Int64(data.count), provider: { offset, size in data.subdata(in: Int(offset)..<Int(offset) + size) })
        _ = try ProfileStore(directory: storage.appendingPathComponent("Profiles")).importArchive(path)
        let suite = "PanelContext-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let simulator = SimulatorCoordinator(directory: storage, supports: { _ in true }, inspect: { $0 }, catalogue: { _ in [] })
        let model = TaskCoordinator(directory: storage, simulatorCoordinator: simulator, defaults: defaults); model.projects = [a]; model.selectedProjectPath = a.path
        let integration = MimicIntegration(model: model, defaults: defaults)
        let unbound = try await integration.handle(.init(method: "get_state", threadID: "chat-b"))
        #expect(unbound["context"] == .null); #expect(unbound["needsBinding"] == .bool(true))
        let anonymous = try await integration.handle(.init(method: "get_state", threadID: ""))
        #expect(anonymous["context"] == .null)
        let first = try await integration.handle(.init(method: "open_panel", parameters: ["checkout": .string(a.path)], threadID: "chat-a"))
        let second = try await integration.handle(.init(method: "open_panel", parameters: ["checkout": .string(b.path)], threadID: "chat-b"))
        #expect(model.project == a); #expect(second["context"]["checkoutId"].string == b.path)
        let devices = try await integration.handle(.init(method: "get_simulator_configuration", parameters: ["context": second["context"]], threadID: "chat-b"))
        #expect(devices["context"] == second["context"]); #expect(devices["context"]["profileID"].string == "fixture")
        var barrier = TaskRecord(action: .format, project: a); barrier.status = .running; model.records = [barrier]
        let selection = model.selectedTaskID
        func arguments(_ context: BridgeValue, _ id: UUID) -> [String: BridgeValue] { ["actionID": .string("allowed"), "parameters": .object([:]), "context": context, "requestID": .string(id.uuidString)] }
        let idA = UUID(), idB = UUID()
        let requestA = MimicBridgeRequest(method: "run_local_action", parameters: arguments(first["context"], idA), threadID: "chat-a")
        let requestB = MimicBridgeRequest(method: "run_local_action", parameters: arguments(second["context"], idB), threadID: "chat-b")
        _ = try await integration.handle(requestA); _ = try await integration.handle(requestB)
        #expect(model.records.suffix(2).map(\.project.path) == [a.path, b.path]); #expect(model.selectedTaskID == selection)
        let duplicate = try await integration.handle(requestB); #expect(duplicate["id"].string == idB.uuidString)
        #expect(model.records.count == 3)
        await #expect(throws: (any Error).self) { try await integration.handle(.init(method: "get_task", parameters: ["taskID": .string(idA.uuidString)], threadID: "chat-b")) }
        let stateB = try await integration.handle(.init(method: "get_state", threadID: "chat-b"))
        #expect(stateB["tasks"].array?.count == 1); #expect(stateB["queue"].array?.count == 3)
        model.projects[1].branch = "changed"
        await #expect(throws: (any Error).self) { try await integration.handle(.init(method: "run_local_action", parameters: arguments(second["context"], UUID()), threadID: "chat-b")) }
        #expect(model.records.first { $0.id == idB }?.project == b)
        let restored = PanelWorkspaceStore(defaults: defaults); #expect(restored.load("chat-b").checkout == b.path)
        model.stopAndExit()
    }
}
