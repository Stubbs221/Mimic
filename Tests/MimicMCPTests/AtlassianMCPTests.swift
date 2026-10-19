// Created by Василий Маслов on 13.10.2026.
import Foundation
import Testing
import MCP
@testable import MimicCore
@testable import MimicMCP

struct AtlassianMCPTests {
    @Test func automaticPanelDataAndPrivateErrorsDoNotEnterModelContent() throws {
        let work: BridgeValue = .object(["issue": .object(["description": .string("private-requirement")])])
        for name in ["open_panel", "get_state", "bind_project"] {
            let result = try MimicMCPMain.toolReply(.init(id: UUID(), result: .object(["work": work])), name: name)
            #expect(result.structuredContent?.objectValue?["work"] == nil)
            #expect(result._meta?["mimic/workspace"]?.objectValue?["work"] != nil)
            for case let .text(text, _, _) in result.content { #expect(!text.contains("private-requirement")) }
        }
        let result = try MimicMCPMain.toolReply(.init(id: UUID(), error: "authenticationRequired"), name: "panel_work_context")
        #expect(result.content.isEmpty && result.structuredContent == nil)
    }
    @Test func onlySemanticReadsArePublicAndInputsCannotContainCredentialsOrArbitraryURLs() throws {
        let tools = MimicMCPMain.tools()
        for name in AtlassianBridge.tools {
            let tool = try #require(tools.first { $0.name == name }); #expect(tool.annotations.readOnlyHint == true)
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            #expect(properties["token"] == nil && properties["headers"] == nil && properties["endpoint"] == nil)
        }
        for name in AtlassianBridge.appTools {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool._meta?["ui"]?.objectValue?["visibility"] == .array([.string("app")]))
        }
        #expect(!tools.contains { ["jira_update_issue", "confluence_update_page"].contains($0.name) })
    }
}
