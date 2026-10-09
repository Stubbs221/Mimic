//
//  AgentWorkflow.swift
//  MimicCore
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation

/// Product and tool revisions are separate from the socket/MCP protocol versions.
public struct AgentHelperIdentity: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let toolSchemaRevision: Int
    public var executableDigest: String?
    public static let current: Self = {
        var value = Self(version: MimicVersion.version, build: MimicVersion.build, toolSchemaRevision: AgentWorkflow.schemaRevision)
        if let url = Bundle.main.executableURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 128 * 1024 * 1024, let data = try? Data(contentsOf: url, options: .mappedIfSafe) { value.executableDigest = SourceRevisionReader.hash(data) }
        return value
    }()
    public init(version: String, build: String, toolSchemaRevision: Int) { self.version = version; self.build = build; self.toolSchemaRevision = toolSchemaRevision }
}

public enum AgentWorkflow {
    public static let schemaRevision = 2
    public static let tools = ["get_agent_state", "list_activity_history", "start_test_catalogue", "get_test_catalogue", "validate_selected_tests", "run_verified_tests", "get_preparation_state", "get_activity_changes", "preview_artifact_cleanup", "cleanup_activity_artifacts", "get_build_products", "select_build_product", "run_simulator_app", "open_simulator_deeplink", "prepare_simulator_scenario", "start_simulator_check", "get_simulator_check", "finish_simulator_check", "start_simulator_recording", "stop_simulator_recording"]
    public static let mutations: Set<String> = ["start_test_catalogue", "run_verified_tests", "cleanup_activity_artifacts", "select_build_product", "run_simulator_app", "open_simulator_deeplink", "prepare_simulator_scenario", "start_simulator_check", "finish_simulator_check", "start_simulator_recording", "stop_simulator_recording"]
    public static var capabilities: BridgeValue {
        .object(["buildWorkflowVersion": .number(1), "agentWorkflowVersion": .number(2), "toolSchemaRevision": .number(Double(schemaRevision)), "projectBinding": .bool(true), "buildReadiness": .bool(true), "buildWait": .bool(true), "buildResults": .bool(true), "workflowCorrelation": .bool(true), "testCatalogue": .bool(true), "verifiedTestsCLI": .bool(true), "verifiedTestsXcodeMCP": .bool(false), "sourceRevision": .bool(true), "compactState": .bool(true), "preparationReceipts": .bool(true), "simulatorChecks": .bool(true), "artifactCleanup": .bool(true)])
    }
    public static func delivery(_ helper: AgentHelperIdentity?) -> BridgeValue {
        let compatible = helper?.toolSchemaRevision == schemaRevision
        return .object(["native": (try? .encode(AgentHelperIdentity.current)) ?? .null, "helper": (try? .encode(helper)) ?? .null, "requiredToolSchemaRevision": .number(Double(schemaRevision)), "compatibility": .string(helper == nil ? "unknown" : compatible ? "compatible" : "incompatible"), "hostCatalogueVerified": .bool(false), "nextStep": compatible ? .null : .object(["code": .string("reconnectPlugin"), "target": .string("Mimic"), "panelReopenRestartsMCP": .bool(false)])])
    }
}

/// A native validation handle owns the exact expanded selection and code identity.
public struct VerifiedTestSelection: Codable, Sendable {
    public let id: UUID
    public let catalogueID: UUID
    public let project: ProjectContext
    public let parameters: BuildParameters
    public let developer: String
    public let profileRevision: String?
    public let revision: SourceRevision
    public let owner: String?
    public let expectedCases: [String: [String]]
    public init(id: UUID = UUID(), catalogueID: UUID, project: ProjectContext, parameters: BuildParameters, developer: String, profileRevision: String?, revision: SourceRevision, owner: String?, expectedCases: [String: [String]] = [:]) {
        self.id = id; self.catalogueID = catalogueID; self.project = project; self.parameters = parameters; self.developer = developer; self.profileRevision = profileRevision; self.revision = revision; self.owner = owner; self.expectedCases = expectedCases
    }
    public static func expand(_ ids: [String], scope: String, catalogue: BuildTestCatalogue) throws -> (selected: [String], unknown: [String], suggestions: [String: [String]]) {
        guard ["method", "class"].contains(scope), !ids.isEmpty, ids.count <= 100 else { throw BuildError.arguments }
        let known = Set(catalogue.tests.map(\.id))
        var selected = Set<String>(), unknown: [String] = [], suggestions: [String: [String]] = [:]
        for id in ids {
            let parts = id.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 2 && scope == "class" {
                let leaves = known.filter { $0.hasPrefix(id + "/") }
                if leaves.isEmpty { unknown.append(id) } else { selected.formUnion(leaves) }
            } else if parts.count == 3 && known.contains(id) { selected.insert(id) }
            else {
                unknown.append(id)
                suggestions[id] = catalogue.tests.filter { test in
                    test.id == id + "()" || parts.count >= 2 && test.target == String(parts[0]) && test.className == String(parts[1])
                }.prefix(10).map(\.id)
            }
        }
        guard selected.count <= 100 else { throw BuildError.capacity }
        return (selected.sorted(), unknown, suggestions)
    }
}
