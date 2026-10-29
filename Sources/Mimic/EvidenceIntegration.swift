//
//  EvidenceIntegration.swift
//  Mimic
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import MimicCore

struct StoredCIEvidence: Codable {
    let owner: String?
    let snapshot: CIAnalysisSnapshot
    let evidence: CIEvidence
}

extension MimicIntegration {
    /// Evidence is a read-only observer of an immutable snapshot, outside the local execution FIFO.
    func evidenceRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        let p = request.parameters, owner = request.threadID
        if request.method == "start_ci_evidence" {
            guard let id = p["snapshotID"]?.string.flatMap(UUID.init(uuidString:)) else { throw BuildError.arguments }
            let snapshot = try CIAnalysisSnapshotStore(root: model.builds.artifactRoot).load(id)
            guard canAccess(snapshot.project, threadID: owner), let state = model.ciMonitor.state(for: snapshot.summary), state.context?.connection == snapshot.connection else { throw BuildError.context }
            if let existing = ciEvidenceQueries.first(where: { $0.value.owner == owner && $0.value.snapshot.taskID == id && ciEvidenceResults[$0.key] == nil }) { return .object(["queryID": .string(existing.key.uuidString), "snapshotID": .string(id.uuidString)]) }
            guard ciEvidenceQueries.count < 128 else { throw BuildError.capacity }
            let query = UUID(), root = model.builds.artifactRoot
            let task = Task { [weak self] in
                do {
                    let result = try await state.collectEvidence(snapshot)
                    let stored = StoredCIEvidence(owner: owner, snapshot: snapshot, evidence: result)
                    try JSONEncoder().encode(stored).write(to: root.appendingPathComponent("CIAnalysis").appendingPathComponent(query.uuidString + ".evidence.json"), options: .atomic)
                    self?.ciEvidenceResults[query] = .success(result)
                    return result
                } catch {
                    self?.ciEvidenceResults[query] = .failure(error)
                    throw error
                }
            }
            ciEvidenceQueries[query] = (owner, snapshot, task)
            return .object(["queryID": .string(query.uuidString), "snapshotID": .string(id.uuidString), "status": .string("collecting")])
        }
        if request.method == "get_ci_evidence" {
            guard let id = p["queryID"]?.string.flatMap(UUID.init(uuidString:)) else { throw BuildError.arguments }
            let evidence: CIEvidence
            if let query = ciEvidenceQueries[id] {
                guard query.owner == owner, canAccess(query.snapshot.project, threadID: owner) else { throw BuildError.notFound }
                guard let outcome = ciEvidenceResults[id] else { return .object(["queryID": .string(id.uuidString), "status": .string("collecting")]) }
                switch outcome {
                case let .success(value): evidence = value
                case let .failure(error): return .object(["queryID": .string(id.uuidString), "status": .string("unavailable"), "complete": .bool(false), "code": .string((error as? CIError)?.localizationKey ?? "evidenceUnavailable")])
                }
            } else {
                let path = model.builds.artifactRoot.appendingPathComponent("CIAnalysis").appendingPathComponent(id.uuidString + ".evidence.json")
                let saved = try JSONDecoder().decode(StoredCIEvidence.self, from: Data(contentsOf: path))
                guard saved.owner == owner, canAccess(saved.snapshot.project, threadID: owner) else { throw BuildError.notFound }; evidence = saved.evidence
            }
            let page = try paginate(evidence.items, cursor: p["cursor"], limit: p["limit"] ?? .number(50), id: { $0.id })
            return .object(["queryID": .string(id.uuidString), "status": .string("ready"), "snapshotID": .string(evidence.snapshotID.uuidString), "checkedAt": .string(evidence.checkedAt.ISO8601Format()), "originalJobIDs": try .encode(evidence.originalJobIDs), "originalCheckIDs": try .encode(evidence.originalCheckIDs), "sha": evidence.selectedSHA.map(BridgeValue.string) ?? .null, "ref": .string(evidence.selectedRef), "complete": .bool(evidence.complete), "sources": try .encode(evidence.sources), "items": try .encode(page.items), "total": .number(Double(evidence.items.count)), "nextCursor": page.next.map(BridgeValue.string) ?? .null, "responseTruncated": .bool(page.next != nil)])
        }
        let storage = TestArtifactStore(root: model.builds.artifactRoot)
        if request.method == "get_test_artifact" {
            guard let id = p["artifactID"]?.string.flatMap(UUID.init(uuidString:)) else { throw BuildError.arguments }
            let artifact: TestImageArtifact
            do { artifact = try storage.artifact(id) }
            catch BuildError.notFound { return .object(["availability": .string("unavailable"), "reason": .string("artifactExpiredOrUnknown")]) }
            _ = try accessibleBuild(.string(artifact.activityID.uuidString), thread: owner)
            guard !model.builds.artifactLeases.contains(artifact.activityID), !model.builds.artifactCleanupReserved(artifact.activityID) else { throw WorkflowFieldError("busy", field: "artifactID", existingActivityID: artifact.activityID) }
            guard FileManager.default.fileExists(atPath: artifact.originalPath) else { return .object(["availability": .string("unavailable"), "reason": .string("artifactExpired")]) }
            model.builds.artifactLeases.insert(artifact.activityID)
            defer { model.builds.artifactLeases.remove(artifact.activityID) }
            let image = try await Task.detached { try storage.preview(artifact) }.value
            _ = try accessibleBuild(.string(artifact.activityID.uuidString), thread: owner)
            return .object(["artifact": try .encode(artifact), "image": .string(image.base64EncodedString()), "mimeType": .string("image/jpeg"), "preview": .bool(true)])
        }
        let record = try accessibleBuild(p["activityID"], thread: owner)
        guard let method = p["methodID"]?.string else { throw BuildError.arguments }
        guard !model.builds.artifactLeases.contains(record.id), !model.builds.artifactCleanupReserved(record.id) else { throw WorkflowFieldError("busy", field: "activityID", existingActivityID: record.id) }
        model.builds.artifactLeases.insert(record.id)
        defer { model.builds.artifactLeases.remove(record.id) }
        let result = try await model.builds.result(record.id), facts = result.executions ?? []
        let catalogue = try await Task.detached { try storage.list(record: record, methodID: method, facts: facts) }.value
        _ = try accessibleBuild(.string(record.id.uuidString), thread: owner)
        let page = try paginate(catalogue.items, cursor: p["cursor"], limit: p["limit"], id: { $0.id.uuidString })
        return .object(["availability": .string(catalogue.availability), "reason": catalogue.reason.map(BridgeValue.string) ?? .null, "items": try .encode(page.items), "nextCursor": page.next.map(BridgeValue.string) ?? .null])
    }
}
