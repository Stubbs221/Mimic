// Created by Василий Маслов on 13.10.2026.
import AppKit
import Foundation
import Network
import MCP
import MimicCore

/// Cloud metadata advertises write scopes too; never use the SDK's unfiltered default selector.
struct AtlassianReadScopes: OAuthScopeSelecting {
    let allowed: Set<String> = ["read:me", "read:account", "offline_access", "read:jira:agent-interface", "search:jira:agent-interface", "read:confluence:agent-interface", "search:confluence:agent-interface"]
    func selectScopes(challengeScope: String?, scopesSupported: [String]?) -> Set<String>? { allowed }
    func parseScopeString(_ scope: String) -> Set<String> { Set(scope.split(whereSeparator: \.isWhitespace).map(String.init)) }
    func serialize(_ scopes: Set<String>) -> String? { scopes.sorted().joined(separator: " ") }
}

/// A short-lived loopback listener receives only this OAuth flow's callback; the SDK checks state and PKCE.
@MainActor final class AtlassianOAuthBrowser: OAuthAuthorizationDelegate {
    var interactive = false
    private var listener: NWListener?
    private var callback: CheckedContinuation<URL, any Error>?
    private var timeout: Task<Void, Never>?
    private(set) var redirect: URL?
    func prepare() async throws -> URL {
        let params = NWParameters.tcp; params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params); self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                Task { @MainActor in
                    guard let self, let data, let line = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first,
                          line.hasPrefix("GET /callback?"), let path = line.split(separator: " ").dropFirst().first, let redirect = self.redirect,
                          let url = URL(string: String(path), relativeTo: redirect)?.absoluteURL else { connection.cancel(); return }
                    let body = "Mimic: " + text("work.login.complete")
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    self.complete(.success(url))
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else { continuation.resume(throwing: AtlassianError.network); return }
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/callback")!; self?.redirect = url; continuation.resume(returning: url)
                case .failed: listener.stateUpdateHandler = nil; continuation.resume(throwing: AtlassianError.network)
                default: break
                }
            } }
            listener.start(queue: .main)
        }
    }
    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        guard interactive else { throw AtlassianError.authenticationRequired }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callback = continuation
                guard NSWorkspace.shared.open(url) else { complete(.failure(AtlassianError.network)); return }
                timeout = Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(300)); if !Task.isCancelled { self?.complete(.failure(AtlassianError.cancelled)) } }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.complete(.failure(AtlassianError.cancelled)) } }
    }
    func stop() { complete(.failure(AtlassianError.cancelled)); listener?.cancel(); listener = nil }
    private func complete(_ result: Result<URL, any Error>) {
        timeout?.cancel(); timeout = nil
        guard let callback else { return }; self.callback = nil; callback.resume(with: result)
    }
}

