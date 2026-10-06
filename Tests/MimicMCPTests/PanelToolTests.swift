// Created by Василий Маслов on 06.10.2026.
import Foundation
import MCP
import MimicCore
import Testing
@testable import MimicMCP

struct PanelToolTests {
    @Test func privateResultsAndToolsKeepDraftsAndCiphertextOutOfModelContent() throws {
        let tools = MimicMCPMain.tools()
        for name in PanelBridge.appTools {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool._meta?["ui"]?.objectValue?["visibility"] == .array([.string("app")]))
            let reply = try MimicMCPMain.toolReply(.init(id: UUID(), result: .object(["private": .string("fixture-private")])), name: name)
            #expect(reply.content.isEmpty)
            #expect(reply.structuredContent == nil)
            #expect(reply._meta?["mimic/private"] != nil)
        }
    }
    @Test func hostIdentityAndOptionalCheckoutAreExplicit() throws {
        #expect(MimicMCPMain.threadID(Metadata(additionalFields: ["thread_id": .string("chat-a")])) == "chat-a")
        #expect(MimicMCPMain.threadID(nil) == nil)
        let open = try #require(MimicMCPMain.tools().first { $0.name == "open_panel" })
        #expect(open.inputSchema.objectValue?["required"] == .array([]))
        #expect(open.inputSchema.objectValue?["properties"]?.objectValue?["checkout"] != nil)
        for name in PanelBridge.generatorTools {
            let tool = try #require(MimicMCPMain.tools().first { $0.name == name })
            #expect(tool._meta?["ui"]?.objectValue?["visibility"] == .array([.string("app"), .string("model")]))
        }
    }
}
