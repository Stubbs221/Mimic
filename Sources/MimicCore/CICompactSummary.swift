// Created by Василий Маслов on 06.10.2026.
import Foundation

/// A failed mandatory job or unresolved downstream bridge; URLs always come from CI metadata.
public struct CIFailedCheck: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let url: URL
    public init(id: Int, name: String, url: URL) {
        self.id = id; self.name = name; self.url = url
    }
}

/// Read-only presentation shared by native cards and the checkout-scoped Codex bridge.
/// Unknown timing or incomplete checks never become an inferred duration or percentage.
public struct CICompactSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let scopeID: String
    public var checkout: String
    public let pipelineID: Int?
    /// A stable pipeline/Jenkins label; nil lets each surface localize the pending launch label.
    public let displayID: String?
    public let firstFailedJob: String?
    /// Optional for compatibility with previously encoded compact summaries.
    public let failedChecks: [CIFailedCheck]?
    public let sha: String?
    public let jenkinsURL: URL?
    public let allureURL: URL?
    public let branch: String
    public let status: String
    public let createdAt: Date?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let duration: Double?
    public let runningJobs: [String]
    public let completed: Int?
    public let total: Int?
    public let complete: Bool
    public let waitingForManual: Bool
    public let updatedAt: Date?
    public let stale: Bool
    /// The authenticated account is presentation context, never inferred from the run initiator.
    public let accountUsername: String?
    /// Only a GitLab pipeline URL receives the GitLab action; queued Jenkins runs have none.
    public let gitlabURL: URL?

    public var identity: String { self.scopeID + ":" + self.id }
    public var active: Bool { Self.isActive(self.status) }
    public var canAnalyze: Bool { self.status == "failed" || self.failedChecks?.isEmpty == false || self.firstFailedJob != nil }
    public var fraction: Double? {
        guard self.complete, let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    public static func isActive(_ status: String) -> Bool {
        ["running", "queued", "triggering", "pending", "preparing", "waiting_for_resource", "manual", "blocked", "scheduled"].contains(status)
    }

    public init(entry: CIFeedEntry, context: CIContext, accountID: Int?, checks: CIProgressSummary?, updatedAt: Date?, stale: Bool, accountUsername: String? = nil) {
        self.id = entry.id
        self.scopeID = context.connection.id.uuidString + ":" + String(context.connection.projectID) + ":" + (accountID.map(String.init) ?? "unknown")
        self.checkout = context.checkout; self.pipelineID = entry.pipeline?.id ?? entry.run?.pipelineID
        if let id = self.pipelineID { self.displayID = "#\(id)" }
        else if let number = entry.run?.buildURL?.lastPathComponent, Int(number) != nil { self.displayID = "Jenkins #\(number)" }
        else if let number = entry.run?.queueURL?.lastPathComponent, Int(number) != nil { self.displayID = "Jenkins · #\(number)" }
        else { self.displayID = nil }
        self.failedChecks = checks?.analysisFailures
        self.firstFailedJob = self.failedChecks?.first?.name
        self.sha = entry.sha
        self.jenkinsURL = entry.run?.buildURL ?? entry.run?.queueURL
        self.allureURL = entry.run?.allureURL
        self.branch = entry.branch; self.status = entry.status; self.createdAt = entry.createdAt
        self.startedAt = entry.pipeline?.startedAt; self.finishedAt = entry.pipeline?.finishedAt
        let elapsed = entry.pipeline?.duration ?? entry.pipeline?.startedAt.flatMap { start in entry.pipeline?.finishedAt.map { $0.timeIntervalSince(start) } }
        self.duration = elapsed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.runningJobs = checks?.running.sorted { $0.id < $1.id }.map(\.name) ?? []
        self.completed = checks?.completed; self.total = checks?.total; self.complete = checks?.complete == true
        self.waitingForManual = checks?.waitingForManual == true
        self.updatedAt = updatedAt; self.stale = stale
        self.accountUsername = accountUsername
        self.gitlabURL = entry.pipeline?.webURL ?? entry.run?.pipelineURL
    }
}
