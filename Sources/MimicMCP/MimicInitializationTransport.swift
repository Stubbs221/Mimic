//
//  MimicInitializationTransport.swift
//  MimicMCP
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation
import Logging
import MCP

/// Swift MCP 0.12.1 models experimental client capabilities as strings. MCP Apps
/// advertise objects there; Mimic does not consume these optional capabilities.
/// Ignore unsupported values only during initialize, preserving core negotiation.
actor MimicInitializationTransport: Transport {
    nonisolated let logger: Logger
    private let stdio: StdioTransport

    init() {
        let stdio = StdioTransport()
        self.stdio = stdio
        self.logger = stdio.logger
    }

    func connect() async throws { try await self.stdio.connect() }
    func disconnect() async { await self.stdio.disconnect() }
    func send(_ data: Data) async throws { try await self.stdio.send(data) }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        let stdio = self.stdio
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await stdio.receive() {
                        try Task.checkCancellation()
                        continuation.yield(Self.compatibleInitialization(data))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func compatibleInitialization(_ data: Data) -> Data {
        guard var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["method"] as? String == "initialize",
              var parameters = message["params"] as? [String: Any],
              var capabilities = parameters["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any] else { return data }
        let supported = experimental.filter { $0.value is String }
        guard supported.count != experimental.count else { return data }
        capabilities["experimental"] = supported
        parameters["capabilities"] = capabilities
        message["params"] = parameters
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}
