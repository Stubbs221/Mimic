//
//  RemoteTestCoordinator.swift
//  MimicCore
//
//  Created by Василий Маслов on 04.10.2026.
import Combine
import Foundation

/// Owns persisted remote run identities. A crash or ambiguous POST never causes a second submission.
@MainActor public final class RemoteTestCoordinator: ObservableObject {
    @Published public private(set) var runs: [RemoteTestRun] = []
    private let directory: URL
    private let jenkins: JenkinsClient
    private let gitlab: GitLabClient
    private let jenkinsToken: (JenkinsConnection) throws -> String
    private let gitlabToken: (GitLabConnection) throws -> String
    private var watchers: [UUID: Task<Void, Never>] = [:]
    private var console: [UUID: Data] = [:]
    private var offsets: [UUID: Int] = [:]
    private var failures: [UUID: Int] = [:]
    public init(directory: URL, jenkins: JenkinsClient = JenkinsClient(), gitlab: GitLabClient = GitLabClient(), jenkinsToken: @escaping (JenkinsConnection) throws -> String, gitlabToken: @escaping (GitLabConnection) throws -> String) {
        self.directory = directory; self.jenkins = jenkins; self.gitlab = gitlab; self.jenkinsToken = jenkinsToken; self.gitlabToken = gitlabToken
        if let data = try? Data(contentsOf: directory.appendingPathComponent("remote-runs.json")), let runs = try? JSONDecoder().decode([RemoteTestRun].self, from: data) {
            self.runs = runs
            for i in self.runs.indices where self.runs[i].status == "submitting" { self.runs[i].status = "unknown"; self.runs[i].error = "mcp.submit.unknown" }
        }
    }
    // MARK: - Persistence

