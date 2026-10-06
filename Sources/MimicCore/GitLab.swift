//
//  GitLab.swift
//  MimicCore
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation

/// Persisted configuration contains no credential; its UUID is the Keychain reference.
public struct GitLabConnection: Codable, Equatable, Sendable {
    public let id: UUID
    public let baseURL: URL
    public let projectID: Int
    public let projectPath: String
    public init(id: UUID = UUID(), baseURL: URL, projectID: Int, projectPath: String) {
        self.id = id; self.baseURL = baseURL; self.projectID = projectID; self.projectPath = projectPath
    }
}

public enum CIError: Error, Equatable, Sendable {
    case invalidConfiguration
    case authentication
    case forbidden
    case notFound
    case rateLimited(TimeInterval)
    case network
    case invalidResponse
    case server
    case credential
    public var localizationKey: String {
        switch self {
        case .invalidConfiguration: "ci.error.configuration"
        case .authentication: "ci.error.authentication"
        case .forbidden: "ci.error.forbidden"
        case .notFound: "ci.error.notFound"
        case .rateLimited: "ci.error.rateLimited"
        case .network: "ci.error.network"
        case .invalidResponse: "ci.error.response"
        case .server: "ci.error.server"
        case .credential: "ci.error.credential"
        }
    }

    public var pausesPolling: Bool { self == .authentication || self == .forbidden || self == .credential }
}

public struct CIProject: Decodable, Sendable {
    public let id: Int
    public let pathWithNamespace: String
    private enum CodingKeys: String, CodingKey { case id; case pathWithNamespace = "path_with_namespace" }
}

/// Unknown future statuses remain visible, rather than decoding to success.
public struct CIPipeline: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let status: String
    public let sha: String
    public let ref: String
    public let webURL: URL
    public let createdAt: Date?
    public let projectID: Int?
    public var name: String? = nil
    public var source: String? = nil
    public var startedAt: Date? = nil
    public var finishedAt: Date? = nil
    public var duration: Double? = nil
    public var user: CIUser? = nil
    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case sha
        case ref
        case webURL = "web_url"
        case createdAt = "created_at"
        case projectID = "project_id"
        case name, source, duration, user
        case startedAt = "started_at", finishedAt = "finished_at"
    }
}

public struct CIJob: Decodable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let stage: String
    public let status: String
    public let webURL: URL
    public let allowFailure: Bool
    public var startedAt: Date? = nil
    public var finishedAt: Date? = nil
    public var duration: Double? = nil
    public var commit: CICommit? = nil
    private enum CodingKeys: String, CodingKey { case id, name, stage, status, duration, commit; case webURL = "web_url", allowFailure = "allow_failure", startedAt = "started_at", finishedAt = "finished_at" }
}

public struct CIBridge: Decodable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let status: String
    public let webURL: URL
    public let downstreamPipeline: CIPipeline?
    public var allowFailure: Bool? = nil
    private enum CodingKeys: String, CodingKey { case id, name, status; case webURL = "web_url", downstreamPipeline = "downstream_pipeline", allowFailure = "allow_failure" }
}

/// A bridge failure must not hide already loaded jobs or imply child pipeline success.
public struct CIPipelineDetails: Sendable {
    public let jobs: [CIJob]
    public let bridges: [CIBridge]
    public let bridgeError: CIError?
    public init(jobs: [CIJob], bridges: [CIBridge], bridgeError: CIError? = nil) {
        self.jobs = jobs; self.bridges = bridges; self.bridgeError = bridgeError
    }
}

public protocol GitLabService: Sendable {
    func project(baseURL: URL, path: String, token: String) async throws -> CIProject
    func pipelines(connection: GitLabConnection, branch: String, token: String) async throws -> [CIPipeline]
    func details(connection: GitLabConnection, pipelineID: Int, token: String) async throws -> CIPipelineDetails
    /// Resolves the authenticated account; the token is never used as a persisted identity.
    func currentUser(connection: GitLabConnection, token: String) async throws -> CIUser
    /// Searches public identities of project members for explicit local subscriptions.
    func users(connection: GitLabConnection, search: String, token: String) async throws -> [CIUser]
    /// Lists project-wide pipelines; username filters the initiator, not the commit author.
    func pipelinePage(connection: GitLabConnection, username: String?, page: Int, perPage: Int, token: String) async throws -> CIPipelinePage
    /// Reads a known pipeline identity without substituting the latest run of its branch.
    func pipeline(connection: GitLabConnection, id: Int, token: String) async throws -> CIPipeline
    func commit(connection: GitLabConnection, sha: String, token: String) async throws -> CICommit
}

