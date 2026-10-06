//
//  AIUsageTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
@testable import MimicCore

@Suite
struct AIUsageTests {
    let now = Date(timeIntervalSince1970: 1000)
    @Test(arguments: [(AIProvider.codex, "plus", AIUsagePeriod.session), (.codex, "pro", .weekly), (.codex, "prolite", .weekly), (.codex, "promax", .weekly), (.codex, "Pro 200", .weekly), (.claude, "pro", .session), (.claude, "default_claude_max_5x", .weekly), (.claude, "max_20x", .weekly), (.codex, "future", .session)])
    func automaticTier(pair: (AIProvider, String, AIUsagePeriod)) {
        let snapshot = AIUsageSnapshot(provider: pair.0, accountID: "fixture", plan: pair.1, windows: [], fetchedAt: self.now)
        #expect(snapshot.period(preference: .automatic) == pair.2)
        #expect(snapshot.period(preference: .session) == .session)
        #expect(snapshot.period(preference: .weekly) == .weekly)
    }
    @Test(arguments: [(-10.0, 100), (0, 100), (0.1, 99), (35.9, 64), (100, 0), (105, 0)])
    func clampsAndFloors(pair: (Double, Int)) {
        let snapshot = AIUsageSnapshot(provider: .codex, accountID: "fixture", plan: "plus", windows: [.init(period: .session, usedPercent: pair.0)], fetchedAt: self.now)
        #expect(snapshot.percentage(preference: .automatic, at: self.now) == pair.1)
    }
    @Test
    func unavailableStaleResetAndMissingWindow() {
        let snapshot = AIUsageSnapshot(provider: .codex, accountID: "fixture", plan: "pro", windows: [.init(period: .session, usedPercent: 25)], fetchedAt: self.now)
        #expect(snapshot.percentage(preference: .automatic, at: self.now) == nil)
        #expect(snapshot.percentage(preference: .session, at: self.now.addingTimeInterval(299)) == 75)
        #expect(snapshot.percentage(preference: .session, at: self.now.addingTimeInterval(300)) == nil)
        let reset = AIUsageSnapshot(provider: .claude, accountID: "fixture", plan: "pro", windows: [.init(period: .session, usedPercent: 0, resetsAt: self.now)], fetchedAt: self.now)
        #expect(reset.percentage(preference: .automatic, at: self.now) == nil)
        #expect(AIUsageWindow(period: .weekly, usedPercent: .nan).remainingPercent == nil)
    }
    @Test
    func codexDurationBucketAndLegacyCompatibility() throws {
        let account = Data(#"{"account":{"type":"chatgpt","planType":"plus","id":"fixture-account"}}"#.utf8)
        let limits = Data(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":12.2,"windowDurationMins":10080,"resetsAt":2000}},"other":{"primary":{"usedPercent":95,"windowDurationMins":300}}}}"#.utf8)
        let snapshot = try AIUsageDecoder.codex(account: account, limits: limits, now: self.now)
        #expect(snapshot.plan == "pro" && snapshot.accountID == "fixture-account")
        #expect(snapshot.window(.session) == nil && snapshot.window(.weekly)?.duration == 604800)
        #expect(snapshot.percentage(preference: .automatic, at: self.now) == 87)
        let old = try AIUsageDecoder.codex(account: account, limits: Data(#"{"rateLimits":{"primary":{"usedPercent":false},"secondary":{"usedPercent":15}}}"#.utf8), now: self.now)
        #expect(old.window(.session)?.remainingPercent == nil && old.window(.weekly)?.remainingPercent == 85)
        #expect(throws: AIUsageError.authentication) { try AIUsageDecoder.codex(account: Data(#"{"account":{"type":"apiKey"}}"#.utf8), limits: limits, now: self.now) }
    }
    @Test
    func claudePercentUnitsDatesAndLivePlan() throws {
        let snapshot = try AIUsageDecoder.claude(usage: Data(#"{"five_hour":{"utilization":35.5,"resets_at":"2026-10-05T13:00:00.125Z"},"seven_day":{"utilization":80,"resets_at":null}}"#.utf8), profile: Data(#"{"account":{"uuid":"account"},"organization":{"uuid":"org","rate_limit_tier":"default_claude_max_5x"}}"#.utf8), identity: "fixture", fallbackPlan: "pro", now: self.now)
        #expect(snapshot.accountID == "account:org")
        #expect(snapshot.percentage(preference: .automatic, at: self.now) == 20)
        #expect(snapshot.window(.session)?.remainingPercent == 64.5)
        #expect(snapshot.window(.session)?.resetsAt != nil)
        #expect(AIUsageDecoder.date("2026-10-05T13:00:00Z") != nil)
        #expect(throws: AIUsageError.invalidResponse) { try AIUsageDecoder.claude(usage: Data("{}".utf8), profile: nil, identity: "fixture", fallbackPlan: nil, now: self.now) }
    }
    @Test
    func credentialExpiryAndScope() throws {
        let valid = try ClaudeUsageCredential(data: Data(#"{"claudeAiOauth":{"accessToken":"fixture-only","expiresAt":2000000,"scopes":["user:profile"],"subscriptionType":"pro"}}"#.utf8))
        #expect(valid.isUsable(at: self.now))
        #expect(!valid.isUsable(at: Date(timeIntervalSince1970: 2000)))
        let inference = try ClaudeUsageCredential(data: Data(#"{"claudeAiOauth":{"accessToken":"fixture-only","scopes":["user:inference"]}}"#.utf8))
        #expect(!inference.isUsable(at: self.now))
        #expect(valid.identity != valid.accessToken)
    }
    @Test
    func incrementalActivityIgnoresChatChangesAndQuotaChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = AIUsageLocations(home: root, environment: [:])
        let codex = locations.codex.appendingPathComponent("sessions/session.jsonl"), claude = locations.claude.appendingPathComponent("projects/session.jsonl")
        let desktop = locations.claudeDesktop.appendingPathComponent("session/agent.jsonl")
        for file in [codex, claude, desktop] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data(#"{"type":"event_msg","timestamp":"2026-10-05T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#.utf8).write(to: codex)
        let scanner = AIUsageActivityScanner(locations: locations)
        let date = try #require(AIUsageDecoder.date("2026-10-05T15:00:00Z"))
        #expect(await scanner.scan(now: date) == nil) // Incomplete record.
        try self.append("\n", to: codex)
        #expect(await scanner.scan(now: date)?.provider == .codex)
        try self.append(#"{"type":"assistant","timestamp":"2026-10-05T11:00:00Z","message":{"role":"assistant","id":"request-1","usage":{"input_tokens":1,"output_tokens":2},"content":[{"text":"not decoded"}]}}"# + "\n", to: claude, create: true)
        #expect(await scanner.scan(now: date)?.provider == .claude)
        try self.append(#"{"type":"event_msg","timestamp":"2026-10-05T12:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"# + "\n", to: codex)
        try self.append(#"{"type":"session_meta","timestamp":"2026-10-05T12:00:00Z","title":"renamed"}"# + "\n", to: codex)
        #expect(await scanner.scan(now: date)?.provider == .claude)
        try self.append(#"{"type":"event_msg","timestamp":"2026-10-05T13:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":101}}}}"# + "\n", to: codex)
        #expect(await scanner.scan(now: date)?.provider == .codex)
        try self.append(#"{"type":"assistant","timestamp":"2026-10-05T14:00:00Z","message":{"role":"assistant","id":"desktop-1","usage":{"output_tokens":5}}}"# + "\n", to: desktop, create: true)
        #expect(await scanner.scan(now: date)?.provider == .claude)
        let restart = AIUsageActivityScanner(locations: locations)
        #expect(await restart.scan(now: date)?.date == AIUsageDecoder.date("2026-10-05T14:00:00Z"))
    }
    @Test
    func initialIndexFindsInferenceBeforeLongServiceTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageLong-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = AIUsageLocations(home: root, environment: [:])
        let file = locations.codex.appendingPathComponent("sessions/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = #"{"type":"event_msg","timestamp":"2026-10-05T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
        try (record + "\n" + #"{"type":"session_meta","text":""# + String(repeating: "x", count: 2 * 1024 * 1024) + #""}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
        let scanner = AIUsageActivityScanner(locations: locations)
        #expect(await scanner.scan(now: Date.distantFuture)?.provider == .codex)
        #expect(await scanner.scan(now: Date.distantFuture)?.date == AIUsageDecoder.date("2026-10-05T10:00:00Z"))
    }
    private func append(_ string: String, to file: URL, create: Bool = false) throws {
        if create { try Data().write(to: file) }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(string.utf8))
    }
}

@MainActor
private final class UsageRPCFixture: CodexUsageRPC {
    var methods: [String] = [], notifications: [String] = []
    var stopped = false
    var error: AIUsageError?
    func start(executable: String, home: URL) throws { }
    func request(method: String, params: Data?) async throws -> Data {
        self.methods.append(method)
        if let error { throw error }
        if method == "account/read" { return Data(#"{"account":{"type":"chatgpt","planType":"plus","id":"fixture"}}"#.utf8) }
        if method == "account/rateLimits/read" { return Data(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}"#.utf8) }
        return Data("{}".utf8)
    }
    func notify(method: String) throws { self.notifications.append(method) }
    func stop() { self.stopped = true }
}
@MainActor
private final class UsageCredentialFixture: ClaudeUsageCredentialReading {
    let values: [ClaudeUsageCredential]
    var reads = 0
    init(values: [ClaudeUsageCredential]) { self.values = values }
    func candidates(manual: Bool) throws -> [ClaudeUsageCredential] { self.reads += 1; return self.values }
}
@MainActor
private final class UsageHTTPFixture: AIUsageHTTPTransport {
    var status = 200
    var requests: [URLRequest] = []
    var retryAfter: String?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: self.status, httpVersion: nil, headerFields: self.retryAfter.map { ["Retry-After": $0] }))
        let body = request.url?.lastPathComponent == "profile" ? #"{"account":{"uuid":"fixture"},"organization":{"uuid":"org","rate_limit_tier":"pro"}}"# : #"{"five_hour":{"utilization":10},"seven_day":{"utilization":50}}"#
        return (Data(body.utf8), response)
    }
}
@Suite @MainActor
struct AIUsageAdapterTests {
    @Test
    func codexAccountOnlyHandshakeAndCleanup() async throws {
        let fixture = UsageRPCFixture(), root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexUsage-" + UUID().uuidString)
        let adapter = CodexUsageAdapter(executable: { "/fixture/codex" }, home: root, makeRPC: { fixture })
        let snapshot = try await adapter.fetch(manual: false).snapshot
        #expect(snapshot.window(.session)?.remainingPercent == 80)
        #expect(fixture.methods == ["initialize", "account/read", "account/rateLimits/read"])
        #expect(fixture.notifications == ["initialized"] && fixture.stopped)
        fixture.stopped = false; fixture.error = .timeout
        await #expect(throws: AIUsageError.timeout) { try await adapter.fetch(manual: false) }
        #expect(fixture.stopped)
    }
    @Test(arguments: [401, 403, 429])
    func claudeStatusAndRetryAfter(status: Int) async throws {
        let credential = try ClaudeUsageCredential(data: Data(#"{"claudeAiOauth":{"accessToken":"fixture-only"}}"#.utf8))
        let http = UsageHTTPFixture(); http.status = status; http.retryAfter = "600"
        let now = Date(timeIntervalSince1970: 1000)
        let adapter = ClaudeUsageAdapter(credentials: UsageCredentialFixture(values: [credential]), http: http, now: { now })
        let expected: AIUsageError = status == 429 ? .rateLimited(retryAt: now.addingTimeInterval(600)) : .authentication
        await #expect(throws: expected) { try await adapter.fetch(manual: false) }
        #expect(http.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "api.anthropic.com" })
    }
    @Test
    func claudeSuccessAndHTTPDate() async throws {
        let credential = try ClaudeUsageCredential(data: Data(#"{"claudeAiOauth":{"accessToken":"fixture-only","subscriptionType":"max"}}"#.utf8))
        let http = UsageHTTPFixture()
        let credentials = UsageCredentialFixture(values: [credential])
        let adapter = ClaudeUsageAdapter(credentials: credentials, http: http)
        for _ in 0 ..< 100 { _ = adapter.revision() }
        #expect(credentials.reads == 0)
        let snapshot = try await adapter.fetch(manual: false).snapshot
        #expect(snapshot.plan == "pro" && snapshot.accountID == "fixture:org")
        #expect(http.requests.count == 2 && credentials.reads == 1)
        for _ in 0 ..< 100 { _ = adapter.revision() }
        #expect(credentials.reads == 1)
        #expect(ClaudeUsageAdapter.retryDate("Mon, 05 Oct 2026 13:00:00 GMT", now: Date()) != nil)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct AIUsageNativeRPCTests {
    @Test(arguments: ["valid", "timeout", "rateLimit", "invalid"])
    func supervisedJSONLinesFixture(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageRPC-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture")
        let script = """
        #!/usr/bin/python3
        # Created by Василий Маслов on 05.10.2026.
        import json,sys,time
        mode = 'MODE'
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            if mode == 'timeout':
                time.sleep(60)
                continue
            if mode == 'invalid':
                sys.stdout.write('invalid-json\\n');sys.stdout.flush()
                continue
            response = {'id':request['id'],'result':{'ok':True}}
            if mode == 'rateLimit': response = {'id':request['id'],'error':{'code':429,'message':'fixture quota'}}
            payload = json.dumps(response)+'\\n'
            sys.stdout.write(payload[:4]);sys.stdout.flush()
            time.sleep(0.005)
            sys.stdout.write(payload[4:]);sys.stdout.flush()
        """.replacingOccurrences(of: "MODE", with: mode)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let rpc = NativeCodexUsageRPC(timeout: mode == "timeout" ? 0.2 : 3)
        try rpc.start(executable: executable.path, home: root)
        defer { rpc.stop() }
        switch mode {
        case "valid":
            let data = try await rpc.request(method: "account/read", params: nil)
            #expect(try AIUsageDecoder.object(data)["ok"] as? Bool == true)
            try rpc.notify(method: "initialized")
        case "rateLimit": await #expect(throws: AIUsageError.rateLimited(retryAt: nil)) { try await rpc.request(method: "account/read", params: nil) }
        case "invalid": await #expect(throws: AIUsageError.invalidResponse) { try await rpc.request(method: "account/read", params: nil) }
        default: await #expect(throws: AIUsageError.timeout) { try await rpc.request(method: "account/read", params: nil) }
        }
    }

    /// Explicit opt-in probe reads the existing account only; it cannot start inference.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_USAGE_LIVE_CODEX"] == "1"))
    func installedCodexAccountOnlyProbe() async throws {
        let executable = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        let adapter = CodexUsageAdapter(executable: { executable })
        var snapshot: AIUsageSnapshot?
        // Codex may rotate its own token during the first probe, invalidating that generation.
        for _ in 0 ..< 2 {
            do { snapshot = try await adapter.fetch(manual: false).snapshot; break }
            catch AIUsageError.accountChanged { continue }
        }
        let result = try #require(snapshot)
        #expect(result.provider == .codex && !result.windows.isEmpty)
    }
}
