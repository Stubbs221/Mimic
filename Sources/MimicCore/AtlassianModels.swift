// Created by Василий Маслов on 13.10.2026.
import Foundation
import CryptoKit

// MARK: - Portable non-secret connection configuration

public enum AtlassianDeployment: String, Codable, Sendable { case cloud, dataCenter }
public enum AtlassianAuthentication: String, Codable, Sendable { case oauth, personalAccessToken, webSession }

/// A team preset describes endpoints and search boundaries; credentials never enter profiles.
public struct AtlassianPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var deployment: AtlassianDeployment
    public var authentication: AtlassianAuthentication
    public var jiraURL: String?
    public var confluenceURL: String?
    public var projects: [String]? = nil
    public var spaces: [String]? = nil
    public var requirementFields: [String]? = nil

    public init(id: String, title: String, deployment: AtlassianDeployment, authentication: AtlassianAuthentication, jiraURL: String? = nil, confluenceURL: String? = nil) {
        self.id = id; self.title = title; self.deployment = deployment; self.authentication = authentication
        self.jiraURL = jiraURL; self.confluenceURL = confluenceURL
    }

    public func validate() throws {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil, !title.isEmpty, title.count <= 256, jiraURL != nil || confluenceURL != nil,
              deployment == .cloud ? authentication == .oauth : authentication != .oauth else { throw AtlassianError.configuration }
        for raw in [jiraURL, confluenceURL].compactMap({ $0 }) {
            guard let url = URLComponents(string: raw), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { throw AtlassianError.configuration }
        }
        for key in (projects ?? []) + (spaces ?? []) + (requirementFields ?? []) {
            guard key.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { throw AtlassianError.configuration }
        }
        guard (projects?.count ?? 0) <= 100, (spaces?.count ?? 0) <= 100, (requirementFields?.count ?? 0) <= 20 else { throw AtlassianError.configuration }
        for values in [projects ?? [], spaces ?? [], requirementFields ?? []] { guard Set(values).count == values.count else { throw AtlassianError.configuration } }
    }

    /// Changing either endpoint invalidates credentials rather than sending an old session to a new host.
    public func credentialNamespace(profileID: String) -> String {
        SHA256.hash(data: Data([profileID, id, deployment.rawValue, authentication.rawValue, jiraURL ?? "", confluenceURL ?? ""].joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func sourceNamespace(profileID: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
        return credentialNamespace(profileID: profileID) + ":" + digest
    }

    public func accepts(_ url: URL, service: String) -> Bool {
        guard let base = URL(string: service == "jira" ? jiraURL ?? "" : confluenceURL ?? "") else { return false }
        let path = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        return url.scheme == "https" && url.host == base.host && url.port == base.port && url.user == nil && url.password == nil
            && (path.isEmpty || url.path == path || url.path.hasPrefix(path + "/"))
    }
}

public enum AtlassianError: String, Error, Codable, Sendable {
    case configuration, authenticationRequired, accessRequired, cancelled, forbidden, notFound, network, invalidResponse, rateLimited, unsupported, staleContext, invalidReference
}

// MARK: - Shared bounded presentation values

public struct WorkDocument: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
    public var version: Int?
    public var content: String?
    public var nextOffset: Int?
    public var incomplete = false
    public init(id: String, title: String, url: String, version: Int? = nil, content: String? = nil, nextOffset: Int? = nil) {
        self.id = id; self.title = title; self.url = url; self.version = version; self.content = content; self.nextOffset = nextOffset
    }
}

public struct WorkIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var status: String
    public var assignee: String?
    public var url: String
    public var description: String
    public var requirements: [String: String]
    public var documents: [WorkDocument]
    public var relatedIssues: [String]
    public var incomplete: Bool
    public init(key: String, title: String, status: String, url: String, description: String = "", assignee: String? = nil, requirements: [String: String] = [:], documents: [WorkDocument] = [], relatedIssues: [String] = [], incomplete: Bool = false) {
        self.key = key; self.title = title; self.status = status; self.url = url; self.description = description; self.assignee = assignee
        self.requirements = requirements; self.documents = documents; self.relatedIssues = relatedIssues; self.incomplete = incomplete
    }
    public var contextText: String {
        (["\(key) · \(title)", url, status, description] + requirements.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" } + documents.map { "\($0.title): \($0.url)" }).joined(separator: "\n\n")
    }
}

public struct WorkSearchResult: Codable, Sendable {
    public var issues: [WorkIssue] = []
    public var documents: [WorkDocument] = []
    public var nextCursor: String?
    public init(issues: [WorkIssue] = [], documents: [WorkDocument] = [], nextCursor: String? = nil) {
        self.issues = issues; self.documents = documents; self.nextCursor = nextCursor
    }
}

/// Each caller owns its selection; cached source data may be shared only inside the same connection.
public struct WorkContextSnapshot: Codable, Equatable, Sendable {
    public var presetID: String?
    public var phase = "unconfigured"
    public var candidates: [String] = []
    public var issue: WorkIssue?
    public var fetchedAt: Date?
    public var stale = false
    public var error: AtlassianError?
    public var manual = false
    public init() { }
}

public enum WorkReference {
    public static func keys(in branch: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"(?i)(?<![A-Z0-9])([A-Z][A-Z0-9_]*-[0-9]+)(?![A-Z0-9])"#)
        return Array(Set(expression.matches(in: branch, range: NSRange(branch.startIndex..., in: branch)).compactMap { Range($0.range(at: 1), in: branch).map { String(branch[$0]).uppercased() } })).sorted()
    }
    public static func issue(_ reference: String, preset: AtlassianPreset) throws -> String {
        let value: String
        if reference.hasPrefix("https://"), let url = URL(string: reference), preset.accepts(url, service: "jira") { value = url.lastPathComponent }
        else { value = reference }
        guard value.count <= 160, value.range(of: #"^[A-Za-z][A-Za-z0-9_]*-[0-9]+$"#, options: .regularExpression) != nil else { throw AtlassianError.invalidReference }
        let key = value.uppercased()
        if let projects = preset.projects, !projects.isEmpty, !projects.contains(where: { $0.uppercased() == key.split(separator: "-").first.map(String.init) }) { throw AtlassianError.forbidden }
        return key
    }
    public static func page(_ reference: String, preset: AtlassianPreset) throws -> String {
        let value: String
        if reference.hasPrefix("https://"), let url = URL(string: reference), preset.accepts(url, service: "confluence") {
            value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pageId" })?.value
                ?? url.path.split(separator: "/").drop(while: { $0 != "pages" }).dropFirst().first.map(String.init) ?? url.lastPathComponent
        } else { value = reference }
        guard !value.isEmpty, value.count <= 32, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw AtlassianError.invalidReference }; return value
    }
    public static func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    public static func jql(_ query: String, preset: AtlassianPreset) -> String {
        let projects = (preset.projects ?? []).map(quoted).joined(separator: ",")
        return (projects.isEmpty ? "" : "project in (\(projects)) AND ") + "text ~ \(quoted(query)) ORDER BY updated DESC"
    }
    public static func cql(_ query: String, preset: AtlassianPreset) -> String {
        let spaces = (preset.spaces ?? []).map(quoted).joined(separator: ",")
        return "type=page AND " + (spaces.isEmpty ? "" : "space in (\(spaces)) AND ") + "text ~ \(quoted(query))"
    }
}

/// Shared operations are semantic reads; neither arbitrary URLs nor server mutation tools are exposed.
public protocol AtlassianReading: Sendable {
    func issue(_ key: String) async throws -> WorkIssue
    func search(_ query: String, service: String, cursor: String?) async throws -> WorkSearchResult
    func page(_ id: String, offset: Int) async throws -> WorkDocument
    func comments(_ key: String, cursor: String?) async throws -> WorkSearchResult
}

public enum AtlassianBridge {
    public static let tools = ["get_work_context", "jira_get_issue", "jira_search", "jira_get_comments", "confluence_search", "confluence_get_page", "get_work_report"]
    public static let appTools = ["panel_work_context", "panel_work_select", "panel_work_search", "panel_work_page", "panel_work_report", "panel_work_connect"]
}
