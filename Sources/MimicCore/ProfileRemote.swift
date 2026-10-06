//
//  ProfileRemote.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Combine
import Foundation

public struct ProfileRemoteField: Codable, Equatable, Sendable {
    public let defaultValue: String
    public let choices: [String]
    public let boolean: Bool
}
public struct ProfileRemoteContract: Codable, Equatable, Sendable {
    public let fields: [String: ProfileRemoteField]
    public let gitBranch: Bool
    public let branchValues: Set<String>?
    public func wireParameters(_ parameters: [String: String], action: ActionDefinition, branch: String) throws -> [String: String] {
        guard let remote = action.remote else { throw ProfileError.action }
        var result = try ProfileValidation.parameters(parameters, action: action)
        for field in action.parameters where field.kind != .branch {
            guard let contract = self.fields[field.id], let value = result[field.id],
                  contract.choices.isEmpty || contract.choices.contains(value), !contract.boolean || ["true", "false"].contains(value) else { throw ProfileError.parameter }
        }
        result = result.filter { key, _ in action.parameters.first(where: { $0.id == key })?.kind != .branch }
        let wireBranch: String
        if self.gitBranch {
            guard let branches = self.branchValues else { throw JenkinsConnectionError.branchValuesUnavailable }
            if branches.contains("origin/" + branch) { wireBranch = "origin/" + branch }
            else if branches.contains(branch) { wireBranch = branch }
            else { throw JenkinsConnectionError.branchUnavailable }
        } else { wireBranch = branch }
        guard !branch.isEmpty, branch.utf8.count <= 1024 else { throw ProfileError.parameter }
        result[remote.branchParameter] = wireBranch
        return result
    }
}

/// A remote run pins the job, services and profile revision before its single POST.
public struct ProfileRemoteRun: Codable, Identifiable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let checkout: ProjectContext
    public let execution: ProfileExecution
    public let jenkins: JenkinsConnection
    public let gitlab: GitLabConnection?
    public let branch: String
    public let createdAt: Date
    public var status: String
    public var queueURL: URL?
    public var buildURL: URL?
    public var pipelineID: Int?
    public var pipelineURL: URL?
    public var sha: String?
    public var reportURL: URL?
    public var error: String?
    public var jobs: [RemoteJobSummary] = []
    public var terminal: Bool { ["success", "failed", "canceled", "submissionFailed", "unknown", "unlinked"].contains(status) }
}