public struct CIHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let nextPage: String?
    public let retryAfter: TimeInterval?
    public let location: String?
    public let textSize: Int?
    public let moreData: Bool
    public init(data: Data, status: Int, nextPage: String? = nil, retryAfter: TimeInterval? = nil, location: String? = nil, textSize: Int? = nil, moreData: Bool = false) {
        self.data = data; self.status = status; self.nextPage = nextPage; self.retryAfter = retryAfter
        self.location = location; self.textSize = textSize; self.moreData = moreData
    }
}

/// Enables deterministic HTTP fixtures without access to a live GitLab or token.
public protocol CIHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CIHTTPResponse
}

/// Credentials are never forwarded through redirects, even to an authentication page.
private final class NoCIRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionCITransport: CIHTTPTransport {
    public init() { }
    public func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoCIRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CIError.invalidResponse }
        let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        return CIHTTPResponse(data: data, status: response.statusCode, nextPage: response.value(forHTTPHeaderField: "X-Next-Page"), retryAfter: retry, location: response.value(forHTTPHeaderField: "Location"), textSize: response.value(forHTTPHeaderField: "X-Text-Size").flatMap(Int.init), moreData: response.value(forHTTPHeaderField: "X-More-Data") == "true")
    }
}

/// Read-only REST client; tokens are headers, never URL parameters or process arguments.
public struct GitLabClient: GitLabService {
    private let transport: any CIHTTPTransport
    public init(transport: any CIHTTPTransport = URLSessionCITransport()) { self.transport = transport }

