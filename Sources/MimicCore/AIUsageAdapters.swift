//
//  AIUsageAdapters.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import CryptoKit
import Foundation
import Security
import LocalAuthentication

/// Local directories shared by CLI and desktop agents. No shell startup scripts are evaluated.
public struct AIUsageLocations: Sendable {
    public let codex: URL
    public let claude: URL
    public let claudeDesktop: URL
    public let customClaudeDirectory: String?
    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.codex = Self.directory(environment["CODEX_HOME"], fallback: home.appendingPathComponent(".codex"))
        self.claude = Self.directory(environment["CLAUDE_CONFIG_DIR"], fallback: home.appendingPathComponent(".claude"))
        self.customClaudeDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        self.claudeDesktop = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }
    private static func directory(_ path: String?, fallback: URL) -> URL {
        guard let path, !path.isEmpty else { return fallback }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

func usageDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// MARK: - Claude Code credentials and HTTP

/// Credentials live only for a fetch. There is deliberately no Codable conformance or token writer.
public struct ClaudeUsageCredential: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let plan: String?
    let hasUsageScope: Bool
    var identity: String { usageDigest(Data(self.accessToken.utf8)) }
    public init(data: Data) throws {
        let object = try AIUsageDecoder.object(data)
        guard let oauth = object["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIUsageError.authentication }
        self.accessToken = token
        self.expiresAt = AIUsageDecoder.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        self.plan = oauth["rateLimitTier"] as? String ?? oauth["subscriptionType"] as? String
        let scopes = oauth["scopes"] as? [String]
        self.hasUsageScope = scopes == nil || scopes?.isEmpty == true || scopes?.contains("user:profile") == true
    }
    func isUsable(at date: Date) -> Bool { self.hasUsageScope && (self.expiresAt.map { $0 > date } ?? true) }
}

@MainActor
public protocol ClaudeUsageCredentialReading {
    func candidates(manual: Bool) throws -> [ClaudeUsageCredential]
}

/// Reads the selected Claude Code login; background refresh must never prompt for Keychain access.
@MainActor
public struct NativeClaudeUsageCredentials: ClaudeUsageCredentialReading {
    private let locations: AIUsageLocations
    public init(locations: AIUsageLocations = AIUsageLocations()) { self.locations = locations }
    public func candidates(manual: Bool) throws -> [ClaudeUsageCredential] {
        let base = "Claude Code-credentials"
        let services = self.locations.customClaudeDirectory.map { [base + "-" + usageDigest(Data($0.precomposedStringWithCanonicalMapping.utf8)).prefix(8), base] } ?? [base]
        var candidates: [ClaudeUsageCredential] = [], blocked = false
        for service in services {
            for account in [NSUserName(), nil] as [String?] {
                let context = LAContext(); context.interactionNotAllowed = !manual
                var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
                if let account { query[kSecAttrAccount as String] = account }
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled { blocked = true }
                if status == errSecSuccess, let data = result as? Data, let credential = try? ClaudeUsageCredential(data: data), !candidates.contains(where: { $0.identity == credential.identity }) { candidates.append(credential) }
            }
        }
        if let data = try? Data(contentsOf: self.locations.claude.appendingPathComponent(".credentials.json")), let credential = try? ClaudeUsageCredential(data: data), !candidates.contains(where: { $0.identity == credential.identity }) { candidates.append(credential) }
        if candidates.isEmpty { throw blocked ? AIUsageError.keychainAccess : AIUsageError.authentication }
        return candidates
    }
}

/// Only GET requests to Anthropic are constructed by the adapter; no credential refresh is performed.
@MainActor
public protocol AIUsageHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

@MainActor
public final class NativeAIUsageHTTP: AIUsageHTTPTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCache = nil
        self.session = URLSession(configuration: config)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await self.session.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count <= 1024 * 1024 else { throw AIUsageError.invalidResponse }
            return (data, response)
        } catch let error as AIUsageError { throw error }
        catch let error as URLError { throw error.code == .timedOut ? AIUsageError.timeout : error.code == .cancelled ? AIUsageError.cancelled : AIUsageError.network }
        catch { throw AIUsageError.network }
    }
}

