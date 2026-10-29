//
//  TerminalInputAdmissionTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 12.10.2026.
import CryptoKit
import Foundation
import SwiftTerm
import Testing
@testable import Mimic
import MimicCore

@Suite @MainActor
struct TerminalInputAdmissionTests {
    @Test func nativeDelegateDeliversAcceptedInputAndResizeWithoutPersistingInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeInputAdmission-" + UUID().uuidString)
        let checkout = root.appendingPathComponent("checkout"), storage = root.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("App/App.xcworkspace"), withIntermediateDirectories: true)
        for arguments in [["init", "-q", checkout.path], ["-C", checkout.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-qm", "Fixture"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", arguments).0 == 0)
        }
        var manifest = try #require(JSONSerialization.jsonObject(with: Profile11Fixture.data()) as? [String: Any])
        var actions = try #require(manifest["actions"] as? [[String: Any]])
        let profile = try JSONDecoder().decode(MimicProfile.self, from: Profile11Fixture.data())
        let actionID = try #require(profile.interface?.bindings.first { $0.role == .format }?.actionID)
        let index = try #require(actions.firstIndex { $0["id"] as? String == actionID })
        let script = checkout.appendingPathComponent("native-input-fixture.sh")
        try ("# Created by Василий Маслов on 12.10.2026.\n" + "stty -echo; printf '[15:32:02]: Pass'; sleep 0.05; printf 'phrase for Match storage: '; IFS= read -r value; test \"$value\" = SYNTHETIC_NATIVE_INPUT || exit 7; printf ACCEPTED; stty size\n").write(to: script, atomically: true, encoding: .utf8)
        actions[index]["steps"] = [["executable": "/bin/bash", "arguments": [script.path], "directory": "${checkout}"]]
        manifest["actions"] = actions
        _ = try Profile11Fixture.install(directory: storage, data: JSONSerialization.data(withJSONObject: manifest))
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
        let model = TaskCoordinator(directory: storage, helperURL: helper, defaults: defaults)
        let owner = UUID()
        defer {
            model.detachTerminal(owner: owner); model.stopAndExit()
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try EnvironmentInspector.project(path: checkout.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        var output = Data()
        model.attachTerminal(owner: owner) { _, data in output.append(data) }
        model.request(.format)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !String(decoding: output, as: UTF8.self).contains("Passphrase for Match storage:"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let id = try #require(model.activeID, "Disposable profile did not start")
        #expect(model.awaitingInput.contains(id))
        model.resize(id: id, columns: 40, rows: 12)
        let delegate = TerminalDelegate(model: model, id: id)
        delegate.send(source: TerminalView(), data: Array("SYNTHETIC_NATIVE_INPUT\n".utf8)[...])
        #expect(!model.awaitingInput.contains(id))
        while model.activeID == id, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.records.first { $0.id == id }?.status == .succeeded)
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("ACCEPTED") && text.contains("12 40"))
        #expect(model.records.first { $0.id == id }?.hasPrivateInput == true)
        let history = try await self.persistedPrivateHistory(directory: storage)
        #expect(!String(decoding: history, as: UTF8.self).contains("SYNTHETIC_NATIVE_INPUT"))
    }

    @Test func privateTransportDoesNotAcknowledgeRejectedInputOrClearPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InputAdmission-" + UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        let integration = MimicIntegration(model: model, defaults: defaults)
        defer {
            integration.stop(); model.records = []; model.stopAndExit()
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let project = ProjectContext(path: root.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        var workspace = PanelWorkspace(); workspace.checkout = project.path
        try integration.workspaceStore.save(workspace, for: "fixture-chat")
        var record = TaskRecord(action: .bootstrap, project: project)
        record.status = .running; model.records = [record]
        model.awaitingInput.insert(record.id)
        // A stale running record has no live PTY. Transport success must require actual admission.
        let client = P256.KeyAgreement.PrivateKey()
        let opened = try await integration.panelRequest(.init(method: "panel_terminal_open", parameters: ["taskID": .string(record.id.uuidString), "publicKey": .string(client.publicKey.x963Representation.base64EncodedString())], threadID: "fixture-chat"))
        let channelID = try #require(opened["channelID"].string)
        let encodedPeer = try #require(opened["publicKey"].string)
        let peerBytes = try #require(Data(base64Encoded: encodedPeer))
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerBytes)
        let key = try client.sharedSecretFromKeyAgreement(with: peer).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(channelID.utf8), sharedInfo: Data("mimic-panel-terminal-v1".utf8), outputByteCount: 32)
        let input = try JSONEncoder().encode(["input": "SYNTHETIC-REJECTED-INPUT\n"])
        let associated = Data("\(channelID)|\(record.id.uuidString)|fixture-chat|input|1".utf8)
        let box = try AES.GCM.seal(input, using: key, authenticating: associated)
        let packet = PanelCiphertext(sequence: 1, data: try #require(box.combined).base64EncodedString())
        do {
            _ = try await integration.panelRequest(.init(method: "panel_terminal_send", parameters: ["channelID": .string(channelID), "packet": try BridgeValue.encode(packet)], threadID: "fixture-chat"))
            Issue.record("Rejected PTY input was acknowledged")
        } catch let error as MimicIntegration.IntegrationError {
            #expect(error.code == "terminalInput")
        }
        #expect(model.awaitingInput.contains(record.id))
        #expect(model.records[0].hasPrivateInput == true)
        #expect(model.message == text("terminal.input.rejected"))
        let history = try await self.persistedPrivateHistory(directory: root)
        #expect(!String(decoding: history, as: UTF8.self).contains("SYNTHETIC-REJECTED-INPUT"))
    }

    /// History writes are asynchronous; inspect the durable private-input marker before reading bytes.
    private func persistedPrivateHistory(directory: URL) async throws -> Data {
        let store = HistoryStore(directory: directory), deadline = ContinuousClock.now + .seconds(2)
        while (try? store.load().first?.hasPrivateInput) != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try store.load().first?.hasPrivateInput == true)
        return try Data(contentsOf: directory.appendingPathComponent("history.json"))
    }
}
