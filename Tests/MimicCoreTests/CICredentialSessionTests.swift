// Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
@testable import MimicCore

@MainActor private final class SessionStore: CICredentialStore {
    var reads: [(UUID, CICredentialInteraction)] = []
    var values: [UUID: String] = [:]
    var failure: CICredentialAccessError?
    var failSave = false
    func token(for id: UUID, interaction: CICredentialInteraction) throws -> String {
        self.reads.append((id, interaction))
        if let failure { throw failure }
        guard let value = self.values[id] else { throw CICredentialAccessError.missing }
        return value
    }
    func save(_ token: String, for id: UUID) throws {
        if self.failSave { throw CICredentialAccessError.unavailable }
        self.values[id] = token
    }
    func remove(_ id: UUID) throws { self.values[id] = nil }
}
private actor DelayedCredentialHTTP: CIHTTPTransport {
    var pending: CheckedContinuation<CIHTTPResponse, Never>?
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        await withCheckedContinuation { self.pending = $0 }
    }
    func ready() -> Bool { self.pending != nil }
    func finish(_ status: Int) { self.pending?.resume(returning: CIHTTPResponse(data: Data(), status: status)); self.pending = nil }
}

private actor QueueAccessHTTP: CIHTTPTransport {
    var requests: [String] = []
    var hold = false
    var continuation: CheckedContinuation<CIHTTPResponse, Never>?
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        self.requests.append(request.httpMethod ?? "")
        if self.hold { return await withCheckedContinuation { self.continuation = $0 } }
        return CIHTTPResponse(data: Data(#"{"why":"Waiting for executor"}"#.utf8), status: 200)
    }
    func suspendNext() { self.hold = true }
    func waiting() -> Bool { self.continuation != nil }
    func finish() { self.continuation?.resume(returning: CIHTTPResponse(data: Data(#"{"why":"Late"}"#.utf8), status: 200)); self.continuation = nil }
}

@MainActor struct CICredentialSessionTests {
    @Test func sharedCacheStickyFailureAndIsolation() throws {
        let store = SessionStore(), id = UUID(), other = UUID()
        store.values = [id: "fixture", other: "second"]
        let session = CICredentialSession(store: store)
        for _ in 0 ..< 20 { #expect(try session.token(for: id) == "fixture") }
        #expect(store.reads.count == 1 && store.reads.first?.1 == .silent)
        #expect(try session.token(for: other) == "second" && store.reads.count == 2)
        let anotherService = CICredentialSession(store: store)
        #expect(try anotherService.token(for: id) == "fixture" && store.reads.count == 3)
        session.forget(id); store.failure = .accessRequired
        for _ in 0 ..< 20 { #expect(throws: CIError.credential) { try session.token(for: id) } }
        #expect(store.reads.count == 4 && session.failures[id] == .accessRequired)
        #expect(try session.token(for: other) == "second")
    }

    @Test func explicitGrantsCoalesceAndCancellationRequiresAnotherAction() async throws {
        let store = SessionStore(), id = UUID(), session = CICredentialSession(store: store)
        store.failure = .cancelled
        async let first = session.requestAccess(for: id)
        async let second = session.requestAccess(for: id)
        let results = await (first, second)
        #expect(!results.0 && !results.1 && store.reads.count == 1)
        #expect(session.failures[id] == .cancelled && session.granting.isEmpty)
        #expect(throws: CIError.credential) { try session.token(for: id) }
        #expect(store.reads.count == 1)
        store.failure = nil; store.values[id] = "restored"
        #expect(await session.requestAccess(for: id))
        #expect(try session.token(for: id) == "restored" && store.reads.count == 2)
        #expect(store.reads.allSatisfy { $0.1 == .userInitiated })
    }

    @Test func saveDisconnectAndLateHTTPFailuresRespectGeneration() async throws {
        let store = SessionStore(), id = UUID(), session = CICredentialSession(store: store)
        try session.save("old-fixture", for: id)
        let isolated = UUID(); try session.save("old-fixture", for: isolated)
        let http = DelayedCredentialHTTP(), transport = CredentialCIHTTPTransport(session: session, base: http)
        var request = URLRequest(url: URL(string: "https://fixture.invalid/api/v4/user")!)
        request.setValue("old-fixture", forHTTPHeaderField: "PRIVATE-TOKEN")
        let oldRequest = Task { try await CICredentialRequestContext.$connectionID.withValue(id) { try await transport.send(request) } }
        while !(await http.ready()) { await Task.yield() }
        try session.save("new-fixture", for: id)
        await http.finish(401); _ = try await oldRequest.value
        #expect(try session.token(for: id) == "new-fixture" && session.failures[id] == nil)
        #expect(try session.token(for: isolated) == "old-fixture")
        let leases = session.leases(matching: "new-fixture")
        session.reject(leases)
        #expect(session.failures[id] == .rejected)
        #expect(throws: CIError.credential) { try session.token(for: id) }
        try session.save("third-fixture", for: id); store.failSave = true
        #expect(throws: CICredentialAccessError.unavailable) { try session.save("failed-fixture", for: id) }
        #expect(try session.token(for: id) == "third-fixture")
        try session.remove(id)
        #expect(throws: CIError.credential) { try session.token(for: id) }
        #expect(session.failures[id] == .missing)
    }

    @Test func forbiddenDoesNotRereadOrRevokeToken() async throws {
        let store = SessionStore(), id = UUID(), session = CICredentialSession(store: store)
        try session.save("fixture", for: id)
        let http = DelayedCredentialHTTP(), transport = CredentialCIHTTPTransport(session: session, base: http)
        var request = URLRequest(url: URL(string: "https://fixture.invalid")!); request.setValue("fixture", forHTTPHeaderField: "PRIVATE-TOKEN")
        let operation = Task { try await CICredentialRequestContext.$connectionID.withValue(id) { try await transport.send(request) } }
        while !(await http.ready()) { await Task.yield() }
        await http.finish(403); _ = try await operation.value
        #expect(try session.token(for: id) == "fixture" && store.reads.isEmpty && session.failures.isEmpty)
    }
    @Test func restoredAccessResumesGETOnlyAndDiscardsOldWatcherResponses() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/CICredentialRemote-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = JenkinsConnection(baseURL: URL(string: "https://fixture.invalid")!, username: "fixture")
        let gitlab = GitLabConnection(baseURL: URL(string: "https://gitlab.invalid")!, projectID: 1, projectPath: "fixture")
        var run = RemoteTestRun(requestID: UUID(), checkout: ProjectContext(path: "/fixture"), branch: "main", plan: .smoke, jenkins: connection, gitlab: gitlab)
        run.status = "queued"; run.queueURL = URL(string: "https://fixture.invalid/queue/item/7/")
        var runs = [run]
        for status in ["unknown", "unlinked", "submissionFailed"] {
            var terminal = RemoteTestRun(requestID: UUID(), checkout: run.checkout, branch: "main", plan: .smoke, jenkins: connection, gitlab: gitlab)
            terminal.status = status; runs.append(terminal)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(runs).write(to: directory.appendingPathComponent("remote-runs.json"))
        let store = SessionStore(), session = CICredentialSession(store: store), http = QueueAccessHTTP()
        store.values[connection.id] = "fixture"; store.failure = .accessRequired
        let owner = RemoteTestCoordinator(directory: directory, jenkins: JenkinsClient(transport: CredentialCIHTTPTransport(session: session, base: http)), jenkinsToken: { try session.token(for: $0.id) }, gitlabToken: { _ in "fixture" })
        defer { owner.stop() }
        owner.resume()
        for _ in 0 ..< 200 { if owner.runs.first?.error == "ci.error.credential" { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await http.requests.isEmpty && store.reads.count == 1)
        store.failure = nil; #expect(await session.requestAccess(for: connection.id))
        owner.credentialsChanged()
        for _ in 0 ..< 200 { if owner.runs.first?.error == nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await http.requests == ["GET"] && store.reads.count == 2)
        #expect(owner.runs.dropFirst().map(\.status) == ["unknown", "unlinked", "submissionFailed"])
        owner.stop(); await http.suspendNext()
        let old = Task { try await owner.refreshOnce(run.id) }
        while !(await http.waiting()) { await Task.yield() }
        owner.stop(); await http.finish()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(owner.runs.first?.status == "queued")
        #expect(await http.requests.allSatisfy { $0 == "GET" })
    }

}
