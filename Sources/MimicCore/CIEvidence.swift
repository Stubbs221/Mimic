//
//  CIEvidence.swift
//  MimicCore
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation

/// Only allowlisted facts cross the CI boundary. Raw report output is never retained.
public struct CIEvidenceItem: Codable, Sendable {
    public let id: String
    public let kind: String
    public let projectID: Int
    public let pipelineID: Int
    public let source: String
    public let facts: BridgeValue
}

public struct CIEvidenceSource: Codable, Sendable {
    public let path: String
    public var complete: Bool
    public var error: String?
}

public struct CIEvidence: Codable, Sendable {
    public let snapshotID: UUID
    public let checkedAt: Date
    public let selectedSHA: String?
    public let selectedRef: String
    public var originalJobIDs: [Int] = []
    public var originalCheckIDs: [Int] = []
    public var items: [CIEvidenceItem] = []
    public var sources: [CIEvidenceSource] = []
    public var complete: Bool { !sources.isEmpty && sources.allSatisfy(\.complete) }
}

public protocol CIEvidenceService: Sendable {
    func evidence(snapshot: CIAnalysisSnapshot, connection: GitLabConnection, token: String) async throws -> CIEvidence
}

extension GitLabClient: CIEvidenceService {
    /// Read one pinned pipeline graph. Each endpoint reports its own completeness, including partial pages.
    public func evidence(snapshot: CIAnalysisSnapshot, connection: GitLabConnection, token: String) async throws -> CIEvidence {
        guard let rootID = snapshot.summary.pipelineID else { throw CIError.invalidConfiguration }
        var result = CIEvidence(snapshotID: snapshot.taskID, checkedAt: Date(), selectedSHA: snapshot.summary.sha, selectedRef: snapshot.summary.branch)
        result.originalCheckIDs = snapshot.summary.failedChecks?.map(\.id) ?? []
        var pending = [(connection.projectID, rootID, 0)], visited = Set<String>()
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        func errorCode(_ error: Error) -> String {
            switch error {
            case CIError.forbidden: "forbidden"
            case CIError.authentication, CIError.credential: "authentication"
            case CIError.notFound: "notFound"
            case CIError.rateLimited: "rateLimited"
            case is CancellationError: "cancelled"
            default: "unavailable"
            }
        }
        func pages(_ path: String, arrayKey: String? = nil, query: [URLQueryItem] = []) async -> [[String: Any]] {
            var values: [[String: Any]] = [], page = "1", seen = Set<String>(), source = CIEvidenceSource(path: path, complete: false)
            do {
                repeat {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw CIError.network }
                    guard let number = Int(page), number > 0, seen.insert(page).inserted, seen.count <= 20 else { throw CIError.invalidResponse }
                    let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: path, query: query + [URLQueryItem(name: "page", value: page), URLQueryItem(name: "per_page", value: "100")], token: token)
                    guard !response.moreData, response.data.count <= 8 * 1024 * 1024 else { throw CIError.invalidResponse }
                    let object = try JSONSerialization.jsonObject(with: response.data)
                    let rows = arrayKey.flatMap { (object as? [String: Any])?[$0] as? [[String: Any]] } ?? (object as? [[String: Any]])
                    guard let rows else { throw CIError.invalidResponse }
                    guard values.count + rows.count <= 20_000 else { throw CIError.invalidResponse }
                    values += rows
                    page = response.nextPage ?? ""
                } while !page.isEmpty
                source.complete = true
            } catch { source.error = errorCode(error) }
            result.sources.append(source)
            return values
        }
        func safe(_ value: Any?) -> BridgeValue {
            guard let value = value as? String else { return .null }
            return .string(DiagnosticText.bounded(DiagnosticText.clean(value), limit: 1024).text)
        }
        while !pending.isEmpty {
            let (projectID, pipelineID, depth) = pending.removeFirst(), identity = "\(projectID)/\(pipelineID)"
            guard depth <= 5, visited.count < 50, visited.insert(identity).inserted else {
                result.sources.append(.init(path: identity, complete: false, error: "graphBudgetOrCycle")); continue
            }
            let prefix = "projects/\(projectID)/pipelines/\(pipelineID)"
            do {
                guard ContinuousClock.now < deadline else { throw CIError.network }
                let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: prefix, token: token)
                let pipeline = try decode(CIPipeline.self, data: response.data)
                guard pipeline.id == pipelineID, pipeline.projectID == nil || pipeline.projectID == projectID,
                      depth != 0 || snapshot.summary.sha == nil || snapshot.summary.sha == pipeline.sha,
                      depth != 0 || snapshot.summary.branch == pipeline.ref else { throw CIError.invalidResponse }
                result.items.append(.init(id: identity, kind: "pipeline", projectID: projectID, pipelineID: pipelineID, source: prefix,
                    facts: .object(["sha": .string(pipeline.sha), "ref": .string(pipeline.ref), "status": .string(pipeline.status), "url": .string(pipeline.webURL.absoluteString)])))
                result.sources.append(.init(path: prefix, complete: true))
            } catch { result.sources.append(.init(path: prefix, complete: false, error: errorCode(error))); continue }
            let jobs = await pages(prefix + "/jobs", query: [URLQueryItem(name: "include_retried", value: "true")])
            let mandatory = Set(jobs.filter { ($0["allow_failure"] as? Bool) == false && ($0["status"] as? String) == "failed" }.compactMap { $0["id"] as? Int })
            for job in jobs {
                guard let id = job["id"] as? Int else { result.sources.append(.init(path: prefix + "/jobs", complete: false, error: "missingJobIdentity")); continue }
                let candidates = jobs.filter { ($0["id"] as? Int) != id && ($0["name"] as? String) == (job["name"] as? String) && ($0["stage"] as? String) == (job["stage"] as? String) }.compactMap { $0["id"] as? Int }
                var facts: [String: BridgeValue] = ["jobID": .number(Double(id)), "name": safe(job["name"]), "stage": safe(job["stage"]), "status": safe(job["status"]), "url": safe(job["web_url"]), "allowFailure": (job["allow_failure"] as? Bool).map(BridgeValue.bool) ?? .null, "failureReason": safe(job["failure_reason"]), "retryRelationship": .string("unknown"), "retryCandidates": .array(candidates.map { .number(Double($0)) }), "xcode": .null, "swift": .null, "sdk": .null]
                if let manager = job["runner_manager"] as? [String: Any] { facts["runner"] = .object(["version": safe(manager["version"]), "platform": safe(manager["platform"]), "architecture": safe(manager["architecture"])]) }
                result.items.append(.init(id: identity + "/job/\(id)", kind: "job", projectID: projectID, pipelineID: pipelineID, source: prefix + "/jobs", facts: .object(facts)))
            }
            let summaries = await pages(prefix + "/test_report_summary", arrayKey: "test_suites")
            let suites = await pages(prefix + "/test_report", arrayKey: "test_suites")
            if !mandatory.isEmpty, summaries.isEmpty || suites.isEmpty { result.sources.append(.init(path: prefix + "/test_report", complete: false, error: "emptyReport")) }
            for (suiteIndex, suite) in suites.enumerated() {
                let matches = summaries.filter { ($0["name"] as? String) == (suite["name"] as? String) }
                guard matches.count == 1, let ids = matches[0]["build_ids"] as? [Int] else {
                    let candidates = Set(matches.flatMap { $0["build_ids"] as? [Int] ?? [] }).intersection(Set(jobs.compactMap { $0["id"] as? Int }))
                    result.items.append(.init(id: identity + "/suite/\(suiteIndex)", kind: "suite", projectID: projectID, pipelineID: pipelineID, source: prefix + "/test_report",
                        facts: .object(["name": safe(suite["name"]), "jobRelationship": .string("unknown"), "jobCandidates": .array(candidates.sorted().map { .number(Double($0)) })])))
                    result.sources.append(.init(path: prefix + "/test_report", complete: false, error: "suiteJobRelationshipUnknown")); continue
                }
                let relevant = Set(ids).intersection(mandatory)
                guard !relevant.isEmpty else { continue }
                guard let tests = suite["test_cases"] as? [[String: Any]] else { result.sources.append(.init(path: prefix + "/test_report", complete: false, error: "testCasesUnavailable")); continue }
                for (testIndex, test) in tests.enumerated() where ["failed", "error"].contains(test["status"] as? String ?? "") {
                    result.items.append(.init(id: identity + "/suite/\(suiteIndex)/test/\(testIndex)", kind: "test", projectID: projectID, pipelineID: pipelineID, source: prefix + "/test_report", facts: .object(["suite": safe(suite["name"]), "classname": safe(test["classname"]), "name": safe(test["name"]), "status": safe(test["status"]), "jobIDs": .array(relevant.sorted().map { .number(Double($0)) })])))
                }
            }
            let bridges = await pages(prefix + "/bridges")
            for bridge in bridges {
                guard let id = bridge["id"] as? Int else { continue }
                result.items.append(.init(id: identity + "/bridge/\(id)", kind: "bridge", projectID: projectID, pipelineID: pipelineID, source: prefix + "/bridges", facts: .object(["name": safe(bridge["name"]), "status": safe(bridge["status"]), "url": safe(bridge["web_url"]), "allowFailure": (bridge["allow_failure"] as? Bool).map(BridgeValue.bool) ?? .null])))
                if (bridge["allow_failure"] as? Bool) == true { continue }
                if let child = bridge["downstream_pipeline"] as? [String: Any], let childID = child["id"] as? Int, let childProject = child["project_id"] as? Int { pending.append((childProject, childID, depth + 1)) }
                else { result.sources.append(.init(path: prefix + "/bridges/\(id)", complete: false, error: "downstreamUnavailable")) }
            }
        }
        let knownJobIDs = Set(result.items.filter { $0.kind == "job" }.compactMap { $0.facts["jobID"].integer })
        result.originalJobIDs = result.originalCheckIDs.filter(knownJobIDs.contains)
        return result
    }
}

/// Snapshots and evidence have immutable IDs; reading one never substitutes the latest pipeline.
public struct CIAnalysisSnapshotStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.appendingPathComponent("CIAnalysis") }
    public func save(_ snapshot: CIAnalysisSnapshot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent(snapshot.taskID.uuidString + ".json")
        if FileManager.default.fileExists(atPath: path.path) {
            let previous = try load(snapshot.taskID)
            guard previous.summary == snapshot.summary, previous.connection == snapshot.connection else { throw BuildError.duplicate }; return
        }
        try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
    }
    public func load(_ id: UUID) throws -> CIAnalysisSnapshot {
        try JSONDecoder().decode(CIAnalysisSnapshot.self, from: Data(contentsOf: root.appendingPathComponent(id.uuidString + ".json")))
    }
}
