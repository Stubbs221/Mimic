//
//  Jenkins.swift
//  MimicCore
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation

/// Persisted Jenkins settings contain a Keychain reference, never a token.
public struct JenkinsConnection: Codable, Sendable, Equatable {
    public let id: UUID
    public let baseURL: URL
    public let username: String
    public init(id: UUID = UUID(), baseURL: URL, username: String) {
        self.id = id; self.baseURL = baseURL; self.username = username
    }
}

/// Only the existing simulator job and its four plans are supported.
public enum UITestPlan: String, Codable, CaseIterable, Sendable { case smoke = "SMOKE", functional = "FUNCTIONAL", stats = "STATS", full = "FULL" }

/// Remote launches have their own lifecycle, separate from the local PTY queue.
public struct RemoteTestRun: Codable, Sendable, Identifiable {
    public let id: UUID
    public let requestID: UUID
    public let checkout: ProjectContext
    public let branch: String
    public let plan: UITestPlan
    public let jenkins: JenkinsConnection
    public let gitlab: GitLabConnection
    public let createdAt: Date
    /// Nil denotes legacy UI-test history; plan remains the compatibility field for that job.
    public var parameters: RemoteCIParameters?
    public var kind: RemoteCIKind { self.parameters?.kind ?? .uiTests }
    public var resolvedParameters: RemoteCIParameters { self.parameters ?? .uiTests(self.plan) }
    public var queueURL: URL?
    public var buildURL: URL?
    public var pipelineID: Int?
    public var pipelineURL: URL?
    public var sha: String?
    public var status = "submitting"
    public var error: String?
    /// Numeric submission metadata only; server bodies and credentials are never persisted.
    public var submissionHTTPStatus: Int?
    public var updatedAt: Date?
    public var jobs: [RemoteJobSummary] = []
    public var allureURL: URL?
    public var isTerminal: Bool { ["success", "failed", "canceled", "skipped", "submissionFailed", "unknown", "unlinked"].contains(self.status) }
    public init(id: UUID = UUID(), requestID: UUID, checkout: ProjectContext, branch: String, plan: UITestPlan, jenkins: JenkinsConnection, gitlab: GitLabConnection, createdAt: Date = Date()) {
        self.id = id; self.requestID = requestID; self.checkout = checkout; self.branch = branch; self.plan = plan; self.jenkins = jenkins; self.gitlab = gitlab; self.createdAt = createdAt
    }
}

/// Job status remains visible even when GitLab allows that job to fail.
public struct RemoteJobSummary: Codable, Sendable {
    public let name: String
    public let status: String
    public let allowFailure: Bool
    public let url: URL
    public init(_ bridge: CIBridge) { self.name = bridge.name; self.status = bridge.status; self.allowFailure = false; self.url = bridge.webURL }
    public init(_ job: CIJob) { self.name = job.name; self.status = job.status; self.allowFailure = job.allowFailure; self.url = job.webURL }
}

/// Exact identity emitted by the GitLab trigger response in the associated Jenkins build.
public struct TriggeredPipeline: Decodable, Sendable {
    public let id: Int
    public let projectID: Int
    public let ref: String
    public let sha: String
    public let webURL: URL
    enum CodingKeys: String, CodingKey { case id, ref, sha; case projectID = "project_id", webURL = "web_url" }
}

/// Connection failures keep Jenkins-specific job validation separate from transport failures.
public enum JenkinsConnectionError: Error, Equatable, Sendable {
    case transport(CIError)
    case missingParameters
    case unsupportedPlans
    case contractChanged
    case branchValuesUnavailable
    case branchUnavailable
    case submissionRejected

