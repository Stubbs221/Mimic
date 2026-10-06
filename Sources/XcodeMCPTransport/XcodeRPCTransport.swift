// Created by Василий Маслов on 04.10.2026.
import Foundation
import Logging
import MCP
import MimicCore

/// Keeps SDK request correlation intact while using Xcode's supported numeric wire IDs.
public actor XcodeRPCTransport: Transport {
    public nonisolated let logger = Logger(label: "Mimic.XcodeRPC", factory: { _ in SwiftLogNoOpLogHandler() })
    private let base: any Transport
    private var identity = XcodeRPCIdentity()
    private var reader: Task<Void, Never>?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    public init(base: any Transport) {
        self.base = base
        let channel = AsyncThrowingStream<Data, Error>.makeStream(); stream = channel.stream; continuation = channel.continuation
    }
    public func connect() async throws {
        try await base.connect()
        reader = Task { [base] in
            do { for try await message in await base.receive() { let data = try identity.incoming(message); continuation.yield(data) }; continuation.finish() }
            catch { continuation.finish(throwing: error) }
        }
    }
    public func disconnect() async { reader?.cancel(); reader = nil; continuation.finish(); await base.disconnect() }
    public func send(_ data: Data) async throws { try await base.send(identity.outgoing(data)) }
    public func receive() -> AsyncThrowingStream<Data, Error> { stream }
}
