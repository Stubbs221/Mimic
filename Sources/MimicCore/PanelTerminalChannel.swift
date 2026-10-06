// Created by Василий Маслов on 06.10.2026.
import CryptoKit
import Foundation

public enum PanelChannelError: Error { case expired, identity, sequence, payload }
public struct PanelCiphertext: Codable, Sendable {
    public let sequence: Int
    public let data: String
    public init(sequence: Int, data: String) { self.sequence = sequence; self.data = data }
}

/// Ephemeral ECDH/HKDF/AES-GCM channel. Associated data binds task, chat, direction and strict sequence.
/// No keys, plaintext input or output are encoded into durable state or tool-visible summaries.
public final class PanelTerminalChannel {
    public let id: UUID
    public let taskID: UUID
    public let threadID: String
    public let publicKey: Data
    public let expiresAt: Date
    private let key: SymmetricKey
    private var received = 0
    private var sent = 0
    public init(taskID: UUID, threadID: String, clientKey: Data, now: Date = Date()) throws {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: clientKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        id = UUID(); self.taskID = taskID; self.threadID = threadID
        publicKey = privateKey.publicKey.x963Representation
        expiresAt = now.addingTimeInterval(15 * 60)
        key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(id.uuidString.utf8), sharedInfo: Data("mimic-panel-terminal-v1".utf8), outputByteCount: 32)
    }
    private func associated(_ direction: String, _ sequence: Int) -> Data {
        Data("\(id.uuidString)|\(taskID.uuidString)|\(threadID)|\(direction)|\(sequence)".utf8)
    }
    public func seal(_ data: Data, now: Date = Date()) throws -> PanelCiphertext {
        guard now < expiresAt else { throw PanelChannelError.expired }
        guard data.count <= 256 * 1024 else { throw PanelChannelError.payload }
        let sequence = sent + 1
        let box = try AES.GCM.seal(data, using: key, authenticating: associated("output", sequence))
        guard let combined = box.combined else { throw PanelChannelError.payload }
        sent = sequence
        return .init(sequence: sequence, data: combined.base64EncodedString())
    }
    public func open(_ packet: PanelCiphertext, threadID: String, taskID: UUID, now: Date = Date()) throws -> Data {
        guard now < expiresAt else { throw PanelChannelError.expired }
        guard self.threadID == threadID, self.taskID == taskID else { throw PanelChannelError.identity }
        guard packet.sequence == received + 1 else { throw PanelChannelError.sequence }
        guard let bytes = Data(base64Encoded: packet.data), bytes.count <= 32 * 1024 else { throw PanelChannelError.payload }
        let plaintext = try AES.GCM.open(.init(combined: bytes), using: key, authenticating: associated("input", packet.sequence))
        received = packet.sequence; return plaintext
    }
}
