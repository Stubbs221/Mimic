//
//  CIPresentation.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation

// MARK: - Feed metadata

/// Only the title is retained; author emails and full commit messages are not needed by CI.
public struct CICommit: Decodable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// One identity survives the transition from a Jenkins queue item to a GitLab pipeline.
public struct CIFeedEntry: Identifiable, Sendable {
    public let pipeline: CIPipeline?
    public let run: RemoteTestRun?
    public let participant: CIUser?
    public var id: String { self.run.map { "run." + $0.id.uuidString } ?? "pipeline.\(self.pipeline!.id)" }
    public var createdAt: Date? { self.pipeline?.createdAt ?? self.run?.createdAt }
    public var status: String { self.pipeline?.status ?? self.run?.status ?? "unknown" }
    public var branch: String { self.pipeline?.ref ?? self.run?.branch ?? "" }
    public var sha: String? { self.pipeline?.sha ?? self.run?.sha }
    public init(pipeline: CIPipeline?, run: RemoteTestRun? = nil, participant: CIUser? = nil) {
        precondition(pipeline != nil || run != nil)
        self.pipeline = pipeline; self.run = run; self.participant = participant
    }
}

// MARK: - Check progress

/// Completion measures checks, not elapsed time. Partial child data must never imply a percentage.
public struct CIProgressSummary: Sendable {
    public let jobs: [CIJob]
    public let bridges: [CIBridge]
    public let complete: Bool
    public let commitTitle: String?
    public var running: [CIJob] { self.jobs.filter { $0.status == "running" } }
    public var failed: [CIJob] { self.jobs.filter { $0.status == "failed" && !$0.allowFailure }.sorted { $0.id < $1.id } }
    public var waitingForManual: Bool {
        self.jobs.contains { $0.status == "manual" && !$0.allowFailure } || self.bridges.contains { $0.status == "manual" && $0.allowFailure != true }
    }
    private var countedJobs: [CIJob] { self.jobs.filter { !($0.status == "manual" && $0.allowFailure) } }
    private var countedBridges: [CIBridge] { self.bridges.filter { !($0.status == "manual" && $0.allowFailure == true) } }
    public var total: Int { self.countedJobs.count + self.countedBridges.count }
    public var completed: Int {
        let terminal = ["success", "failed", "canceled", "skipped"]
        return self.countedJobs.filter { terminal.contains($0.status) }.count + self.countedBridges.filter { terminal.contains($0.downstreamPipeline?.status ?? $0.status) }.count
    }
    public init(jobs: [CIJob], bridges: [CIBridge] = [], complete: Bool = true, commitTitle: String? = nil) {
        var seen = Set<Int>()
        self.jobs = jobs.sorted { $0.id > $1.id }.filter { seen.insert($0.id).inserted }
        self.bridges = bridges; self.complete = complete
        self.commitTitle = commitTitle
    }
}

// MARK: - GitLabService

public enum CILoadState: Sendable { case notRequested, loading, loaded, partial, failed }

extension GitLabService {
    /// Older fixture/adaptor implementations can omit optional commit metadata.
    public func commit(connection: GitLabConnection, sha: String, token: String) async throws -> CICommit { throw CIError.notFound }

    /// Bound traversal by exact project/pipeline identity, with no unbounded child requests.
    public func progress(connection: GitLabConnection, pipelineID: Int, token: String, root suppliedRoot: CIPipelineDetails? = nil, failedOnly: Bool = false, loadChild: (@Sendable (GitLabConnection, Int) async throws -> CIPipelineDetails)? = nil) async throws -> CIProgressSummary {
        let root: CIPipelineDetails
        if let suppliedRoot { root = suppliedRoot }
        else { root = try await self.details(connection: connection, pipelineID: pipelineID, token: token) }
        if let failure = root.bridgeError {
            if failure.pausesPolling && failure != .forbidden { throw failure }
            if case .rateLimited = failure { throw failure }
        }
        var jobs = root.jobs, bridges: [CIBridge] = []
        var complete = root.bridgeError == nil
        var queue = root.bridges.filter { !failedOnly || $0.status == "failed" || $0.downstreamPipeline?.status == "failed" }.map { ($0, 1) }
        var seen: Set<String> = ["\(connection.projectID):\(pipelineID)"]
        var children = 0
        while !queue.isEmpty {
            try Task.checkCancellation()
            let (bridge, depth) = queue.removeFirst()
            guard let child = bridge.downstreamPipeline else { bridges.append(bridge); continue }
            let projectID = child.projectID ?? connection.projectID
            let identity = "\(projectID):\(child.id)"
            guard !seen.contains(identity) else { continue }
            guard depth <= 3, children < 20, JenkinsClient.sameOrigin(child.webURL, connection.baseURL) else {
                complete = false; bridges.append(bridge); continue
            }
            seen.insert(identity); children += 1
            let childConnection = GitLabConnection(id: connection.id, baseURL: connection.baseURL, projectID: projectID, projectPath: connection.projectPath)
            do {
                let details: CIPipelineDetails
                if let loadChild { details = try await loadChild(childConnection, child.id) }
                else { details = try await self.details(connection: childConnection, pipelineID: child.id, token: token) }
                jobs += details.jobs; complete = complete && details.bridgeError == nil
                queue += details.bridges.filter { !failedOnly || $0.status == "failed" || $0.downstreamPipeline?.status == "failed" }.map { ($0, depth + 1) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if let failure = error as? CIError, failure.pausesPolling && failure != .forbidden { throw failure }
                if case CIError.rateLimited = error { throw error }
                complete = false; bridges.append(bridge)
            }
        }
        return CIProgressSummary(jobs: jobs, bridges: bridges, complete: complete, commitTitle: root.jobs.first(where: { $0.commit != nil })?.commit?.title)
    }
}
