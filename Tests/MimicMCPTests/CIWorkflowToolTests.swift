//
//  CIWorkflowToolTests.swift
//  MimicMCPTests
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import MCP
import Testing
import MimicCore
@testable import MimicMCP

struct CIWorkflowToolTests {
    @Test func sharedRulesArePublishedWithCorrectRequiredFieldsAndReadSemantics() throws {
        let tools = MimicMCPMain.tools()
        for (name, rule) in WorkflowContract.rules {
            let tool = try #require(tools.first { $0.name == name }), schema = try #require(tool.inputSchema.objectValue)
            #expect(Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []) == rule.required)
            #expect(Set(schema["properties"]?.objectValue?.keys ?? Dictionary<String, Value>().keys) == Set(rule.fields.keys))
            #expect(schema["additionalProperties"] == .bool(false))
        }
        let catalogue = try #require(tools.first { $0.name == "start_test_catalogue" })
        #expect(catalogue.inputSchema.objectValue?["properties"]?.objectValue?["parameters"]?.objectValue?["properties"]?.objectValue?["backend"]?.objectValue?["enum"] == .array([.string("cli")]))
        let run = try #require(tools.first { $0.name == "run_verified_tests" })
        #expect(run.inputSchema.objectValue?["required"]?.arrayValue?.contains(.string("enqueue")) == false)
        #expect(AgentWorkflow.schemaRevision == 4)
    }
    @Test func blockedFieldErrorsAreErrorsAndRetainStructuredRecovery() throws {
        let payload = WorkflowFieldError("busy", field: "enqueue", existingActivityID: UUID()).payload
        let result = try MimicMCPMain.toolReply(.init(id: UUID(), result: payload), name: "run_verified_tests")
        #expect(result.isError == true)
        #expect(result.structuredContent?.objectValue?["field"] == .string("enqueue"))
    }
    @Test func admissionContextRoundTripsWithoutResolvedXcodeSubstitution() {
        var record = BuildActivity(project: .init(path: "/fixture", branch: "main", commit: "one"), parameters: .init(), source: "Fixture")
        record.selectedDeveloperDirectory = "/resolved/Developer"
        let metadata = BuildBridge.metadata(record)
        #expect(metadata["context"] == metadata["admissionContext"])
        #expect(metadata["context"]["xcode"] == .string(""))
        #expect(metadata["executionContext"]["xcode"] == .string("/resolved/Developer"))
    }
    @Test func deliveryReportsMeasuredPreparationWithoutClaimingHostReceipt() throws {
        let reply = MimicBridgeReply(id: UUID(), result: .object(["verdict": .string("passed")]))
        let result = try MimicMCPMain.toolReply(reply, name: "get_build_result", requestStartedAt: .now)
        let timing = try #require(result.structuredContent?.objectValue?["mcpDelivery"]?.objectValue)
        #expect(timing["hostReceipt"] == .string("unknown"))
        #expect(timing["preparationMilliseconds"]?.doubleValue ?? -1 >= 0)
        #expect(timing["nativePayloadBytes"]?.intValue ?? 0 > 0)
    }
}