    /// Localization keys never include raw server responses or credentials.
    public var localizationKey: String {
        switch self {
        case .branchValuesUnavailable: "jenkins.error.branchValues"
        case .branchUnavailable: "jenkins.error.branchUnavailable"
        case .submissionRejected: "jenkins.error.submissionRejected"
        case .contractChanged: "jenkins.error.contractChanged"
        case .missingParameters: "jenkins.error.parameters"
        case .unsupportedPlans: "jenkins.error.plans"
        case .transport(let error):
            switch error {
            case .invalidConfiguration: "jenkins.error.configuration"
            case .authentication: "jenkins.error.authentication"
            case .forbidden: "jenkins.error.forbidden"
            case .notFound: "jenkins.error.notFound"
            case .rateLimited: "jenkins.error.rateLimited"
            case .network: "jenkins.error.network"
            case .invalidResponse: "jenkins.error.response"
            case .server: "jenkins.error.server"
            case .credential: "jenkins.error.credential"
            }
        }
    }
}

/// A non-successful POST response is retained without keeping its potentially sensitive body.
public struct JenkinsSubmissionError: Error, Sendable {
    public let status: Int
}

/// A constrained Jenkins REST adapter. Redirects and credential-bearing URLs are excluded.
public struct JenkinsClient: Sendable {
    public static let job = "uiTests"
    private let transport: any CIHTTPTransport
    public init(transport: any CIHTTPTransport = URLSessionCITransport()) { self.transport = transport }
    private func request(connection: JenkinsConnection, token: String, path: String, method: String = "GET", fields: [String: String] = [:]) async throws -> CIHTTPResponse {
        let base = try GitLabClient.baseURL(connection.baseURL.absoluteString)
        guard !connection.username.isEmpty, !connection.username.contains(":"), !token.isEmpty, !token.contains("\n"), !token.contains("\r") else { throw CIError.invalidConfiguration }
        guard let url = URL(string: path, relativeTo: base.appendingPathComponent("/"))?.absoluteURL,
              url.host == base.host, url.port == base.port, url.scheme == "https", url.user == nil, url.password == nil else { throw CIError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Basic " + Data((connection.username + ":" + token).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            var encoded = URLComponents()
            encoded.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = Data((encoded.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let response = try await CICredentialRequestContext.$connectionID.withValue(connection.id) { try await self.transport.send(request) }
        switch response.status {
        case 200...299: return response
        // Jenkins returns 303 when it reuses an existing queue item. The caller validates Location.
        case 303 where method == "POST": return response
        case 301...399, 401: throw CIError.authentication
        case 403: throw CIError.forbidden
        case 404: throw CIError.notFound
        case 429: throw CIError.rateLimited(response.retryAfter ?? 30)
        default:
            if method == "POST" { throw JenkinsSubmissionError(status: response.status) }
            throw CIError.server
        }
    }
    // MARK: - Job contract and submission

    public func check(connection: JenkinsConnection, token: String) async throws {
        // Explicit tree selection avoids the default API depth hiding nested plan choices.
        let tree = "actions[parameterDefinitions[name,choices]],property[parameterDefinitions[name,choices]]"
        let response = try await self.request(connection: connection, token: token, path: "job/\(Self.job)/api/json?tree=\(tree)")
        let value: BridgeValue
        do { value = try JSONDecoder().decode(BridgeValue.self, from: response.data) }
        catch { throw CIError.invalidResponse }
        guard value.object != nil else { throw CIError.invalidResponse }
        let definitions = ["actions", "property"].flatMap { key in
            (value[key].array ?? []).flatMap { $0["parameterDefinitions"].array ?? [] }
        }
        let names = definitions.compactMap { $0["name"].string }
        guard names.contains("BRANCH"), names.contains("TEST_PLAN") else { throw JenkinsConnectionError.missingParameters }
        let plans = definitions.filter { $0["name"].string == "TEST_PLAN" }
        guard plans.contains(where: { Set($0["choices"].array?.compactMap(\.string) ?? []).isSuperset(of: UITestPlan.allCases.map(\.rawValue)) }) else { throw JenkinsConnectionError.unsupportedPlans }
    }
    /// No automatic retry: after a transport failure, submission may already have occurred.
    public func submit(connection: JenkinsConnection, token: String, branch: String, plan: UITestPlan) async throws -> URL {
        try await self.submit(connection: connection, token: token, branch: branch, parameters: .uiTests(plan))
    }
    // MARK: - Exact run tracking

    /// Validates only the selected job. Optional jobs cannot block UI-test configuration.
    public func contract(connection: JenkinsConnection, token: String, kind: RemoteCIKind, includeBranchValues: Bool = false) async throws -> JenkinsJobContract {
        let branchTree = includeBranchValues ? ",allValueItems[value,values[value],errors]" : ""
        let fields = "name,_class,choices,defaultParameterValue[value]" + branchTree
        let tree = "actions[parameterDefinitions[\(fields)]],property[parameterDefinitions[\(fields)]]"
        let response = try await self.request(connection: connection, token: token, path: "job/\(kind.job)/api/json?tree=\(tree)")
        let value = try JSONDecoder().decode(BridgeValue.self, from: response.data)
        let definitions = ["actions", "property"].flatMap { key in (value[key].array ?? []).flatMap { $0["parameterDefinitions"].array ?? [] } }
        let required: Set<String> = Set([kind.branchParameter]).union(kind == .uiTests ? ["TEST_PLAN"] : kind == .beta ? ["TARGET", "REBASE_BRANCH", "UPLOAD_TO_APP_DISTRIBUTION"] : Set(QualityGate.allCases.map(\.rawValue)))
        var defaults: [String: String] = [:], choices: [String: [String]] = [:], names = Set<String>()
        var usesGitParameter = false, branchValues: Set<String>?
        for definition in definitions {
            guard let name = definition["name"].string, required.contains(name) else { continue }
            names.insert(name)
            if name == kind.branchParameter, definition["_class"].string == "net.uaznia.lukanus.hudson.plugins.gitparameter.GitParameterDefinition" {
                usesGitParameter = true
                if includeBranchValues {
                    let items = definition["allValueItems"]
                    guard (items["errors"].array ?? []).isEmpty,
                          let values = items.array ?? items["values"].array else { throw JenkinsConnectionError.branchValuesUnavailable }
                    branchValues = Set(values.compactMap { $0["value"].string })
                }
            }
            if let options = definition["choices"].array?.compactMap(\.string) { choices[name] = options }
            let value = definition["defaultParameterValue"]["value"]
            if let string = value.string { defaults[name] = string }
            else if case .bool(let bool) = value { defaults[name] = bool ? "true" : "false" }
        }
        guard names.isSuperset(of: required) else { throw JenkinsConnectionError.missingParameters }
        switch kind {
        case .uiTests:
            guard Set(choices["TEST_PLAN"] ?? []).isSuperset(of: UITestPlan.allCases.map(\.rawValue)) else { throw JenkinsConnectionError.unsupportedPlans }
        case .qualityGates:
            guard QualityGate.allCases.allSatisfy({ ["true", "false"].contains(defaults[$0.rawValue] ?? "") }) else { throw JenkinsConnectionError.missingParameters }
        case .beta:
            guard let target = defaults["TARGET"], choices["TARGET"]?.contains(target) == true,
                  let upload = defaults["UPLOAD_TO_APP_DISTRIBUTION"], ["FALSE", "TRUE"].contains(upload), choices["UPLOAD_TO_APP_DISTRIBUTION"]?.contains(upload) == true,
                  defaults["REBASE_BRANCH"] != nil else { throw JenkinsConnectionError.missingParameters }
        }
        return JenkinsJobContract(kind: kind, defaults: defaults, choices: choices, usesGitParameter: usesGitParameter, branchValues: branchValues)
    }

    /// Sends reviewed defaults and the wire branch resolved by the coordinator's current contract.
    public func submit(connection: JenkinsConnection, token: String, branch: String, parameters: RemoteCIParameters) async throws -> URL {
        guard !branch.isEmpty, branch.utf8.count < 1024, !branch.contains("\n"), !branch.contains("\r") else { throw CIError.invalidConfiguration }
        var fields = parameters.fields; fields[parameters.kind.branchParameter] = branch
        let response = try await self.request(connection: connection, token: token, path: "job/\(parameters.kind.job)/buildWithParameters", method: "POST", fields: fields)
        guard let location = response.location, let url = URL(string: location, relativeTo: connection.baseURL)?.absoluteURL,
              Self.sameOrigin(url, connection.baseURL), url.query == nil, url.fragment == nil,
              Array(url.path.split(separator: "/").dropLast()) == connection.baseURL.path.split(separator: "/") + ["queue", "item"],
              let queueID = url.path.split(separator: "/").last.flatMap({ Int($0) }), queueID > 0 else { throw CIError.invalidResponse }
        return url
    }

    /// Beta embeds the exact triggered pipeline link in this build's description, never in a latest-build query.
    public static func betaPipelineURL(description: String?, connection: GitLabConnection) -> URL? {
        guard let description, description.utf8.count <= 64 * 1024,
              let expression = try? NSRegularExpression(pattern: "href=[\\\"']([^\\\"']+)[\\\"']") else { return nil }
        let range = NSRange(description.startIndex..., in: description)
        for match in expression.matches(in: description, range: range) {
            guard let range = Range(match.range(at: 1), in: description), let url = URL(string: String(description[range])),
                  Self.sameOrigin(url, connection.baseURL), url.path.hasPrefix("/" + connection.projectPath + "/-/pipelines/"),
                  url.path.split(separator: "/").last.flatMap({ Int($0) }) != nil else { continue }
            return url
        }
        return nil
    }

    public func queue(connection: JenkinsConnection, token: String, url: URL) async throws -> BridgeValue {
        guard Self.sameOrigin(url, connection.baseURL) else { throw CIError.invalidConfiguration }
        let response = try await self.request(connection: connection, token: token, path: url.appendingPathComponent("api/json").absoluteString)
        return try JSONDecoder().decode(BridgeValue.self, from: response.data)
    }
    /// Queue items expire. Recover only a build whose queueId equals this persisted request's queue item.
    public func buildURL(connection: JenkinsConnection, token: String, queueURL: URL, kind: RemoteCIKind = .uiTests) async throws -> URL? {
        guard Self.sameOrigin(queueURL, connection.baseURL), let queueID = queueURL.path.split(separator: "/").last.flatMap({ Int($0) }) else { throw CIError.invalidConfiguration }
        let response = try await self.request(connection: connection, token: token, path: "job/\(kind.job)/api/json?tree=builds[number,url,queueId]{0,100}")
        let json = try JSONDecoder().decode(BridgeValue.self, from: response.data)
        for build in json["builds"].array ?? [] where build["queueId"].integer == queueID {
            if let value = build["url"].string, let url = URL(string: value), Self.sameOrigin(url, connection.baseURL), url.path.contains("/job/\(kind.job)/") { return url }
        }
        return nil
    }
    public func build(connection: JenkinsConnection, token: String, url: URL, kind: RemoteCIKind = .uiTests) async throws -> BridgeValue {
        guard Self.sameOrigin(url, connection.baseURL), url.path.contains("/job/\(kind.job)/") else { throw CIError.invalidConfiguration }
        let response = try await self.request(connection: connection, token: token, path: url.appendingPathComponent("api/json").absoluteString)
        return try JSONDecoder().decode(BridgeValue.self, from: response.data)
    }
    public func console(connection: JenkinsConnection, token: String, url: URL, offset: Int, kind: RemoteCIKind = .uiTests) async throws -> CIHTTPResponse {
        guard Self.sameOrigin(url, connection.baseURL), url.path.contains("/job/\(kind.job)/"), offset >= 0 else { throw CIError.invalidConfiguration }
        return try await self.request(connection: connection, token: token, path: url.appendingPathComponent("logText/progressiveText").absoluteString + "?start=\(offset)")
    }
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool { a.scheme == "https" && a.host == b.host && a.port == b.port && a.user == nil && a.password == nil }

    // MARK: - Trigger identity

    /// Extracts only allowlisted trigger fields. Raw console output is never persisted or exposed to MCP.
    public static func pipeline(in data: Data, connection: GitLabConnection, branch: String) -> TriggeredPipeline? {
        // Jenkins emits stage braces outside JSON. Parse complete JSON lines first so they cannot swallow the trigger response.
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
            if let p = try? JSONDecoder().decode(TriggeredPipeline.self, from: Data(line.utf8)), valid(p, connection: connection, branch: branch) { return p }
        }
        let bytes = Array(data)
        var candidates = 0
        for first in bytes.indices where bytes[first] == 123 {
            candidates += 1
            guard candidates <= 128 else { return nil }
            var depth = 0, inString = false, escaped = false
            for index in first..<min(bytes.count, first + 64 * 1024) {
                let byte = bytes[index]
                if inString {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { inString = false }
                } else if byte == 34 { inString = true }
                else if byte == 123 { depth += 1 }
                else if byte == 125 {
                    depth -= 1
                    if depth == 0 {
                        if let p = try? JSONDecoder().decode(TriggeredPipeline.self, from: Data(bytes[first...index])), valid(p, connection: connection, branch: branch) { return p }
                        break
                    }
                }
            }
        }
        return nil
    }
    private static func valid(_ p: TriggeredPipeline, connection: GitLabConnection, branch: String) -> Bool {
        p.id > 0 && p.projectID == connection.projectID && p.ref == branch && !p.sha.isEmpty && Self.sameOrigin(p.webURL, connection.baseURL) && p.webURL.path.hasSuffix("/pipelines/\(p.id)")
    }
}

// MARK: - Profile-defined job contracts

extension JenkinsClient {
    private static func profileJobPath(_ job: String) throws -> String {
        guard ProfileValidation.relativePath(job), job.split(separator: "/").allSatisfy({ $0.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil }) else { throw ProfileError.path }
        return job.split(separator: "/").map { "job/" + $0 }.joined(separator: "/")
    }
    public func profileContract(connection: JenkinsConnection, token: String, action: ActionDefinition) async throws -> ProfileRemoteContract {
        guard let remote = action.remote else { throw ProfileError.action }
        let path = try Self.profileJobPath(remote.job)
        let fields = "name,_class,choices,defaultParameterValue[value],allValueItems[value,values[value],errors]"
        let tree = "actions[parameterDefinitions[\(fields)]],property[parameterDefinitions[\(fields)]]"
        let response = try await request(connection: connection, token: token, path: path + "/api/json?tree=" + tree)
        let value = try JSONDecoder().decode(BridgeValue.self, from: response.data)
        let definitions = ["actions", "property"].flatMap { key in (value[key].array ?? []).flatMap { $0["parameterDefinitions"].array ?? [] } }
        let required = Set(action.parameters.filter { $0.kind != .branch }.map(\.id) + [remote.branchParameter])
        var result: [String: ProfileRemoteField] = [:], gitBranch = false, branches: Set<String>?
        for definition in definitions {
            guard let name = definition["name"].string, required.contains(name) else { continue }
            let defaultValue = definition["defaultParameterValue"]["value"]
            let bool = definition["_class"].string?.hasSuffix("BooleanParameterDefinition") == true
            let string = defaultValue.string ?? (defaultValue == .bool(true) ? "true" : defaultValue == .bool(false) ? "false" : "")
            result[name] = ProfileRemoteField(defaultValue: string, choices: definition["choices"].array?.compactMap(\.string) ?? [], boolean: bool)
            if name == remote.branchParameter, definition["_class"].string?.hasSuffix("GitParameterDefinition") == true {
                gitBranch = true
                let items = definition["allValueItems"]
                guard (items["errors"].array ?? []).isEmpty, let values = items.array ?? items["values"].array else { throw JenkinsConnectionError.branchValuesUnavailable }
                branches = Set(values.compactMap { $0["value"].string })
            }
        }
        guard Set(result.keys) == required else { throw JenkinsConnectionError.missingParameters }
        for parameter in action.parameters where parameter.kind != .branch {
            guard let field = result[parameter.id], (parameter.kind == .boolean) == field.boolean else { throw JenkinsConnectionError.missingParameters }
            if parameter.kind == .choice { guard !field.choices.isEmpty, Set(field.choices).isSuperset(of: parameter.choices ?? []), field.choices.contains(field.defaultValue) else { throw JenkinsConnectionError.contractChanged } }
            guard DiagnosticText.clean(field.defaultValue) == field.defaultValue, field.defaultValue.utf8.count <= 4096,
                  !field.defaultValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !parameter.required || !field.defaultValue.isEmpty,
                  parameter.kind != .boolean || ["true", "false"].contains(field.defaultValue) else { throw JenkinsConnectionError.contractChanged }
            if let pattern = parameter.pattern, !field.defaultValue.isEmpty {
                guard let range = field.defaultValue.range(of: pattern, options: .regularExpression), range.lowerBound == field.defaultValue.startIndex, range.upperBound == field.defaultValue.endIndex else { throw JenkinsConnectionError.contractChanged }
            }
        }
        return ProfileRemoteContract(fields: result, gitBranch: gitBranch, branchValues: branches)
    }
    public func profileSubmit(connection: JenkinsConnection, token: String, job: String, fields: [String: String]) async throws -> URL {
        let response = try await request(connection: connection, token: token, path: Self.profileJobPath(job) + "/buildWithParameters", method: "POST", fields: fields)
        guard let location = response.location, let url = URL(string: location, relativeTo: connection.baseURL)?.absoluteURL,
              Self.sameOrigin(url, connection.baseURL), url.query == nil, url.fragment == nil,
              Array(url.path.split(separator: "/").dropLast()) == connection.baseURL.path.split(separator: "/") + ["queue", "item"],
              let queueID = url.path.split(separator: "/").last.flatMap({ Int($0) }), queueID > 0 else { throw CIError.invalidResponse }
        return url
    }
    public func profileBuildURL(connection: JenkinsConnection, token: String, queueURL: URL, job: String) async throws -> URL? {
        guard Self.sameOrigin(queueURL, connection.baseURL), let queueID = queueURL.path.split(separator: "/").last.flatMap({ Int($0) }) else { throw CIError.invalidConfiguration }
        let path = try Self.profileJobPath(job)
        let response = try await request(connection: connection, token: token, path: path + "/api/json?tree=builds[number,url,queueId]{0,100}")
        let json = try JSONDecoder().decode(BridgeValue.self, from: response.data)
        return json["builds"].array?.first(where: { $0["queueId"].integer == queueID })?["url"].string.flatMap(URL.init(string:))
    }
    public func profileBuild(connection: JenkinsConnection, token: String, url: URL, job: String) async throws -> BridgeValue {
        try validateProfileBuildURL(url, connection: connection, job: job)
        let response = try await request(connection: connection, token: token, path: url.appendingPathComponent("api/json").absoluteString)
        return try JSONDecoder().decode(BridgeValue.self, from: response.data)
    }
    public func profileConsole(connection: JenkinsConnection, token: String, url: URL, job: String, offset: Int) async throws -> CIHTTPResponse {
        try validateProfileBuildURL(url, connection: connection, job: job)
        guard offset >= 0 else { throw CIError.invalidConfiguration }
        return try await request(connection: connection, token: token, path: url.appendingPathComponent("logText/progressiveText").absoluteString + "?start=\(offset)")
    }
    private func validateProfileBuildURL(_ url: URL, connection: JenkinsConnection, job: String) throws {
        let expected = connection.baseURL.appendingPathComponent(try Self.profileJobPath(job)).path
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        guard Self.sameOrigin(url, connection.baseURL), url.query == nil, url.fragment == nil,
              (path as NSString).deletingLastPathComponent == expected,
              let number = Int((path as NSString).lastPathComponent), number > 0 else { throw CIError.invalidConfiguration }
    }
    /// Account verification does not assume that any particular job exists.
    public func checkAccount(connection: JenkinsConnection, token: String) async throws {
        let response = try await request(connection: connection, token: token, path: "whoAmI/api/json")
        let value = try JSONDecoder().decode(BridgeValue.self, from: response.data)
        guard value["authenticated"] == .bool(true), value["anonymous"] != .bool(true) else { throw CIError.authentication }
    }
}
