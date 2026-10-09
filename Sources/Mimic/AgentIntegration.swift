//
//  AgentIntegration.swift
//  Mimic
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import MimicCore

struct AgentCleanupPreview: Sendable {
    let activityID: UUID
    let project: ProjectContext
    let owner: String?
    let artifacts: [ManagedArtifact]
}

extension MimicIntegration {
    // MARK: - Strict public contract

    func agentRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        let p = request.parameters, method = request.method, thread = request.threadID
        if let helper = request.helperIdentity, helper.toolSchemaRevision != AgentWorkflow.schemaRevision, AgentWorkflow.mutations.contains(method) {
            return .object(["status": .string("blocked"), "code": .string("incompatibleToolSchema"), "delivery": AgentWorkflow.delivery(helper)])
        }
        let keys: [String: Set<String>] = [
            "get_agent_state": ["includeActions"], "list_activity_history": ["kind", "cursor", "limit", "status", "workflowID"],
            "start_test_catalogue": ["context", "parameters", "requestID", "workflowID"],
            "get_test_catalogue": ["catalogueID", "filter", "cursor", "limit"],
            "validate_selected_tests": ["catalogueID", "context", "testIdentifiers", "scope"],
            "run_verified_tests": ["selectionID", "context", "requestID", "workflowID"],
            "get_preparation_state": ["platform"], "get_activity_changes": ["activityID", "kind"],
            "preview_artifact_cleanup": ["activityID"], "cleanup_activity_artifacts": ["previewID", "requestID"],
            "get_build_products": ["activityID"], "select_build_product": ["activityID", "productID"],
            "run_simulator_app": ["context", "activityID", "productID", "sessionID", "requestID"],
            "open_simulator_deeplink": ["context", "sessionID", "scenarioID", "url", "requestID"],
            "prepare_simulator_scenario": ["context", "scenarioID", "requestID"],
            "start_simulator_check": ["sessionID", "workflowID", "requestID"], "get_simulator_check": ["checkID"],
            "finish_simulator_check": ["checkID"], "start_simulator_recording": ["checkID", "requestID"], "stop_simulator_recording": ["checkID"]
        ]
        let optional: Set<String> = ["includeActions", "filter", "cursor", "limit", "status"]
        let optionalWorkflow = ["list_activity_history", "start_test_catalogue", "run_verified_tests"].contains(method)
        guard let allowed = keys[method], Set(p.keys).isSubset(of: allowed), allowed.subtracting(optional).subtracting(optionalWorkflow ? ["workflowID"] : []).isSubset(of: Set(p.keys)),
              p.values.allSatisfy({ value in value.string.map { $0.utf8.count <= 4096 && !$0.contains("\0") } ?? true }) else { throw failure("arguments") }
        switch method {
        case "get_agent_state":
            guard p["includeActions"] == nil || p["includeActions"] == .bool(true) || p["includeActions"] == .bool(false) else { throw failure("arguments") }
            if let current = project(thread) { await model.refreshPanelContext(current.path) }
            return await agentState(thread: thread, includeActions: p["includeActions"] == .bool(true), helper: request.helperIdentity)
        case "get_preparation_state":
            guard let project = project(thread), let platform = p["platform"]?.string.flatMap(BootstrapPlatform.init(rawValue:)) else { throw failure("arguments") }
            return await model.preparationState(project: project, platform: platform)
        case "list_activity_history": return try activityHistory(p, thread: thread)
        case "start_test_catalogue":
            let project = try expected(p["context"] ?? .null, threadID: thread)
            guard let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)) else { throw BuildError.arguments }
            let parameters = try BuildBridge.parameters(p["parameters"] ?? .null, operation: .build, intent: .catalogue)
            guard parameters.backend == .cli else { throw BuildError.unsupported }
            if let existing = model.builds.activity(id) {
                guard canAccess(existing.project, threadID: thread), existing.project == project, existing.parameters == parameters, existing.workflowID == (try workflowID(p["workflowID"])) else { throw BuildError.duplicate }
                return BuildBridge.metadata(existing)
            }
            let revision = try await sourceRevision(project)
            let record = try await model.builds.submit(id: id, project: project, parameters: parameters, source: request.clientName ?? "Codex", workflowID: try workflowID(p["workflowID"]), sourceRevision: revision)
            return BuildBridge.metadata(record)
        case "get_test_catalogue":
            let record = try accessibleBuild(p["catalogueID"], thread: thread)
            guard record.parameters.intent == .catalogue else { throw BuildError.arguments }
            var result: [String: BridgeValue] = ["catalogueID": .string(record.id.uuidString), "activity": BuildBridge.summary(record), "complete": .bool(false)]
            guard let catalogue = record.testCatalogue else { return .object(result) }
            let revision = try await sourceRevision(record.project)
            let fresh = revision == record.sourceProvenance?.finished && record.sourceProvenance?.stability == "unchangedObserved"
            let filter = p["filter"]?.string ?? ""
            let tests = catalogue.tests.filter { filter.isEmpty || $0.id.localizedCaseInsensitiveContains(filter) }
            let page = try paginate(tests, cursor: p["cursor"], limit: p["limit"], id: { $0.id })
            var caseBudget = 100
            let response = page.items.map { test -> BuildTest in
                let cases = test.caseIdentifiers.map { Array($0.prefix(caseBudget)) }; caseBudget -= cases?.count ?? 0
                var value = BuildTest(id: test.id, target: test.target, className: test.className, name: test.name, caseIdentifiers: cases)
                value.caseIdentifiersTruncated = (test.caseIdentifiers?.count ?? 0) > (cases?.count ?? 0); return value
            }
            result["tests"] = try .encode(response); result["nextCursor"] = page.next.map(BridgeValue.string) ?? .null
            result["total"] = .number(Double(tests.count)); result["sourceRevision"] = try .encode(revision)
            result["complete"] = .bool(record.status == .succeeded && fresh); result["stale"] = .bool(!fresh)
            return .object(result)
        case "validate_selected_tests":
            let project = try expected(p["context"] ?? .null, threadID: thread)
            let record = try accessibleBuild(p["catalogueID"], thread: thread)
            guard record.project == project, record.profileRevision == model.activeProfile?.revision, record.status == .succeeded, let catalogue = record.testCatalogue,
                  let ids = p["testIdentifiers"]?.array, ids.allSatisfy({ $0.string != nil }), let scope = p["scope"]?.string else { throw BuildError.arguments }
            let revision = try await sourceRevision(project)
            guard revision == record.sourceProvenance?.finished, record.sourceProvenance?.stability == "unchangedObserved" else { throw BuildError.sourceChanged }
            let pinned = try await BuildDiscovery.pinned(project)
            guard pinned.developerDirectory == catalogue.developerDirectory, project == self.project(thread), model.activeProfile?.revision == record.profileRevision else { throw BuildError.context }
            let expanded = try VerifiedTestSelection.expand(ids.compactMap(\.string), scope: scope, catalogue: catalogue)
            if !expanded.unknown.isEmpty { return .object(["valid": .bool(false), "code": .string("unknownIdentifier"), "unknown": try .encode(expanded.unknown), "suggestions": try .encode(expanded.suggestions)]) }
            guard agentSelections.count < 1024 else { throw BuildError.capacity }
            var parameters = record.parameters; parameters.intent = nil; parameters.operation = .test; parameters.testIdentifiers = expanded.selected
            let selection = VerifiedTestSelection(catalogueID: record.id, project: project, parameters: parameters, developer: catalogue.developerDirectory, profileRevision: record.profileRevision, revision: revision, owner: thread, expectedCases: Dictionary(uniqueKeysWithValues: catalogue.tests.filter { expanded.selected.contains($0.id) && $0.caseIdentifiers != nil }.map { ($0.id, $0.caseIdentifiers!) }))
            agentSelections[selection.id] = selection
            return .object(["valid": .bool(true), "selectionID": .string(selection.id.uuidString), "testIdentifiers": try .encode(expanded.selected), "sourceRevision": try .encode(revision)])
        case "run_verified_tests":
            let project = try expected(p["context"] ?? .null, threadID: thread)
            guard let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)), let selectionID = p["selectionID"]?.string.flatMap(UUID.init(uuidString:)) else { throw BuildError.arguments }
            let workflow = try workflowID(p["workflowID"])
            if let existing = model.builds.activity(id) {
                guard canAccess(existing.project, threadID: thread), existing.project == project, existing.selectionID == selectionID, existing.workflowID == workflow else { throw BuildError.duplicate }
                return BuildBridge.metadata(existing)
            }
            guard let selection = agentSelections[selectionID], selection.owner == thread, selection.project == project, selection.profileRevision == model.activeProfile?.revision else { throw BuildError.selectionExpired }
            guard try await BuildDiscovery.pinned(project).developerDirectory == selection.developer else { throw BuildError.context }
            let record = try await model.builds.submit(id: id, project: project, parameters: selection.parameters, source: request.clientName ?? "Codex", workflowID: workflow, sourceRevision: selection.revision, selectionID: selectionID, expectedCases: selection.expectedCases)
            return BuildBridge.metadata(record)
        case "get_activity_changes":
            let kind = p["kind"]?.string
            let changes: ActivityChanges?
            if kind == "build" { changes = try accessibleBuild(p["activityID"], thread: thread).changes }
            else if kind == "task", let id = p["activityID"]?.string.flatMap(UUID.init(uuidString:)), let record = model.records.first(where: { $0.id == id }), canAccess(record.project, threadID: thread) { changes = record.changes }
            else { throw BuildError.notFound }
            return .object(["changes": try .encode(changes), "attribution": .string("observationsOnly")])
        case "preview_artifact_cleanup":
            let record = try accessibleBuild(p["activityID"], thread: thread)
            let paths = try model.builds.artifacts(record.id), root = model.builds.artifactRoot
            let artifacts = try await Task.detached { try paths.map { try ManagedArtifactReader.inspect($0, root: root) } }.value
            guard canAccess(record.project, threadID: thread), !(model.builds.activity(record.id)?.status.isPending ?? true), !model.builds.artifactLeases.contains(record.id) else { throw BuildError.context }
            guard cleanupPreviews.count < 100 else { throw BuildError.capacity }
            let id = UUID(); cleanupPreviews[id] = .init(activityID: record.id, project: record.project, owner: thread, artifacts: artifacts)
            return .object(["previewID": .string(id.uuidString), "artifacts": try .encode(artifacts), "origin": .string("managedOutput")])
        case "cleanup_activity_artifacts": return try await cleanupArtifacts(p, thread: thread)
        default: return try await simulatorAgentRequest(request)
        }
    }

    // MARK: - Bounded state and stable history cursors

    func sourceRevision(_ project: ProjectContext) async throws -> SourceRevision {
        let exclusions = model.activeProfile?.profile.sourceExclusions ?? []
        return try await Task.detached { try SourceRevisionReader.capture(path: project.path, exclusions: exclusions) }.value
    }
    func accessibleBuild(_ value: BridgeValue?, thread: String?) throws -> BuildActivity {
        guard let id = value?.string.flatMap(UUID.init(uuidString:)), let record = model.builds.activity(id), canAccess(record.project, threadID: thread) else { throw BuildError.notFound }; return record
    }
    func paginate<T>(_ values: [T], cursor: BridgeValue?, limit: BridgeValue?, id: (T) -> String) throws -> (items: [T], next: String?) {
        guard cursor == nil || cursor?.string != nil, limit == nil || limit?.integer != nil else { throw BuildError.arguments }
        let limit = limit?.integer ?? 20; guard (1...100).contains(limit) else { throw BuildError.arguments }
        let start: Int
        if let cursor = cursor?.string { guard let index = values.firstIndex(where: { id($0) == cursor }) else { throw BuildError.context }; start = index + 1 }
        else { start = 0 }
        let items = Array(values.dropFirst(start).prefix(limit)); return (items, start + items.count < values.count ? items.last.map(id) : nil)
    }
    func agentState(thread: String?, includeActions: Bool, helper: AgentHelperIdentity?) async -> BridgeValue {
        let current = project(thread)
        let builds = model.builds.records.filter { $0.project.path == current?.path && ($0.status.isPending || $0.status == .unknown) }.map(BuildBridge.summary)
        let tasks = model.records.filter { $0.project.path == current?.path && [.queued, .running].contains($0.status) }.map(task)
        let simulators = model.simulatorScreen.records.filter { $0.project.path == current?.path && ($0.status.isPending || $0.holdsQueue) }.map(\.metadata)
        var blockers: [BridgeValue] = []
        if current == nil { blockers.append(.object(["code": .string("needsBinding")])) }
        if model.admissionsClosed { blockers.append(.object(["code": .string("admissionsClosed")])) }
        if model.builds.records.contains(where: { $0.status == .unknown }) || model.simulatorScreen.records.contains(where: { $0.status == .unknown && $0.holdsQueue }) { blockers.append(.object(["code": .string("unknownOperation")])) }
        if model.switchingBranch { blockers.append(.object(["code": .string("branchSwitch")])) }
        if let helper, helper.toolSchemaRevision != AgentWorkflow.schemaRevision { blockers.append(.object(["code": .string("reconnectPlugin")])) }
        let preparation = current == nil ? BridgeValue.null : await model.preparationState(project: current!, platform: .ios)
        if preparation["blocking"] == .bool(true) { blockers.append(.object(["code": .string("preparationRequired")])) }
        let all = builds + tasks + simulators
        var fields: [String: BridgeValue] = ["version": .number(2), "context": current.map { Self.context($0, profile: model.activeProfile) } ?? .null,
            "needsBinding": .bool(current == nil), "capabilities": AgentWorkflow.capabilities, "delivery": AgentWorkflow.delivery(helper), "blockers": .array(blockers),
            "active": .array(all), "queue": .object(["tasks": .number(Double(model.records.filter { [.running, .queued].contains($0.status) }.count)), "builds": .number(Double(model.builds.records.filter { $0.status.isPending || $0.status == .unknown }.count)), "simulator": .number(Double(model.simulatorScreen.records.filter { $0.status.isPending || $0.holdsQueue }.count))]), "preparation": preparation,
            "simulator": .object(["activeOperations": .number(Double(simulators.count)), "sessions": (try? .encode(simulatorBindings.values.filter { $0.project.path == current?.path })) ?? .array([])])]
        if includeActions { fields["actions"] = .array((model.activeProfile?.profile.actions.filter(\.allowsMCP) ?? []).map { .object(["id": .string($0.id), "title": .string($0.title), "parameters": (try? .encode($0.parameters)) ?? .null]) }) }
        return .object(fields)
    }
    func activityHistory(_ p: [String: BridgeValue], thread: String?) throws -> BridgeValue {
        guard let current = project(thread), let kind = p["kind"]?.string, ["build", "task", "simulator", "remote"].contains(kind), p["status"] == nil || p["status"]?.string != nil else { throw BuildError.arguments }
        var values: [BridgeValue]
        switch kind {
        case "build": values = model.builds.records.filter { $0.project.path == current.path }.reversed().map(BuildBridge.summary)
        case "task": values = model.records.filter { $0.project.path == current.path }.reversed().map(task)
        case "simulator": values = model.simulatorScreen.records.filter { $0.project.path == current.path }.reversed().map(\.metadata)
        default: values = model.profileRemote.runs.filter { $0.checkout.path == current.path }.map(profileRemoteSummary)
        }
        if let status = p["status"]?.string { values = values.filter { $0["status"].string == status } }
        if let workflow = p["workflowID"] { guard workflow.string.flatMap(UUID.init(uuidString:)) != nil else { throw BuildError.arguments }; values = values.filter { $0["workflowID"] == workflow } }
        let page = try paginate(values, cursor: p["cursor"], limit: p["limit"], id: { $0["id"].string! })
        return .object(["items": .array(page.items), "nextCursor": page.next.map(BridgeValue.string) ?? .null])
    }

    // MARK: - Explicit managed artifact cleanup

    func cleanupArtifacts(_ p: [String: BridgeValue], thread: String?) async throws -> BridgeValue {
        guard let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)), let previewID = p["previewID"]?.string.flatMap(UUID.init(uuidString:)) else { throw BuildError.arguments }
        let key = id.uuidString
        if let entry = cleanupLedger[key] {
            guard entry["previewID"] == .string(previewID.uuidString), entry["owner"] == thread.map(BridgeValue.string) ?? .null else { throw BuildError.duplicate }
            if let activity = entry["activityID"].string.flatMap(UUID.init(uuidString:)).flatMap(model.builds.activity) {
                var fields = entry.object ?? [:]; fields["status"] = .string(activity.status.rawValue); fields["removed"] = try .encode(activity.cleanupRemoved ?? []); return .object(fields)
            }
            return entry
        }
        if let existing = model.builds.activity(id) {
            guard canAccess(existing.project, threadID: thread), let preview = cleanupPreviews[previewID], preview.activityID == existing.cleanupActivityID, preview.artifacts == existing.cleanupArtifacts else { throw BuildError.duplicate }
            return BuildBridge.metadata(existing)
        }
        guard let preview = cleanupPreviews[previewID], preview.owner == thread, canAccess(preview.project, threadID: thread) else { throw BuildError.context }
        let paths = try model.builds.artifacts(preview.activityID), root = model.builds.artifactRoot
        let current = try await Task.detached { try paths.map { try ManagedArtifactReader.inspect($0, root: root) } }.value
        guard current == preview.artifacts, !model.builds.artifactLeases.contains(preview.activityID), canAccess(preview.project, threadID: thread) else { throw BuildError.sourceChanged }
        guard let project = project(thread) else { throw BuildError.context }
        var parameters = try accessibleBuild(.string(preview.activityID.uuidString), thread: thread).parameters
        guard parameters.backend == .cli else { throw BuildError.unsupported }
        parameters.intent = .cleanup; parameters.operation = .build; parameters.testIdentifiers = []; parameters.testPlan = ""
        let record = try await model.builds.submit(id: id, project: project, parameters: parameters, source: "Codex", cleanupArtifacts: preview.artifacts, cleanupActivityID: preview.activityID)
        let fields: [String: BridgeValue] = ["previewID": .string(previewID.uuidString), "owner": thread.map(BridgeValue.string) ?? .null, "activityID": .string(record.id.uuidString), "status": .string(record.status.rawValue)]
        cleanupLedger[key] = .object(fields); try saveCleanupLedger(); return .object(fields)
    }

    func saveCleanupLedger() throws {
        let directory = model.supportDirectory.appendingPathComponent("Agent")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("cleanup.json"); try JSONEncoder().encode(cleanupLedger).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