/// Official Rovo MCP is consumed behind semantic read operations, never exported as a generic proxy.
actor AtlassianCloud: AtlassianReading {
    private let preset: AtlassianPreset
    private let keychain: AtlassianKeychain
    private let client = Client(name: "Mimic", version: MimicVersion.version)
    private var browser: AtlassianOAuthBrowser?
    private var connected = false
    private var cloudID: String?
    private var tools: [String: BridgeValue] = [:]
    private var connection: Task<Void, any Error>?
    init(preset: AtlassianPreset, keychain: AtlassianKeychain) { self.preset = preset; self.keychain = keychain }
    func connect(interactive: Bool = false) async throws {
        if connected { return }
        if let connection { try await connection.value; return }
        let task = Task { try await self.openConnection(interactive: interactive) }; connection = task
        defer { connection = nil }
        try await task.value
    }
    private func openConnection(interactive: Bool) async throws {
        let browser = await AtlassianOAuthBrowser(); self.browser = browser
        await MainActor.run { browser.interactive = interactive }
        defer { Task { @MainActor in browser.interactive = false } }
        let redirect = try await browser.prepare()
        let auth = OAuthAuthorizer(configuration: .init(grantType: .authorizationCode, authentication: .none(clientID: keychain.load()?.clientID ?? ""), authorizationRedirectURI: redirect, clientName: "Mimic", authorizationDelegate: browser), tokenStorage: keychain, scopeSelector: AtlassianReadScopes())
        let transport = HTTPClientTransport(endpoint: URL(string: "https://mcp.atlassian.com/v2/mcp?tools=all")!, configuration: .ephemeral, authorizer: auth)
        do {
            _ = try await client.connect(transport: transport)
            // The official flat catalog is paginated. Schemas are used only for fixed, allowed read names.
            var cursor: String?, seen = Set<String>()
            repeat {
                let page = try await client.listTools(cursor: cursor)
                for tool in page.tools { tools[tool.name] = try BridgeValue.encode(tool.inputSchema) }
                cursor = page.nextCursor
                if let cursor { guard seen.insert(cursor).inserted, seen.count <= 30 else { throw AtlassianError.invalidResponse } }
            } while cursor != nil
            let resources = try await call("getAccessibleAtlassianResources", [:])
            let entries = resources.array ?? resources["resources"].array ?? []
            let host = URL(string: preset.jiraURL ?? preset.confluenceURL ?? "")?.host
            guard let resource = entries.first(where: { URL(string: $0["url"].string ?? "")?.host == host }), let id = resource["id"].string else { throw AtlassianError.forbidden }
            try keychain.verifyPersistence()
            cloudID = id; connected = true; await browser.stop()
        } catch { await browser.stop(); await client.disconnect(); throw (error as? AtlassianError) ?? AtlassianError.authenticationRequired }
    }
    private func call(_ name: String, _ arguments: [String: Value]) async throws -> BridgeValue {
        let allowed: Set<String> = ["getAccessibleAtlassianResources", "getJiraIssue", "listJiraIssueRemoteIssueLinks", "searchJiraIssuesUsingJql", "getConfluenceContent", "searchConfluence", "listJiraIssueComments"]
        guard allowed.contains(name), let schema = tools[name] else { throw AtlassianError.unsupported }
        let properties = schema["properties"].object ?? [:]
        var mapped = arguments.filter { properties[$0.key] != nil }
        if let id = arguments["id"] {
            for alias in ["contentId", "pageId", "id"] where properties[alias] != nil { mapped[alias] = id; break }
        }
        if name == "getConfluenceContent" {
            if properties["contentType"] != nil { mapped["contentType"] = .string("page") }
            if properties["expand"] != nil { mapped["expand"] = .string("space,version,body.view") }
            if properties["bodyFormat"] != nil {
                let formats = properties["bodyFormat"]?["enum"].array?.compactMap(\.string) ?? []
                if let format = ["storage", "view", "markdown"].first(where: { formats.contains($0) }) { mapped["bodyFormat"] = .string(format) }
            }
        }
        guard (schema["required"].array ?? []).compactMap(\.string).allSatisfy({ mapped[$0] != nil }) else { throw AtlassianError.unsupported }
        if properties["fields"]?["type"].string == "string", let fields = arguments["fields"], let list = try BridgeValue.encode(fields).array { mapped["fields"] = .string(list.compactMap(\.string).joined(separator: ",")) }
        let context = try await client.send(CallTool.request(.init(name: name, arguments: mapped)))
        let deadline = Task { try? await Task.sleep(for: .seconds(45)); if !Task.isCancelled { try? await client.cancelRequest(context.requestID, reason: "Read deadline") } }
        defer { deadline.cancel() }
        let result = try await withTaskCancellationHandler { try await context.value } onCancel: { Task { try? await self.client.cancelRequest(context.requestID, reason: "Read cancelled") } }
        guard result.isError != true else { throw AtlassianError.invalidResponse }
        try keychain.verifyPersistence()
        if let structured = result.structuredContent { return try BridgeValue.encode(structured) }
        let encoded = try BridgeValue.encode(result.content)
        for block in encoded.array ?? [] {
            if let raw = block["text"].string, let value = try? JSONDecoder().decode(BridgeValue.self, from: Data(raw.utf8)) { return value }
        }
        throw AtlassianError.invalidResponse
    }
    private func args() async throws -> [String: Value] { try await connect(); guard let cloudID else { throw AtlassianError.authenticationRequired }; return ["cloudId": .string(cloudID)] }
    func issue(_ key: String) async throws -> WorkIssue {
        let key = try WorkReference.issue(key, preset: preset); var args = try await args(); args["issueIdOrKey"] = .string(key)
        args["fields"] = .array((["summary", "status", "assignee", "description", "issuelinks"] + (preset.requirementFields ?? [])).map { .string($0) })
        let value = try await call("getJiraIssue", args); var result = AtlassianText.issue(value, preset: preset)
        guard result.key == key, !result.title.isEmpty else { throw AtlassianError.invalidResponse }
        do { result.documents = AtlassianText.documents(try await call("listJiraIssueRemoteIssueLinks", args), description: result.description, preset: preset) }
        catch { result.incomplete = true; result.documents = AtlassianText.documents(.array([]), description: result.description, preset: preset) }
        return result
    }
    func search(_ query: String, service: String, cursor: String?) async throws -> WorkSearchResult {
        guard ["jira", "confluence"].contains(service), !query.isEmpty, query.count <= 512, (cursor?.count ?? 0) <= 2048 else { throw AtlassianError.invalidReference }; var args = try await args()
        if service == "jira" {
            args["jql"] = .string(WorkReference.jql(query, preset: preset)); args["maxResults"] = .int(20); if let cursor { args["nextPageToken"] = .string(cursor) }
            let result = try await call("searchJiraIssuesUsingJql", args)
            return .init(issues: (result["issues"].array ?? []).map { AtlassianText.issue($0, preset: preset) }, nextCursor: result["nextPageToken"].string)
        }
        guard let start = Int(cursor ?? "0"), start >= 0 else { throw AtlassianError.invalidReference }
        args["cql"] = .string(WorkReference.cql(query, preset: preset)); args["limit"] = .int(20); args["start"] = .int(start)
        let result = try await call("searchConfluence", args)
        let documents = (result["results"].array ?? []).map { AtlassianText.page($0["content"] == .null ? $0 : $0["content"], preset: preset, offset: 0, includeContent: false) }
        return .init(documents: documents, nextCursor: result["nextCursor"].string ?? (result["_links"]["next"].string == nil ? nil : String(start + documents.count)))
    }
    func page(_ id: String, offset: Int) async throws -> WorkDocument {
        let id = try WorkReference.page(id, preset: preset); var args = try await args(); args["id"] = .string(id)
        let value = try await call("getConfluenceContent", args)
        guard (value["id"].string ?? value["id"].integer.map(String.init)) == id else { throw AtlassianError.invalidResponse }
        if let spaces = preset.spaces, !spaces.isEmpty, !spaces.contains(value["space"]["key"].string ?? "") { throw AtlassianError.forbidden }
        return AtlassianText.page(value, preset: preset, offset: offset)
    }
    func comments(_ key: String, cursor: String?) async throws -> WorkSearchResult {
        guard let start = Int(cursor ?? "0"), start >= 0 else { throw AtlassianError.invalidReference }
        var args = try await args(); args["issueIdOrKey"] = .string(try WorkReference.issue(key, preset: preset)); args["maxResults"] = .int(20); args["startAt"] = .int(start)
        let value = try await call("listJiraIssueComments", args)
        let documents: [WorkDocument] = (value["comments"].array ?? []).map { .init(id: $0["id"].string ?? "", title: $0["author"]["displayName"].string ?? "", url: "", content: AtlassianText.rich($0["body"])) }
        return .init(documents: documents, nextCursor: value["nextCursor"].string ?? (start + documents.count < (value["total"].integer ?? 0) ? String(start + documents.count) : nil))
    }
}