    public static func baseURL(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { throw CIError.invalidConfiguration }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw CIError.invalidConfiguration }
        return url
    }

    public func project(baseURL: URL, path: String, token: String) async throws -> CIProject {
        guard !path.isEmpty, let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) else { throw CIError.invalidConfiguration }
        let response = try await request(baseURL: baseURL, path: "projects/" + encoded, token: token)
        return try self.decode(CIProject.self, data: response.data)
    }

    public func currentUser(connection: GitLabConnection, token: String) async throws -> CIUser {
        let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: "user", token: token)
        return try self.decode(CIUser.self, data: response.data)
    }

    public func users(connection: GitLabConnection, search: String, token: String) async throws -> [CIUser] {
        let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: "projects/\(connection.projectID)/users",
            query: [URLQueryItem(name: "search", value: search), URLQueryItem(name: "per_page", value: "100")], token: token)
        return try self.decode([CIUser].self, data: response.data)
    }

    public func pipelinePage(connection: GitLabConnection, username: String?, page: Int = 1, perPage: Int = 100, token: String) async throws -> CIPipelinePage {
        guard page > 0, (1 ... 100).contains(perPage) else { throw CIError.invalidConfiguration }
        var query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "order_by", value: "id"), URLQueryItem(name: "sort", value: "desc")]
        if let username { query.append(URLQueryItem(name: "username", value: username)) }
        let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: "projects/\(connection.projectID)/pipelines", query: query, token: token)
        let next: Int?
        if let value = response.nextPage, !value.isEmpty {
            guard let number = Int(value), number > page else { throw CIError.invalidResponse }
            next = number
        } else { next = nil }
        return CIPipelinePage(pipelines: try self.decode([CIPipeline].self, data: response.data), nextPage: next)
    }

    public func pipelines(connection: GitLabConnection, branch: String, token: String) async throws -> [CIPipeline] {
        let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: "projects/\(connection.projectID)/pipelines", query: [URLQueryItem(name: "ref", value: branch), URLQueryItem(name: "per_page", value: "5"), URLQueryItem(name: "order_by", value: "id"), URLQueryItem(name: "sort", value: "desc")], token: token)
        return try Array(self.decode([CIPipeline].self, data: response.data).prefix(5))
    }

    public func details(connection: GitLabConnection, pipelineID: Int, token: String) async throws -> CIPipelineDetails {
        let path = "projects/\(connection.projectID)/pipelines/\(pipelineID)"
        let jobs: [CIJob] = try await pages(connection: connection, path: path + "/jobs", token: token)
        do {
            let bridges: [CIBridge]
            do { bridges = try await self.pages(connection: connection, path: path + "/bridges", token: token) }
            catch CIError.notFound { bridges = try await self.pages(connection: connection, path: path + "/trigger_jobs", token: token) }
            return CIPipelineDetails(jobs: jobs, bridges: bridges)
        } catch is CancellationError { throw CancellationError() }
        catch { return CIPipelineDetails(jobs: jobs, bridges: [], bridgeError: error as? CIError ?? .network) }
    }

    /// Branch search is remote-only and never fetches or switches the local Git checkout.
    public func branches(connection: GitLabConnection, search: String, token: String) async throws -> [String] {
        let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: "projects/\(connection.projectID)/repository/branches", query: [URLQueryItem(name: "search", value: search), URLQueryItem(name: "per_page", value: "100")], token: token)
        struct Branch: Decodable { let name: String }
        return try self.decode([Branch].self, data: response.data).map(\.name)
    }

    /// Existence checks use the encoded branch endpoint, independent of search pagination or regular expressions.
    public func branchExists(connection: GitLabConnection, branch: String, token: String) async throws -> Bool {
        guard !branch.isEmpty, branch.utf8.count <= 1024, let encoded = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) else { throw CIError.invalidConfiguration }
        do {
            let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: "projects/\(connection.projectID)/repository/branches/" + encoded, token: token)
            struct Branch: Decodable { let name: String }
            return try self.decode(Branch.self, data: response.data).name == branch
        } catch CIError.notFound { return false }
    }

    /// Reads exactly the pipeline accepted by Jenkins, independent of the latest branch pipeline.
    public func pipeline(connection: GitLabConnection, id: Int, token: String) async throws -> CIPipeline {
        let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: "projects/\(connection.projectID)/pipelines/\(id)", token: token)
        return try self.decode(CIPipeline.self, data: response.data)
    }

    /// Reads only the specific commit's ID and title, without retaining author or message fields.
    public func commit(connection: GitLabConnection, sha: String, token: String) async throws -> CICommit {
        guard !sha.isEmpty, sha.utf8.count <= 128,
              let encoded = sha.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw CIError.invalidConfiguration }
        let response = try await self.request(baseURL: connection.baseURL, credentialID: connection.id, path: "projects/\(connection.projectID)/repository/commits/" + encoded, query: [URLQueryItem(name: "stats", value: "false")], token: token)
        let commit = try self.decode(CICommit.self, data: response.data)
        guard commit.id == sha else { throw CIError.invalidResponse }
        return commit
    }

    /// Only the small Allure launch ID artifact is read; CI logs and test results are excluded.
    public func allureID(connection: GitLabConnection, jobID: Int, token: String) async throws -> Int? {
        try await self.reportID(connection: connection, jobID: jobID, artifactPath: "logs/allure_launch_id", token: token)
    }
    public func reportID(connection: GitLabConnection, jobID: Int, artifactPath: String, token: String) async throws -> Int? {
        guard ProfileValidation.relativePath(artifactPath) else { throw CIError.invalidConfiguration }
        let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: "projects/\(connection.projectID)/jobs/\(jobID)/artifacts/" + artifactPath, token: token)
        guard response.data.count <= 128 else { throw CIError.invalidResponse }
        return Int(String(decoding: response.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func pages<Item: Decodable & Sendable>(connection: GitLabConnection, path: String, token: String) async throws -> [Item] {
        var result: [Item] = [], page = "1", visited = Set<String>()
        repeat {
            try Task.checkCancellation()
            guard visited.insert(page).inserted, visited.count <= 20, Int(page) != nil else { throw CIError.invalidResponse }
            let response = try await request(baseURL: connection.baseURL, credentialID: connection.id, path: path, query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: page)], token: token)
            result += try self.decode([Item].self, data: response.data)
            page = response.nextPage ?? ""
        } while !page.isEmpty
        return result
    }

    private func request(baseURL: URL, credentialID: UUID? = nil, path: String, query: [URLQueryItem] = [], token: String) async throws -> CIHTTPResponse {
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r"),
              var components = try URLComponents(url: Self.baseURL(baseURL.absoluteString), resolvingAgainstBaseURL: false) else { throw CIError.invalidConfiguration }
        components.percentEncodedPath += "/api/v4/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw CIError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: CIHTTPResponse
        do { response = try await CICredentialRequestContext.$connectionID.withValue(credentialID ?? CICredentialRequestContext.connectionID) { try await self.transport.send(request) } }
        catch { if Task.isCancelled || error is CancellationError { throw CancellationError() }; throw error as? CIError ?? CIError.network }
        switch response.status {
        case 200 ... 299: return response
        case 301 ... 399,
             401: throw CIError.authentication
        case 403: throw CIError.forbidden
        case 404: throw CIError.notFound
        case 429: throw CIError.rateLimited(max(1, response.retryAfter ?? 30))
        default: throw CIError.server
        }
    }

    private func decode<Item: Decodable>(_ type: Item.Type, data: Data) throws -> Item {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw CIError.invalidResponse }
            return date
        }
        do { return try decoder.decode(type, from: data) } catch { throw CIError.invalidResponse }
    }
}
