// Created by Василий Маслов on 16.10.2026.
import Foundation
import Testing
import MCP
@testable import MimicCore
@testable import MimicMCP

struct ServiceToolMCPTests {
    @Test func schemasOnlyAcceptNamedOperationsAndSeparatePrivateUI() throws {
        let tools = MimicMCPMain.tools()
        for name in ServiceToolBridge.tools + ServiceToolBridge.appTools {
            let tool = try #require(tools.first { $0.name == name })
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            #expect(properties["url"] == nil && properties["method"] == nil && properties["owner"] == nil)
            #expect(tool.annotations.readOnlyHint == !["run_service_tool_action", "panel_service_run", "panel_service_save"].contains(name))
            if ServiceToolBridge.appTools.contains(name) { #expect(tool._meta?["ui"]?.objectValue?["visibility"] == .array([.string("app")])) }
        }
    }
    @Test func automaticPanelDataIsPrivateButExplicitAgentResultIsComplete() throws {
        let secret: BridgeValue = .object(["data": .object(["session": .string("fixture-session")])])
        let automatic = try MimicMCPMain.toolReply(.init(id: UUID(), result: .object(["serviceTools": secret])), name: "get_state")
        #expect(automatic.structuredContent?.objectValue?["serviceTools"] == nil)
        let explicit = try MimicMCPMain.toolReply(.init(id: UUID(), result: secret), name: "get_service_tool_result")
        #expect(explicit.structuredContent?.objectValue?["data"]?.objectValue?["session"] == .string("fixture-session"))
        for name in ServiceToolBridge.appTools {
            let reply = try MimicMCPMain.toolReply(.init(id: UUID(), result: secret), name: name)
            #expect(reply.content.isEmpty && reply.structuredContent == nil)
            let error = try MimicMCPMain.toolReply(.init(id: UUID(), error: "arguments"), name: name)
            #expect(error.content.isEmpty)
        }
    }
}
