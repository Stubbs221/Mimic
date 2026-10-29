//
//  SelectionIntegration.swift
//  Mimic
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import MimicCore

extension MimicIntegration {
    var selectionStore: TestSelectionStore { .init(root: model.builds.artifactRoot) }

    /// Every draft is bound to the same native catalogue and source checks as the short selection path.
    func selectionRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        let p = request.parameters, thread = request.threadID
        let owner = request.threadID ?? (request.clientName == "Terminal" ? "terminal" : "desktop")
        try WorkflowContract.validate(p, method: request.method)
        if ["start_ci_evidence", "get_ci_evidence", "list_test_artifacts", "get_test_artifact"].contains(request.method) { return try await evidenceRequest(request) }
        if request.method == "cancel_workflow_pending" {
            guard let workflow = p["workflowID"]?.string.flatMap(UUID.init(uuidString:)), let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)) else { throw WorkflowFieldError("invalidUUID", field: "workflowID") }
            return try model.builds.cancelWorkflowPending(workflow.uuidString, owner: owner, requestID: id)
        }
        if request.method == "get_test_facts" {
            let record = try accessibleBuild(p["activityID"], thread: thread)
            let result = try await model.builds.result(record.id)
            guard canAccess(record.project, threadID: thread) else { throw BuildError.context }
            let facts = result.executions ?? []
            let indexed = facts.enumerated().map { (id: String($0.offset), fact: $0.element) }
            var page = try paginate(indexed, cursor: p["cursor"], limit: p["limit"] ?? .number(100), id: { $0.id })
            while page.items.count > 1, try JSONEncoder().encode(page.items.map(\.fact)).count > 256 * 1024 {
                page.items.removeLast(); page.next = page.items.last?.id
            }
            return .object(["items": try .encode(page.items.map(\.fact)), "nextCursor": page.next.map(BridgeValue.string) ?? .null, "total": .number(Double(facts.count)), "verification": result.verification?.compactMetadata ?? .null])
        }
        if request.method == "create_test_selection" {
            let project = try expected(p["context"] ?? .null, threadID: thread)
            let record = try accessibleBuild(p["catalogueID"], thread: thread)
            guard let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)) else { throw WorkflowFieldError("invalidUUID", field: "requestID") }
            if let saved = try selectionStore.load(id) {
                guard saved.owner == owner, saved.project == project, saved.catalogueID == record.id else { throw BuildError.duplicate }
                return try selectionMetadata(saved, p: p)
            }
            guard record.project == project, record.status == .succeeded, let catalogue = record.testCatalogue, record.profileRevision == model.activeProfile?.revision else { throw BuildError.context }
            let revision = try await sourceRevision(project)
            let pinned = try await BuildDiscovery.pinned(project)
            guard revision == record.sourceProvenance?.finished, record.sourceProvenance?.stability == "unchangedObserved", pinned.developerDirectory == catalogue.developerDirectory else { throw BuildError.sourceChanged }
            _ = try expected(p["context"] ?? .null, threadID: thread)
            guard record.profileRevision == model.activeProfile?.revision else { throw BuildError.context }
            // A concurrent create may have finalized this handle while freshness was captured.
            // Replaying the original request must never replace that manifest with a new draft.
            if let saved = try selectionStore.load(id) {
                guard saved.owner == owner, saved.project == project, saved.catalogueID == record.id else { throw BuildError.duplicate }
                return try selectionMetadata(saved, p: p)
            }
            var parameters = record.parameters; parameters.intent = nil; parameters.operation = .test; parameters.testIdentifiers = []
            var selection = VerifiedTestSelection(id: id, catalogueID: record.id, project: project, parameters: parameters, developer: catalogue.developerDirectory, profileRevision: record.profileRevision, revision: revision, owner: owner)
            selection.state = "draft"
            try selectionStore.save(selection)
            return try selectionMetadata(selection, p: p)
        }
        guard let id = p["selectionID"]?.string.flatMap(UUID.init(uuidString:)), var selection = try selectionStore.load(id), selection.owner == owner, canAccess(selection.project, threadID: thread) else { throw BuildError.selectionExpired }
        if request.method == "append_test_selection" {
            guard let values = p["testIdentifiers"]?.array, values.allSatisfy({ $0.string != nil }), let requestID = p["requestID"]?.string.flatMap(UUID.init(uuidString:)) else { throw WorkflowFieldError("invalidIdentifiers", field: "testIdentifiers") }
            try selectionStore.append(values.compactMap(\.string), requestID: requestID, to: &selection)
            try selectionStore.save(selection)
        } else if request.method == "finalize_test_selection" {
            let project = try expected(p["context"] ?? .null, threadID: thread)
            guard !selection.expired, project == selection.project, selection.profileRevision == model.activeProfile?.revision, let catalogue = model.builds.activity(selection.catalogueID)?.testCatalogue else { throw BuildError.selectionExpired }
            let revision = try await sourceRevision(project)
            let developer = try await BuildDiscovery.pinned(project).developerDirectory
            _ = try expected(p["context"] ?? .null, threadID: thread)
            guard revision == selection.revision, developer == selection.developer, selection.profileRevision == model.activeProfile?.revision else { throw BuildError.sourceChanged }
            // Reload after suspension: another page may have been added while freshness was captured.
            guard let latest = try selectionStore.load(id), latest.owner == owner else { throw BuildError.selectionExpired }; selection = latest
            let known = Set(catalogue.tests.map(\.id)), unknown = selection.parameters.testIdentifiers.filter { !known.contains($0) }
            if !unknown.isEmpty {
                let page = try paginate(unknown, cursor: p["cursor"], limit: p["limit"] ?? .number(100), id: { $0 })
                return .object(["valid": .bool(false), "code": .string("unknownOrDisabledIdentifier"), "unknown": try .encode(page.items), "nextCursor": page.next.map(BridgeValue.string) ?? .null, "total": .number(Double(unknown.count))])
            }
            guard !selection.parameters.testIdentifiers.isEmpty else { throw BuildError.testsRequired }
            selection.expectedCases = Dictionary(uniqueKeysWithValues: catalogue.tests.filter { selection.parameters.testIdentifiers.contains($0.id) && $0.caseIdentifiers != nil }.map { ($0.id, $0.caseIdentifiers!) })
            selection.digest = SourceRevisionReader.hash(try JSONEncoder().encode(selection.parameters.testIdentifiers))
            selection.state = "finalized"; try selectionStore.save(selection)
        }
        return try selectionMetadata(selection, p: p)
    }

    private func selectionMetadata(_ selection: VerifiedTestSelection, p: [String: BridgeValue]) throws -> BridgeValue {
        let page = try paginate(selection.parameters.testIdentifiers, cursor: p["cursor"], limit: p["limit"] ?? .number(100), id: { $0 })
        return .object(["selectionID": .string(selection.id.uuidString), "catalogueID": .string(selection.catalogueID.uuidString), "state": .string(selection.expired ? "expired" : selection.state ?? "expired"), "count": .number(Double(selection.parameters.testIdentifiers.count)), "digest": selection.digest.map(BridgeValue.string) ?? .null, "testIdentifiers": try .encode(page.items), "nextCursor": page.next.map(BridgeValue.string) ?? .null, "expiresAt": selection.createdAt.map { .string($0.addingTimeInterval(86400).ISO8601Format()) } ?? .null, "valid": .bool(!selection.expired && selection.state == "finalized")])
    }
}