    private func persist() throws {
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = self.directory.appendingPathComponent("remote-runs.json")
        try JSONEncoder().encode(self.runs).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    // MARK: - Submission

    /// Validate and persist before POST. Duplicate request IDs return their original run.
    public func submit(requestID: UUID, checkout: ProjectContext, branch: String, plan: UITestPlan, jenkins: JenkinsConnection, gitlab: GitLabConnection, validate: @escaping @MainActor () async throws -> Void = {}) async throws -> RemoteTestRun {
        try await self.submit(requestID: requestID, checkout: checkout, branch: branch, parameters: .uiTests(plan), jenkins: jenkins, gitlab: gitlab, validate: validate)
    }

    /// Additional jobs require the reviewed contract; a changed contract throws before admission or POST.
    public func submit(requestID: UUID, checkout: ProjectContext, branch: String, parameters: RemoteCIParameters, jenkins: JenkinsConnection, gitlab: GitLabConnection, reviewedContract: JenkinsJobContract? = nil, validate: @escaping @MainActor () async throws -> Void = {}) async throws -> RemoteTestRun {
        if let previous = self.runs.first(where: { $0.requestID == requestID }) {
            guard previous.checkout == checkout, previous.branch == branch, previous.resolvedParameters == parameters && previous.jenkins == jenkins && previous.gitlab == gitlab else { throw CIError.invalidConfiguration }
            return previous
        }
        guard parameters.kind == .uiTests || reviewedContract != nil else { throw CIError.invalidConfiguration }
        guard self.runs.filter({ !$0.isTerminal }).count < 20 else { throw CIError.rateLimited(30) }
        let jt = try self.jenkinsToken(jenkins), gt = try self.gitlabToken(gitlab)
        let exists = try await self.gitlab.branchExists(connection: gitlab, branch: branch, token: gt)
        guard exists else { throw CIError.notFound }
        // Recheck after the read-only preflight, since another panel may use the same ID.
        if let previous = self.runs.first(where: { $0.requestID == requestID }) {
            guard previous.checkout == checkout, previous.branch == branch, previous.resolvedParameters == parameters && previous.jenkins == jenkins && previous.gitlab == gitlab else { throw CIError.invalidConfiguration }; return previous
        }
        let current = try await self.jenkins.contract(connection: jenkins, token: jt, kind: parameters.kind, includeBranchValues: true)
        if let reviewedContract {
            guard current == reviewedContract else { throw JenkinsConnectionError.contractChanged }
        }
        guard current.validates(parameters) else { throw CIError.invalidConfiguration }
        let branchValue = try current.branchValue(for: branch)
        try await validate()
        if let previous = self.runs.first(where: { $0.requestID == requestID }) {
            guard previous.checkout == checkout, previous.branch == branch, previous.resolvedParameters == parameters && previous.jenkins == jenkins && previous.gitlab == gitlab else { throw CIError.invalidConfiguration }; return previous
        }
        guard self.runs.filter({ !$0.isTerminal }).count < 20 else { throw CIError.rateLimited(30) }
        var run = RemoteTestRun(requestID: requestID, checkout: checkout, branch: branch, plan: { if case .uiTests(let plan) = parameters { return plan }; return .smoke }(), jenkins: jenkins, gitlab: gitlab)
        run.parameters = parameters
        self.runs.insert(run, at: 0)
        do { try self.persist() } catch { self.runs.removeAll { $0.id == run.id }; throw error }
        do {
            let queue = try await self.jenkins.submit(connection: jenkins, token: jt, branch: branchValue, parameters: parameters)
            self.modify(run.id) { $0.queueURL = queue; $0.status = "queued"; $0.updatedAt = Date() }
            self.watch(run.id)
        } catch {
            let status = (error as? JenkinsSubmissionError)?.status
            let rejected = status == 400 || status == 422
            let known = (error as? CIError).map { [.authentication, .forbidden, .notFound, .invalidConfiguration].contains($0) } ?? false
            let key: String
            if rejected { key = JenkinsConnectionError.submissionRejected.localizationKey }
            else if let ci = error as? CIError, known { key = JenkinsConnectionError.transport(ci).localizationKey }
            else if status != nil { key = "mcp.submit.serverUnknown" }
            else { key = "mcp.submit.unknown" }
            self.modify(run.id) {
                $0.status = known || rejected ? "submissionFailed" : "unknown"
                $0.error = key; $0.submissionHTTPStatus = status; $0.updatedAt = Date()
            }
        }
        return self.runs.first { $0.id == run.id } ?? run
    }
    private func modify(_ id: UUID, _ body: (inout RemoteTestRun) -> Void) {
        guard let i = self.runs.firstIndex(where: { $0.id == id }) else { return }
        body(&self.runs[i]); try? self.persist()
    }
    // MARK: - Polling

    /// Reopening the app resumes only GET polling, including after credentials are repaired.
    private var readRevision = UUID()
    /// Repaired credentials replace only GET watchers; submissions and terminal outcomes remain untouched.
    public func credentialsChanged() { self.stop(); self.resume() }
    public func resume() { for run in self.runs where !run.isTerminal { self.watch(run.id) } }
    public func stop() { self.readRevision = UUID(); for task in self.watchers.values { task.cancel() }; self.watchers.removeAll() }
    private func watch(_ id: UUID) {
        guard self.watchers[id] == nil else { return }
        let revision = self.readRevision
        self.watchers[id] = Task { [weak self] in
            defer { if self?.readRevision == revision { self?.watchers[id] = nil } }
            while !Task.isCancelled {
                guard let self, let run = self.runs.first(where: { $0.id == id }), !run.isTerminal else { return }
                do {
                    try await self.refreshOnce(id)
                    self.failures[id] = 0
                } catch {
                    guard self.readRevision == revision, !Task.isCancelled else { return }
                    let ci = error as? CIError ?? .network
                    self.modify(id) { $0.error = ci.localizationKey }
                    if ci.pausesPolling { return }
                    self.failures[id, default: 0] += 1
                    let delay: Double = if case let .rateLimited(seconds) = ci { seconds } else { min(120, pow(2, Double(self.failures[id, default: 1])) * 5) }
                    do { try await Task.sleep(for: .seconds(max(5, delay))) } catch { return }
                    continue
                }
                do { try await Task.sleep(for: .seconds(run.pipelineID == nil ? 5 : 15)) } catch { return }
            }
        }
    }
    /// One bounded step is injectable through HTTP fixtures; it never exposes Jenkins console text.
    public func refreshOnce(_ id: UUID) async throws {
        guard let run = self.runs.first(where: { $0.id == id }), !run.isTerminal else { return }
        let revision = self.readRevision
        if let pipelineID = run.pipelineID {
            let token = try self.gitlabToken(run.gitlab)
            let pipeline = try await self.gitlab.pipeline(connection: run.gitlab, id: pipelineID, token: token)
            try self.checkRead(revision)
            guard pipeline.ref == run.branch, pipeline.sha == run.sha else { throw CIError.invalidResponse }
            let details = try await self.gitlab.details(connection: run.gitlab, pipelineID: pipelineID, token: token)
            try self.checkRead(revision)
            var allure = run.allureURL
            if allure == nil {
                for job in details.jobs where job.status == "success" || job.status == "failed" {
                    try self.checkRead(revision)
                    if let launch = try? await self.gitlab.allureID(connection: run.gitlab, jobID: job.id, token: token), launch > 0 {
                        try self.checkRead(revision)
                        _ = launch; break
                    }
                }
            }
            try self.checkRead(revision)
            self.modify(id) { $0.status = pipeline.status; $0.jobs = details.jobs.map(RemoteJobSummary.init) + details.bridges.map(RemoteJobSummary.init); $0.allureURL = allure; $0.error = details.bridgeError?.localizationKey; $0.updatedAt = Date() }
            return
        }
        let token = try self.jenkinsToken(run.jenkins)
        var buildURL = run.buildURL
        if buildURL == nil, let queue = run.queueURL {
            let value: BridgeValue
            do { value = try await self.jenkins.queue(connection: run.jenkins, token: token, url: queue); try self.checkRead(revision) }
            catch CIError.notFound {
                try self.checkRead(revision)
                let recovered = try await self.jenkins.buildURL(connection: run.jenkins, token: token, queueURL: queue, kind: run.kind)
                try self.checkRead(revision)
                if let recovered {
                    self.modify(id) { $0.buildURL = recovered; $0.status = "triggering" }
                    return
                }
                self.modify(id) { $0.status = "unlinked"; $0.error = "mcp.pipeline.unlinked"; $0.updatedAt = Date() }
                return
            }
            if value["cancelled"] == .bool(true) { self.modify(id) { $0.status = "canceled"; $0.updatedAt = Date() }; return }
            if let urlString = value["executable"]["url"].string, let url = URL(string: urlString), JenkinsClient.sameOrigin(url, run.jenkins.baseURL), url.path.contains("/job/\(run.kind.job)/") {
                buildURL = url; self.modify(id) { $0.buildURL = url; $0.status = "triggering" }
            } else { self.modify(id) { $0.status = "queued"; $0.error = nil; $0.updatedAt = Date() }; return }
        }
        guard let buildURL else { throw CIError.invalidResponse }
        let build = try await self.jenkins.build(connection: run.jenkins, token: token, url: buildURL, kind: run.kind)
        try self.checkRead(revision)
        if run.kind == .beta, let url = JenkinsClient.betaPipelineURL(description: build["description"].string, connection: run.gitlab),
           let pipelineID = url.path.split(separator: "/").last.flatMap({ Int($0) }) {
            let pipeline = try await self.gitlab.pipeline(connection: run.gitlab, id: pipelineID, token: self.gitlabToken(run.gitlab))
            try self.checkRead(revision)
            guard pipeline.ref == run.branch, pipeline.projectID == run.gitlab.projectID,
                  JenkinsClient.sameOrigin(pipeline.webURL, run.gitlab.baseURL), pipeline.webURL.path == url.path, !pipeline.sha.isEmpty else { throw CIError.invalidResponse }
            self.modify(id) { $0.pipelineID = pipeline.id; $0.pipelineURL = pipeline.webURL; $0.sha = pipeline.sha; $0.status = pipeline.status; $0.error = nil; $0.updatedAt = Date() }
            return
        }
        let response = try await self.jenkins.console(connection: run.jenkins, token: token, url: buildURL, offset: self.offsets[id, default: 0], kind: run.kind)
        try self.checkRead(revision)
        guard response.data.count <= 1024 * 1024 else { throw CIError.invalidResponse }
        var data = self.console[id, default: Data()]; data.append(response.data)
        self.console[id] = Data(data.suffix(256 * 1024))
        self.offsets[id] = response.textSize ?? (self.offsets[id, default: 0] + response.data.count)
        if let pipeline = JenkinsClient.pipeline(in: self.console[id] ?? Data(), connection: run.gitlab, branch: run.branch) {
            self.modify(id) { $0.pipelineID = pipeline.id; $0.pipelineURL = pipeline.webURL; $0.sha = pipeline.sha; $0.status = "pending"; $0.error = nil; $0.updatedAt = Date() }
            self.console[id] = nil; self.offsets[id] = nil
        } else if build["building"] == .bool(false), response.moreData != true {
            self.modify(id) { $0.status = ["FAILURE", "ABORTED"].contains(build["result"].string ?? "") ? "submissionFailed" : "unlinked"; $0.error = "mcp.pipeline.unlinked"; $0.updatedAt = Date() }
            self.console[id] = nil; self.offsets[id] = nil
        } else { self.modify(id) { $0.error = nil; $0.updatedAt = Date() } }
    }
    private func checkRead(_ revision: UUID) throws {
        guard self.readRevision == revision, !Task.isCancelled else { throw CancellationError() }
    }

}
