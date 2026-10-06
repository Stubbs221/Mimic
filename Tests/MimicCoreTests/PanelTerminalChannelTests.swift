// Created by Василий Маслов on 06.10.2026.
import CryptoKit
import Foundation
import Testing
@testable import MimicCore

struct PanelTerminalChannelTests {
    @Test func encryptedExchangeRejectsReplayTamperingWrongChatAndExpiry() throws {
        let client = P256.KeyAgreement.PrivateKey(), task = UUID(), now = Date()
        let channel = try PanelTerminalChannel(taskID: task, threadID: "chat-a", clientKey: client.publicKey.x963Representation, now: now)
        let shared = try client.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: channel.publicKey))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(channel.id.uuidString.utf8), sharedInfo: Data("mimic-panel-terminal-v1".utf8), outputByteCount: 32)
        let input = Data("fixture input that must never be persisted".utf8)
        let aad = Data("\(channel.id.uuidString)|\(task.uuidString)|chat-a|input|1".utf8)
        let sealed = try AES.GCM.seal(input, using: key, authenticating: aad)
        let packet = PanelCiphertext(sequence: 1, data: try #require(sealed.combined).base64EncodedString())
        #expect(throws: PanelChannelError.self) { try channel.open(packet, threadID: "chat-b", taskID: task, now: now) }
        #expect(throws: PanelChannelError.self) { try channel.open(packet, threadID: "chat-a", taskID: UUID(), now: now) }
        #expect(try channel.open(packet, threadID: "chat-a", taskID: task, now: now) == input)
        #expect(throws: PanelChannelError.self) { try channel.open(packet, threadID: "chat-a", taskID: task, now: now) }
        let output = try channel.seal(Data("fixture output".utf8), now: now)
        let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(base64Encoded: output.data)!), using: key, authenticating: Data("\(channel.id.uuidString)|\(task.uuidString)|chat-a|output|1".utf8))
        #expect(String(decoding: decoded, as: UTF8.self) == "fixture output")
        #expect(!String(decoding: try JSONEncoder().encode(output), as: UTF8.self).contains("fixture output"))
        #expect(throws: PanelChannelError.self) { try channel.seal(input, now: now.addingTimeInterval(901)) }
        let forged = PanelCiphertext(sequence: 2, data: packet.data)
        #expect(throws: (any Error).self) { try channel.open(forged, threadID: "chat-a", taskID: task, now: now) }
    }
    @Test @MainActor func privateInputNeverProducesDiagnosticFragmentAndOlderHistoryDecodes() throws {
        var record = TaskRecord(action: .format, project: ProjectContext(path: "/private/tmp/disposable"))
        record.hasPrivateInput = true; record.status = .failed
        let memory = DiagnosticMemory(); memory.capture(record: record, output: Data("echoed input".utf8))
        #expect(record.metadataOnly); #expect(memory.fragment(id: record.id) == nil)
        let bytes = try JSONEncoder().encode(record)
        var old = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]; old["hasPrivateInput"] = nil
        #expect(try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: old)).hasPrivateInput == nil)
    }
}

@MainActor struct PanelWorkspaceTests {
    @Test func restoredChatsKeepBindingsDraftsAndSelectionIndependent() throws {
        let suite = "PanelWorkspace-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelWorkspaceStore(defaults: defaults)
        try store.save(.init(checkout: "/private/tmp/a", expanded: .builds, selection: "task:first", drafts: ["builds": ["scheme": "Пример 🧪"]]), for: "a")
        try store.save(.init(checkout: "/private/tmp/b", expanded: .generateUI), for: "b")
        let restored = PanelWorkspaceStore(defaults: defaults)
        #expect(restored.load("a").expanded == .builds)
        #expect(restored.load("a").drafts["builds"]?["scheme"] == "Пример 🧪")
        #expect(restored.load("b").checkout == "/private/tmp/b")
        #expect(restored.load("new").checkout == nil)
        #expect(throws: PanelLayoutError.self) { try store.save(.init(drafts: ["action": ["name": String(repeating: "x", count: 16385)]]), for: "c") }
    }
}