/// No automatic retry of submissions. Restart restores observations and marks uncertain POSTs unknown.
@MainActor public final class ProfileRemoteCoordinator: ObservableObject {
    @Published public private(set) var runs: [ProfileRemoteRun] = []
    private let directory: URL
    private let jenkins: JenkinsClient
    private let gitlab: GitLabClient
    private let jenkinsToken: (JenkinsConnection) throws -> String
    private let gitlabToken: (GitLabConnection) throws -> String
    private var watchers: [UUID: Task<Void, Never>] = [:]
    private var admitting = Set<UUID>()
    private var console: [UUID: Data] = [:]
    private var offsets: [UUID: Int] = [:]
    public init(directory: URL, jenkins: JenkinsClient, gitlab: GitLabClient, jenkinsToken: @escaping (JenkinsConnection) throws -> String, gitlabToken: @escaping (GitLabConnection) throws -> String) {
        self.directory = directory; self.jenkins = jenkins; self.gitlab = gitlab
        self.jenkinsToken = jenkinsToken; self.gitlabToken = gitlabToken
        if let data = try? Data(contentsOf: directory.appendingPathComponent("profile-remote-runs.json")), let restored = try? JSONDecoder().decode([ProfileRemoteRun].self, from: data) {
            self.runs = restored
            for i in runs.indices where runs[i].status == "submitting" { runs[i].status = "unknown" }
        }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(runs).write(to: directory.appendingPathComponent("profile-remote-runs.json"), options: .atomic)
    }
    private func update(_ id: UUID, _ body: (inout ProfileRemoteRun) -> Void) throws {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        body(&runs[index]); try persist()
    }
    public func contract(action: ActionDefinition, connection: JenkinsConnection) async throws -> ProfileRemoteContract {
        try await jenkins.profileContract(connection: connection, token: jenkinsToken(connection), action: action)
    }
    public func submit(id: UUID, checkout: ProjectContext, execution: ProfileExecution, jenkins connection: JenkinsConnection, gitlab gitConnection: GitLabConnection?, reviewed: ProfileRemoteContract? = nil, validate: @MainActor () async throws -> Void) async throws -> ProfileRemoteRun {
        if let run = runs.first(where: { $0.requestID == id }) {
            guard run.checkout == checkout, run.execution == execution, run.jenkins == connection, run.gitlab == gitConnection else { throw ProfileError.revision }; return run
        }
        guard !admitting.contains(id), let action = execution.action, let remote = action.remote, runs.filter({ !$0.terminal }).count < 20 else { throw ProfileError.action }
        admitting.insert(id); defer { admitting.remove(id) }
        let branch = action.parameters.first(where: { $0.kind == .branch }).flatMap { execution.parameters[$0.id] } ?? checkout.branch
        if remote.tracking == .gitLabPipeline {
            guard let gitConnection else { throw CIError.invalidConfiguration }
            guard try await gitlab.branchExists(connection: gitConnection, branch: branch, token: gitlabToken(gitConnection)) else { throw CIError.notFound }
        }
        let contract = try await self.contract(action: action, connection: connection)
        if let reviewed {
            guard reviewed.fields == contract.fields, reviewed.gitBranch == contract.gitBranch else { throw JenkinsConnectionError.contractChanged }
        }
        if execution.binding?.role == .beta {
            let values = try ProfileValidation.parameters(execution.parameters, action: action)
            for parameter in action.parameters where parameter.kind != .branch {
                guard values[parameter.id] == contract.fields[parameter.id]?.defaultValue else { throw JenkinsConnectionError.contractChanged }
            }
        }
        let fields = try contract.wireParameters(execution.parameters, action: action, branch: branch)
        try await validate()
        var run = ProfileRemoteRun(id: UUID(), requestID: id, checkout: checkout, execution: execution, jenkins: connection, gitlab: gitConnection, branch: branch, createdAt: Date(), status: "submitting")
        runs.insert(run, at: 0)
        do { try persist() } catch { runs.removeAll { $0.id == run.id }; throw error }
        do {
            run.queueURL = try await self.jenkins.profileSubmit(connection: connection, token: jenkinsToken(connection), job: remote.job, fields: fields)
            run.status = "queued"
        } catch {
            let known = (error as? CIError).map { [.authentication, .forbidden, .notFound, .invalidConfiguration].contains($0) } ?? false
            let rejected = (error as? JenkinsSubmissionError).map { [400, 422].contains($0.status) } ?? false
            run.status = known || rejected ? "submissionFailed" : "unknown"
            run.error = String(describing: error)
        }
        let final = run
        try update(run.id) { $0 = final }
        if !run.terminal { watch(run.id) }; return run
    }
    public func resume() { for run in runs where !run.terminal { watch(run.id) } }
    public func stop() { watchers.values.forEach { $0.cancel() }; watchers.removeAll() }
    private func watch(_ id: UUID) {
        guard watchers[id] == nil else { return }
        watchers[id] = Task { [weak self] in
            defer { self?.watchers[id] = nil }
            while !Task.isCancelled {
                guard let self, let run = runs.first(where: { $0.id == id }), !run.terminal else { return }
                do { try await refresh(id) }
                catch { if !Task.isCancelled { try? update(id) { $0.error = String(describing: error) } } }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    /// Polls this queue/build identity only; an unrelated latest build cannot satisfy a request.
    public func refresh(_ id: UUID) async throws {
        guard let run = runs.first(where: { $0.id == id }), !run.terminal, let remote = run.execution.action?.remote else { return }
        if let pipeline = run.pipelineID, let connection = run.gitlab {
            let token = try gitlabToken(connection)
            let value = try await gitlab.pipeline(connection: connection, id: pipeline, token: token)
            guard !Task.isCancelled, value.ref == run.branch, value.sha == run.sha else { throw CIError.invalidResponse }
            let details = try await gitlab.details(connection: connection, pipelineID: pipeline, token: token)
            guard !Task.isCancelled else { throw CancellationError() }
            var reportURL = run.reportURL
            if reportURL == nil, let template = run.execution.snapshot.profile.services?.reportURLTemplate, let artifact = run.execution.snapshot.profile.services?.reportArtifactPath {
                for job in details.jobs where ["success", "failed"].contains(job.status) {
                    if let report = try? await gitlab.reportID(connection: connection, jobID: job.id, artifactPath: artifact, token: token), report > 0 {
                        let url = URL(string: template.replacingOccurrences(of: "{id}", with: String(report)))
                        if url?.scheme == "https", url?.user == nil, url?.password == nil { reportURL = url }; break
                    }
                }
            }
            guard !Task.isCancelled else { throw CancellationError() }
            let link = reportURL
            try update(id) { $0.status = value.status; $0.jobs = details.jobs.map(RemoteJobSummary.init) + details.bridges.map(RemoteJobSummary.init); $0.reportURL = link; $0.error = nil }; return
        }
        let token = try jenkinsToken(run.jenkins)
        guard let queueURL = run.queueURL else { return }
        var buildURL = run.buildURL
        if buildURL == nil {
            do {
                let queue = try await jenkins.queue(connection: run.jenkins, token: token, url: queueURL)
                guard !Task.isCancelled else { throw CancellationError() }
                if queue["cancelled"] == .bool(true) { try update(id) { $0.status = "canceled" }; return }
                buildURL = queue["executable"]["url"].string.flatMap(URL.init(string:))
            } catch CIError.notFound { buildURL = try await jenkins.profileBuildURL(connection: run.jenkins, token: token, queueURL: queueURL, job: remote.job) }
            if let buildURL { try update(id) { $0.buildURL = buildURL; $0.status = "running" } }
        }
        guard let buildURL else { return }
        let build = try await jenkins.profileBuild(connection: run.jenkins, token: token, url: buildURL, job: remote.job)
        guard !Task.isCancelled else { throw CancellationError() }
        if remote.tracking == .jenkinsOnly {
            if build["building"] == .bool(false) { try update(id) { $0.status = build["result"].string == "SUCCESS" ? "success" : build["result"].string == "ABORTED" ? "canceled" : "failed"; $0.error = nil } }
            return
        }
        guard let connection = run.gitlab else { throw CIError.invalidConfiguration }
        let response = try await jenkins.profileConsole(connection: run.jenkins, token: token, url: buildURL, job: remote.job, offset: offsets[id, default: 0])
        guard !Task.isCancelled else { throw CancellationError() }
        var bytes = console[id, default: Data()]; bytes.append(response.data); console[id] = Data(bytes.suffix(256 * 1024))
        offsets[id] = response.textSize ?? offsets[id, default: 0] + response.data.count
        if let pipeline = JenkinsClient.pipeline(in: console[id] ?? Data(), connection: connection, branch: run.branch) {
            try update(id) { $0.pipelineID = pipeline.id; $0.pipelineURL = pipeline.webURL; $0.sha = pipeline.sha; $0.status = "pending" }
            console[id] = nil; offsets[id] = nil
        } else if let link = JenkinsClient.betaPipelineURL(description: build["description"].string, connection: connection), let pipelineID = link.path.split(separator: "/").last.flatMap({ Int($0) }) {
            let pipeline = try await gitlab.pipeline(connection: connection, id: pipelineID, token: gitlabToken(connection))
            guard !Task.isCancelled, pipeline.ref == run.branch else { throw CIError.invalidResponse }
            try update(id) { $0.pipelineID = pipeline.id; $0.pipelineURL = link; $0.sha = pipeline.sha; $0.status = pipeline.status }
        } else if build["building"] == .bool(false), response.moreData != true {
            try update(id) { $0.status = build["result"].string == "SUCCESS" ? "unlinked" : "failed" }
            console[id] = nil; offsets[id] = nil
        }
    }
}