@MainActor
public final class ClaudeUsageAdapter: AIUsageFetching {
    public let provider = AIProvider.claude
    private let credentials: any ClaudeUsageCredentialReading
    private let http: any AIUsageHTTPTransport
    private let now: () -> Date
    public init(credentials: any ClaudeUsageCredentialReading = NativeClaudeUsageCredentials(), http: any AIUsageHTTPTransport = NativeAIUsageHTTP(), now: @escaping () -> Date = Date.init) {
        self.credentials = credentials; self.http = http; self.now = now
    }
    private var currentRevision = "unavailable"
    public func revision() -> String { self.currentRevision }
    public func fetch(manual: Bool) async throws -> AIUsageFetchResult {
        let candidates = try self.credentials.candidates(manual: manual)
        for credential in candidates where credential.isUsable(at: self.now()) {
            do {
                let usage = try await self.get("usage", token: credential.accessToken)
                let profile: Data?
                do { profile = try await self.get("profile", token: credential.accessToken) }
                catch let error as AIUsageError {
                    if case .rateLimited = error { throw error }
                    profile = nil
                }
                try Task.checkCancellation()
                let snapshot = try AIUsageDecoder.claude(usage: usage, profile: profile, identity: credential.identity, fallbackPlan: credential.plan, now: self.now())
                // Account identity is stable across OAuth token refreshes when the profile is available.
                self.currentRevision = usageDigest(Data(snapshot.accountID.utf8))
                return AIUsageFetchResult(snapshot: snapshot, revision: self.currentRevision)
            } catch let error as AIUsageError where error == .authentication { continue }
        }
        throw AIUsageError.authentication
    }
    private func get(_ resource: String, token: String) async throws -> Data {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/" + resource) else { throw AIUsageError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.timeoutInterval = 10
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await self.http.send(request)
        switch response.statusCode {
        case 200 ..< 300: return data
        case 401, 403: throw AIUsageError.authentication
        case 429: throw AIUsageError.rateLimited(retryAt: Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: self.now()))
        default: throw AIUsageError.network
        }
    }
    public static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite { return now.addingTimeInterval(max(0, seconds)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return formatter.date(from: value)
    }
}

// MARK: - Codex app-server

/// Minimal account-only transport; never creates a thread, runs inference or exposes a listening port.
@MainActor
public protocol CodexUsageRPC: AnyObject, Sendable {
    func start(executable: String, home: URL) throws
    func request(method: String, params: Data?) async throws -> Data
    func notify(method: String) throws
    func stop()
}

