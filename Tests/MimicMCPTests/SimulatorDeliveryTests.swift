//
//  SimulatorDeliveryTests.swift
//  MimicMCPTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
import MimicCore
@testable import MimicMCP

struct SimulatorDeliveryTests {
    private var reply: MimicBridgeReply {
        .init(id: UUID(), result: .object(["image": .string("fixture-base64"), "hierarchy": .string("private-fixture-hierarchy"), "mimeType": .string("image/jpeg"), "sessionID": .string(UUID().uuidString), "revision": .number(1), "width": .number(402), "height": .number(874), "targets": .array([])]))
    }
    @Test func manualPanelDeliveryHasOnlyPrivateMetadata() throws {
        let result = try MimicMCPMain.toolReply(reply, name: "simulator_ui_observe")
        #expect(result.content.isEmpty); #expect(result.structuredContent == nil); #expect(result._meta != nil)
        let decoded = try JSONDecoder().decode(BridgeValue.self, from: JSONEncoder().encode(result))
        #expect(decoded["_meta"]["mimic/simulator"]["hierarchy"].string == "private-fixture-hierarchy")
    }
    @Test func explicitModelObservationIncludesImageAndHierarchyButNoPrivateTargets() throws {
        let result = try MimicMCPMain.toolReply(reply, name: "observe_simulator")
        #expect(result.content.count == 2); #expect(result._meta == nil)
        let metadata = String(decoding: try JSONEncoder().encode(result.structuredContent), as: UTF8.self)
        #expect(!metadata.contains("fixture-base64")); #expect(!metadata.contains("private-fixture-hierarchy")); #expect(!metadata.contains("targets"))
    }
    @Test func privateToolsAreAppOnlyAndActionsHaveConstrainedSchemas() throws {
        let tools = MimicMCPMain.tools()
        for name in SimulatorBridge.appTools {
            let tool = try #require(tools.first { $0.name == name })
            let encoded = try JSONDecoder().decode(BridgeValue.self, from: JSONEncoder().encode(tool))
            #expect(encoded["_meta"]["ui"]["visibility"] == .array([.string("app")]))
        }
        let action = try #require(tools.first { $0.name == "perform_simulator_action" })
        let encoded = try JSONDecoder().decode(BridgeValue.self, from: JSONEncoder().encode(action))
        #expect(encoded["inputSchema"]["additionalProperties"] == .bool(false))
        #expect(encoded["inputSchema"]["properties"]["action"]["additionalProperties"] == .bool(false))
    }
}
