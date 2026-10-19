// Created by Василий Маслов on 13.10.2026.
import Foundation

// MARK: - Same-origin read transport

/// A REST redirect never receives the original credentials, including SSO redirects.
private final class AtlassianNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct AtlassianREST: AtlassianReading {
    public let preset: AtlassianPreset
    private let headers: [String: [String: String]]
    public init(preset: AtlassianPreset, headers: [String: [String: String]]) { self.preset = preset; self.headers = headers }

    public func verifyIdentity(_ service: String) async throws {
        let value = try await get(service, path: service == "jira" ? "/rest/api/2/myself" : "/rest/api/user/current")
        guard AtlassianText.authenticatedIdentity(value, service: service) else { throw AtlassianError.authenticationRequired }
    }

    public func get(_ service: String, path: String, query: [String: String] = [:]) async throws -> BridgeValue {
        let allowed = service == "jira" ? #"^/rest/api/2/(myself|issue/[A-Z][A-Z0-9_]*-[0-9]+(?:/remotelink|/comment)?|search)$"# : #"^/rest/api/(user/current|content/search|content/[0-9]+)$"#
        guard path.range(of: allowed, options: .regularExpression) != nil else { throw AtlassianError.invalidReference }
        guard let base = URL(string: service == "jira" ? preset.jiraURL ?? "" : preset.confluenceURL ?? ""), let credentials = headers[service] else { throw AtlassianError.authenticationRequired }
        let suffix = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        url.path = suffix + path; url.queryItems = query.sorted(by: { $0.key < $1.key }).map { .init(name: $0.key, value: $0.value) }
        guard let endpoint = url.url, preset.accepts(endpoint, service: service) else { throw AtlassianError.configuration }
        var request = URLRequest(url: endpoint); request.timeoutInterval = 20; request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in credentials { request.setValue(value, forHTTPHeaderField: key) }
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: AtlassianNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch is CancellationError { throw AtlassianError.cancelled } catch { throw AtlassianError.network }
        guard let http = response as? HTTPURLResponse else { throw AtlassianError.invalidResponse }
        switch http.statusCode {
        case 200 ... 299: break
        case 401, 300 ... 399: throw AtlassianError.authenticationRequired
        case 403: throw AtlassianError.forbidden
        case 404: throw AtlassianError.notFound
        case 429: throw AtlassianError.rateLimited
        default: throw AtlassianError.network
        }
        guard data.count <= 8 * 1024 * 1024, (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json"), let result = try? JSONDecoder().decode(BridgeValue.self, from: data) else { throw AtlassianError.invalidResponse }
        return result
    }

    public func issue(_ key: String) async throws -> WorkIssue {
        let key = try WorkReference.issue(key, preset: preset)
        let fields = ["summary", "status", "assignee", "description", "issuelinks"] + (preset.requirementFields ?? [])
        let value = try await get("jira", path: "/rest/api/2/issue/" + key, query: ["fields": fields.joined(separator: ",")])
        var result = AtlassianText.issue(value, preset: preset)
        guard result.key == key, !result.title.isEmpty else { throw AtlassianError.invalidResponse }
        do {
            let links = try await get("jira", path: "/rest/api/2/issue/" + key + "/remotelink")
            result.documents = AtlassianText.documents(links, description: result.description, preset: preset)
        } catch { result.incomplete = true; result.documents = AtlassianText.documents(.array([]), description: result.description, preset: preset) }
        return result
    }
    public func search(_ query: String, service: String, cursor: String?) async throws -> WorkSearchResult {
        guard ["jira", "confluence"].contains(service), !query.isEmpty, query.count <= 512, let start = Int(cursor ?? "0"), start >= 0 else { throw AtlassianError.invalidReference }
        if service == "jira" {
            let result = try await get("jira", path: "/rest/api/2/search", query: ["jql": WorkReference.jql(query, preset: preset), "startAt": String(start), "maxResults": "20", "fields": "summary,status"])
            let issues = (result["issues"].array ?? []).map { AtlassianText.issue($0, preset: preset) }
            return .init(issues: issues, nextCursor: start + issues.count < (result["total"].integer ?? 0) ? String(start + issues.count) : nil)
        }
        let result = try await get("confluence", path: "/rest/api/content/search", query: ["cql": WorkReference.cql(query, preset: preset), "start": String(start), "limit": "20", "expand": "version,space"])
        let docs = (result["results"].array ?? []).map { AtlassianText.page($0, preset: preset, offset: 0, includeContent: false) }
        return .init(documents: docs, nextCursor: result["_links"]["next"].string == nil ? nil : String(start + docs.count))
    }
    public func page(_ id: String, offset: Int) async throws -> WorkDocument {
        let id = try WorkReference.page(id, preset: preset)
        let result = try await get("confluence", path: "/rest/api/content/" + id, query: ["expand": "space,version,body.view"])
        guard (result["id"].string ?? result["id"].integer.map(String.init)) == id else { throw AtlassianError.invalidResponse }
        if let spaces = preset.spaces, !spaces.isEmpty, !spaces.contains(result["space"]["key"].string ?? "") { throw AtlassianError.forbidden }
        return AtlassianText.page(result, preset: preset, offset: offset)
    }
    public func comments(_ key: String, cursor: String?) async throws -> WorkSearchResult {
        let key = try WorkReference.issue(key, preset: preset); guard let start = Int(cursor ?? "0"), start >= 0 else { throw AtlassianError.invalidReference }
        let result = try await get("jira", path: "/rest/api/2/issue/" + key + "/comment", query: ["startAt": String(start), "maxResults": "20"])
        let docs = (result["comments"].array ?? []).map { WorkDocument(id: $0["id"].string ?? "", title: $0["author"]["displayName"].string ?? "", url: (preset.jiraURL ?? "") + "/browse/" + key, content: rich($0["body"])) }
        return .init(documents: docs, nextCursor: start + docs.count < (result["total"].integer ?? 0) ? String(start + docs.count) : nil)
    }
    private func rich(_ value: BridgeValue) -> String { AtlassianText.rich(value) }
}

// MARK: - Non-executable rich content normalization

public enum AtlassianText {
    public static func authenticatedIdentity(_ value: BridgeValue, service: String) -> Bool {
        guard value["type"].string != "anonymous" else { return false }
        let fields = service == "jira" ? ["name", "accountId"] : ["username", "userKey", "accountId"]
        return fields.contains { !(value[$0].string ?? "").isEmpty }
    }
    public static func rich(_ value: BridgeValue, depth: Int = 0) -> String {
        guard depth < 32 else { return "" }
        if let string = value.string { return String(string.prefix(64_000)) }
        let content = (value["content"].array ?? []).map { rich($0, depth: depth + 1) }.joined()
        switch value["type"].string {
        case "text":
            let text = value["text"].string ?? ""
            if let mark = value["marks"].array?.first(where: { $0["type"].string == "link" }), let url = mark["attrs"]["href"].string, url.hasPrefix("https://") { return "[\(text)](\(url))" }
            return text
        case "hardBreak": return "\n"
        case "heading": return "\n" + String(repeating: "#", count: min(6, value["attrs"]["level"].integer ?? 2)) + " " + content + "\n"
        case "listItem": return "- " + content + "\n"
        case "tableCell", "tableHeader": return content.trimmingCharacters(in: .whitespacesAndNewlines) + " | "
        case "paragraph", "tableRow", "bulletList", "orderedList": return content + "\n"
        default: return content
        }
    }
    public static func html(_ source: String) -> String {
        var result = String(source.prefix(512_000))
        result = result.replacingOccurrences(of: #"(?is)<(script|style|iframe)[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?is)<a[^>]*href=["'](https://[^"']*)["'][^>]*>(.*?)</a>"#, with: "[$2]($1)", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)<li[^>]*>"#, with: "\n- ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)</(?:p|h[1-6]|div|li|tr)>|<br\s*/?>"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)</(?:td|th)>"#, with: " | ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { result = result.replacingOccurrences(of: entity, with: character) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func issue(_ value: BridgeValue, preset: AtlassianPreset) -> WorkIssue {
        let f = value["fields"], key = value["key"].string ?? value["id"].string ?? ""
        let description = rich(f["description"])
        return WorkIssue(key: key, title: String((f["summary"].string ?? value["summary"].string ?? "").prefix(1024)), status: String((f["status"]["name"].string ?? "").prefix(256)), url: (preset.jiraURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/browse/" + key, description: String(description.prefix(64_000)), assignee: f["assignee"]["displayName"].string,
                         requirements: Dictionary(uniqueKeysWithValues: (preset.requirementFields ?? []).filter { f[$0] != .null }.map { ($0, String(rich(f[$0]).prefix(64_000))) }), relatedIssues: Array((f["issuelinks"].array ?? []).compactMap { $0["outwardIssue"]["key"].string ?? $0["inwardIssue"]["key"].string }.prefix(50)), incomplete: description.count >= 64_000)
    }
    public static func page(_ value: BridgeValue, preset: AtlassianPreset, offset: Int, includeContent: Bool = true) -> WorkDocument {
        let id = value["id"].string ?? value["id"].integer.map(String.init) ?? "", raw = value["body"]["view"]["value"].string ?? value["body"]["storage"]["value"].string ?? value["body"]["value"].string ?? value["body"]["markdown"].string ?? value["content"].string ?? ""
        let body = html(raw), start = min(body.count, max(0, offset)), chunk = String(body.dropFirst(start).prefix(16_000))
        var document = WorkDocument(id: id, title: String((value["title"].string ?? "").prefix(1024)), url: (preset.confluenceURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/pages/viewpage.action?pageId=" + id, version: value["version"]["number"].integer, content: includeContent ? chunk : nil, nextOffset: includeContent && start + chunk.count < body.count ? start + chunk.count : nil)
        document.incomplete = includeContent && (raw.isEmpty || raw.count > 512_000); return document
    }
    public static func documents(_ links: BridgeValue, description: String, preset: AtlassianPreset) -> [WorkDocument] {
        var results: [String: WorkDocument] = [:]
        for link in links.array ?? [] {
            guard let raw = link["object"]["url"].string, let id = try? WorkReference.page(raw, preset: preset) else { continue }
            results[id] = .init(id: id, title: link["object"]["title"].string ?? id, url: raw)
        }
        let expression = try! NSRegularExpression(pattern: #"https://[^\s<>\]\)\"']+"#)
        for match in expression.matches(in: description, range: NSRange(description.startIndex..., in: description)) {
            guard let range = Range(match.range, in: description) else { continue }; let raw = String(description[range])
            if let id = try? WorkReference.page(raw, preset: preset), results[id] == nil { results[id] = .init(id: id, title: id, url: raw) }
        }
        return results.values.sorted { $0.id < $1.id }
    }
}