@MainActor
public final class CodexUsageAdapter: AIUsageFetching {
    public let provider = AIProvider.codex
    private let executable: () -> String?
    private let home: URL
    private let makeRPC: () -> any CodexUsageRPC
    private let now: () -> Date
    public init(executable: @escaping () -> String?, home: URL = AIUsageLocations().codex, makeRPC: @escaping () -> any CodexUsageRPC = { NativeCodexUsageRPC() }, now: @escaping () -> Date = Date.init) {
        self.executable = executable; self.home = home; self.makeRPC = makeRPC; self.now = now
    }
    private var currentRevision = "unavailable"
    public func revision() -> String { self.currentRevision }
    public func fetch(manual: Bool) async throws -> AIUsageFetchResult {
        guard let executable = self.executable() else { throw AIUsageError.missingCLI }
        let rpc = self.makeRPC(); try rpc.start(executable: executable, home: self.home)
        defer { rpc.stop() }
        return try await withTaskCancellationHandler {
            _ = try await rpc.request(method: "initialize", params: Data(#"{"clientInfo":{"name":"mimic_usage","title":"Mimic","version":"1.0.0"},"capabilities":{}}"#.utf8))
            try rpc.notify(method: "initialized")
            let account = try await rpc.request(method: "account/read", params: Data(#"{"refreshToken":false}"#.utf8))
            let limits = try await rpc.request(method: "account/rateLimits/read", params: nil)
            try Task.checkCancellation()
            let snapshot = try AIUsageDecoder.codex(account: account, limits: limits, now: self.now())
            self.currentRevision = usageDigest(Data(snapshot.accountID.utf8))
            return AIUsageFetchResult(snapshot: snapshot, revision: self.currentRevision)
        } onCancel: { Task { @MainActor in rpc.stop() } }
    }
}

/// One short-lived, bounded JSON-lines subprocess with sequential request IDs and a per-request deadline.
@MainActor
public final class NativeCodexUsageRPC: CodexUsageRPC {
    private var process: Process?
    private var stdin: Pipe?, stdout: Pipe?, stderr: Pipe?
    private var buffer = Data()
    private var nextID = 0
    private var pending: (Int, CheckedContinuation<Data, any Error>)?
    private var deadline: Task<Void, Never>?
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 12) { self.timeout = timeout }
    public func start(executable: String, home: URL) throws {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        self.process = process; self.stdin = input; self.stdout = output; self.stderr = errors
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", "mcp_servers={}", "-c", "analytics.enabled=false", "-c", "feedback.enabled=false", "app-server", "--listen", "stdio://"]
        process.environment = AIProviderAdapters.environment(); process.environment?["CODEX_HOME"] = home.path
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
        process.terminationHandler = { [weak self] _ in Task { @MainActor [weak self] in self?.fail(.unsupported) } }
        do { try process.run() } catch { self.stop(); throw AIUsageError.missingCLI }
    }
    public func request(method: String, params: Data?) async throws -> Data {
        try Task.checkCancellation()
        guard self.pending == nil, self.process?.isRunning == true else { throw AIUsageError.unsupported }
        self.nextID += 1; let id = self.nextID
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = try JSONSerialization.jsonObject(with: params) }
        let data = try JSONSerialization.data(withJSONObject: message) + Data([10])
        return try await withCheckedThrowingContinuation { continuation in
            self.pending = (id, continuation)
            do { try self.stdin?.fileHandleForWriting.write(contentsOf: data) } catch { self.fail(.network); return }
            self.deadline = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(self.timeout)) } catch { return }
                self.fail(.timeout); self.stop()
            }
        }
    }
    public func notify(method: String) throws {
        try self.stdin?.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["method": method]) + Data([10]))
    }
    public func stop() {
        self.fail(.cancelled)
        self.stdout?.fileHandleForReading.readabilityHandler = nil; self.stderr?.fileHandleForReading.readabilityHandler = nil
        try? self.stdin?.fileHandleForWriting.close()
        if let process = self.process, process.isRunning {
            process.terminate()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        self.process?.terminationHandler = nil; self.process = nil
        self.stdin = nil; self.stdout = nil; self.stderr = nil; self.buffer.removeAll()
    }
    private func fail(_ error: AIUsageError) {
        self.deadline?.cancel(); self.deadline = nil
        let pending = self.pending; self.pending = nil; pending?.1.resume(throwing: error)
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { self.fail(.unsupported); return }
        guard self.buffer.count + data.count <= 1024 * 1024 else { self.fail(.invalidResponse); self.stop(); return }
        self.buffer.append(data)
        while let newline = self.buffer.firstIndex(of: 10) {
            let line = self.buffer.prefix(upTo: newline); self.buffer.removeSubrange(...newline)
            guard let message = try? AIUsageDecoder.object(Data(line)) else { self.fail(.invalidResponse); self.stop(); return }
            guard let id = message["id"] as? Int, let pending = self.pending, pending.0 == id else { continue }
            if let error = message["error"] as? [String: Any] {
                let code = error["code"] as? Int
                let message = (error["message"] as? String ?? "").lowercased()
                self.fail(message.contains("auth") || message.contains("login") || message.contains("sign in") ? .authentication : code == 429 || message.contains("429") ? .rateLimited(retryAt: nil) : .unsupported)
            } else if let result = message["result"], let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                self.pending = nil; self.deadline?.cancel(); self.deadline = nil; pending.1.resume(returning: data)
            } else { self.fail(.invalidResponse) }
        }
    }
}
