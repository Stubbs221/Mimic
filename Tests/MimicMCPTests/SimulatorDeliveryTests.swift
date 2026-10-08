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
    @Test func viewerDeliveryAndCompletionSkipRefreshButPublicActionsKeepIt() {
        for name in ["get_simulator_activity", "simulator_ui_viewer_action", "simulator_ui_video_poll", "simulator_ui_viewer_heartbeat", "simulator_ui_video_size", "simulator_ui_video", "simulator_ui_video_stop", "simulator_ui_frame", "simulator_ui_input", "simulator_ui_input_event", "simulator_ui_input_cancel"] {
            #expect(!MimicMCPMain.requiresProjectRefresh(method: name, arguments: [:]))
            #expect(!MimicMCPMain.requiresProjectRefresh(method: "simulator_ui_observe", arguments: ["operation": .string(name)]))
        }
        for name in ["run_local_action", "perform_simulator_action", "simulator_ui_action", "simulator_ui_attach", "get_state"] {
            #expect(MimicMCPMain.requiresProjectRefresh(method: name, arguments: [:]))
            #expect(MimicMCPMain.requiresProjectRefresh(method: "simulator_ui_observe", arguments: ["operation": .string(name)]))
        }
    }
    private var reply: MimicBridgeReply {
        .init(id: UUID(), result: .object(["image": .string("fixture-base64"), "hierarchy": .string("private-fixture-hierarchy"), "mimeType": .string("image/jpeg"), "sessionID": .string(UUID().uuidString), "revision": .number(1), "width": .number(402), "height": .number(874), "targets": .array([])]))
    }
    @Test func manualPanelDeliveryHasOnlyPrivateMetadata() throws {
        let result = try MimicMCPMain.toolReply(reply, name: "simulator_ui_observe")
        #expect(result.content.isEmpty); #expect(result.structuredContent == nil); #expect(result._meta != nil)
        let decoded = try JSONDecoder().decode(BridgeValue.self, from: JSONEncoder().encode(result))
        #expect(decoded["_meta"]["mimic/simulator"]["hierarchy"].string == "private-fixture-hierarchy")
    }
    @Test func acceptedManualCommandsKeepActivityIDInPrivateEnvelope() throws {
        let id = UUID().uuidString
        let reply = MimicBridgeReply(id: UUID(), result: .object(["id": .string(id), "kind": .string("action"), "status": .string("queued")]))
        for name in ["simulator_ui_action", "simulator_ui_viewer_action", "simulator_ui_observe"] {
            let result = try MimicMCPMain.toolReply(reply, name: name)
            #expect(result.content.isEmpty && result.structuredContent == nil)
            let value = try JSONDecoder().decode(BridgeValue.self, from: JSONEncoder().encode(result))
            #expect(value["_meta"]["mimic/simulator"]["id"].string == id)
        }
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
    @Test func videoCapabilitiesAndPacketsArePrivateForEveryViewerTool() throws {
        let reply = MimicBridgeReply(id: UUID(), result: .object(["token": .string("private-fixture-token"), "packets": .array([.string("private-video-packet")])]))
        for name in SimulatorBridge.viewerTools {
            let result = try MimicMCPMain.toolReply(reply, name: name)
            #expect(result.content.isEmpty && result.structuredContent == nil)
            let value = try JSONDecoder().decode(BridgeValue.self, from: JSONEncoder().encode(result))
            #expect(value["_meta"]["mimic/simulator"]["token"].string == "private-fixture-token")
        }
    }

}
