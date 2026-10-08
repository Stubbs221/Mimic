// Created by Василий Маслов on 06.10.2026.
import Foundation
import MCP
import MimicCore
import Testing
@testable import MimicMCP

struct PanelToolTests {
    @Test func appearanceIsOptionalPrivateMetadataAndSetupSchemaIsAligned() throws {
        let negotiated = MimicMCPMain.bridgeRequest(method: "get_state", arguments: [:], threadID: "fixture")
        #expect(negotiated.presentationMetadataVersion == 1 && negotiated.parameters.isEmpty)
        #expect(MimicMCPMain.bridgeRequest(method: "cancel_local_task", arguments: [:], threadID: "fixture").presentationMetadataVersion == nil)
        let old = try JSONDecoder().decode(MimicBridgeRequest.self, from: JSONEncoder().encode(MimicBridgeRequest(method: "get_state")))
        #expect(old.presentationMetadataVersion == nil)
        for name in ["open_panel", "get_state"] {
            let result = try MimicMCPMain.toolReply(.init(id: UUID(), result: .object(["appearance": .string("tileGrid"), "tasks": .array([])])), name: name)
            #expect(result._meta?["mimic/workspace"]?.objectValue?["appearance"] == .string("tileGrid"))
            #expect(result.structuredContent?.objectValue?["appearance"] == nil)
            for case let .text(text, _, _) in result.content { #expect(!text.contains("appearance")) }
            let old = try MimicMCPMain.toolReply(.init(id: UUID(), result: .object(["tasks": .array([])])), name: name)
            #expect(old._meta?["mimic/workspace"]?.objectValue?["appearance"] == nil)
        }
        let setup = try #require(MimicMCPMain.tools().first { $0.name == "panel_setup" })
        let operations = try #require(setup.inputSchema.objectValue?["properties"]?.objectValue?["operation"]?.objectValue?["enum"]?.arrayValue)
        #expect(operations.contains(.string("appearance")))
    }
    @Test func repeatedPanelOpensShareOnlyTheHostChatPresentationID() throws {
        let reply = MimicBridgeReply(id: UUID(), result: .object(["tasks": .array([])]))
        func open(_ thread: String?) throws -> CallTool.Result { try MimicMCPMain.toolReply(reply, name: "open_panel", threadID: thread) }
        let first = try open("chat-a"), second = try open("chat-a"), other = try open("chat-b")
        let key = "openai/widgetSessionId"
        let identifier = try #require(first._meta?[key]?.stringValue)
        #expect(identifier == second._meta?[key]?.stringValue)
        #expect(identifier != other._meta?[key]?.stringValue)
        #expect(!identifier.contains("chat-a"))
        #expect(first.structuredContent == second.structuredContent)
        #expect(first.structuredContent?.objectValue?[key] == nil)
        #expect(first._meta?["mimic/workspace"] != nil)
        #expect(try open(nil)._meta?[key] == nil)
        #expect(try open("")._meta?[key] == nil)
        #expect(try open(String(repeating: "a", count: 257))._meta?[key] == nil)
        #expect(try MimicMCPMain.toolReply(reply, name: "get_state", threadID: "chat-a")._meta?[key] == nil)
        #expect(try MimicMCPMain.toolReply(.init(id: UUID(), error: "unavailable"), name: "open_panel", threadID: "chat-a")._meta?[key] == nil)
    }
    @Test func branchDeliveryIsPrivateAndResolutionToolsRequireExactOperationID() throws {
        let tools = MimicMCPMain.tools()
        for name in BranchSwitchBridge.appTools {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool._meta?["ui"]?.objectValue?["visibility"] == .array([.string("app")]))
            let reply = try MimicMCPMain.toolReply(.init(id: UUID(), result: .object(["prompt": .string("fixture")])), name: name)
            #expect(reply.content.isEmpty); #expect(reply.structuredContent == nil)
        }
        for name in BranchSwitchBridge.tools {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool.inputSchema.objectValue?["required"] == .array([.string("operationID")]))
            #expect(tool._meta?["ui"]?.objectValue?["visibility"] == .array([.string("app"), .string("model")]))
        }
        let switchTool = try #require(tools.first { $0.name == "panel_switch_branch" })
        #expect(switchTool.inputSchema.objectValue?["properties"]?.objectValue?["requestID"] != nil)
    }
    @Test func newlyOpenedPanelsAdvertiseVersionedResources() throws {
        let open = try #require(MimicMCPMain.tools().first { $0.name == "open_panel" })
        let uri = try #require(open._meta?["ui"]?.objectValue?["resourceUri"]?.stringValue)
        #expect(uri.hasPrefix(MimicMCPMain.legacyURI + "/"))
        #expect(uri != MimicMCPMain.legacyURI)
        #expect(uri == MimicMCPMain.uri)
        let policy = MimicMCPMain.resourceMetadata
        let domains: Value = .array([.string("ws://127.0.0.1:*"), .string("wss://127.0.0.1:47931")])
        #expect(policy["ui"]?.objectValue?["csp"]?.objectValue?["connectDomains"] == domains)
        #expect(policy["openai/widgetCSP"]?.objectValue?["connect_domains"] == domains)
    }
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
    @Test func favoritesStayInPrivateStateMetadata() throws {
        let result = try MimicMCPMain.toolReply(.init(id: UUID(), result: .object(["toolsPreferences": .object(["revision": .number(1), "favorites": .array([.string("format")])]), "tasks": .array([])])), name: "get_state")
        #expect(result.structuredContent?.objectValue?["toolsPreferences"] == nil)
        #expect(result._meta?["mimic/workspace"]?.objectValue?["toolsPreferences"] != nil)
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
