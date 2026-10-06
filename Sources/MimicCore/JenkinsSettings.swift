//
//  JenkinsSettings.swift
//  MimicCore
//
//  Created by Василий Маслов on 04.10.2026.
import Combine
import Foundation

/// Native-only personal credentials; the web panel and MCP see only a configured flag.
@MainActor public final class JenkinsSettings: ObservableObject {
    /// The native form and verification use the same fixed Apple endpoint.
    @Published public var address = "" { didSet { self.invalidate() } }
    @Published public var username = "" { didSet { self.invalidate() } }
    @Published public var enteredToken = "" { didSet { self.invalidate() } }
    @Published public private(set) var connection: JenkinsConnection?
    @Published public private(set) var checking = false
    @Published public private(set) var verified = false
    @Published public private(set) var error: JenkinsConnectionError?
    public var onChange: (() -> Void)?
    private let defaults: UserDefaults
    public let credentialSession: CICredentialSession
    public var authenticatedClient: JenkinsClient { JenkinsClient(transport: CredentialCIHTTPTransport(session: self.credentialSession)) }
    public let client: JenkinsClient
    private var revision = UUID()
    private var checked: JenkinsConnection?
    private var checkedToken = ""
    public init(defaults: UserDefaults = .standard, credentials: any CICredentialStore = KeychainCICredentialStore(service: "local.vmaslov.Mimic.jenkins"), client: JenkinsClient? = nil) {
        let session = CICredentialSession(store: credentials)
        self.defaults = defaults; self.credentialSession = session; self.client = client ?? JenkinsClient(transport: CredentialCIHTTPTransport(session: session))
        if let data = defaults.data(forKey: "jenkinsConnection"), let connection = try? JSONDecoder().decode(JenkinsConnection.self, from: data) {
            self.connection = connection; self.username = connection.username; self.address = connection.baseURL.absoluteString
        }
    }
    private func invalidate() { self.revision = UUID(); self.verified = false; self.checking = false; self.checked = nil; self.checkedToken = ""; self.error = nil }
    public func token(for connection: JenkinsConnection) throws -> String { try self.credentialSession.token(for: connection.id) }
    public func requestCredentialAccess() async {
        guard let connection, await self.credentialSession.requestAccess(for: connection.id), self.connection == connection else { return }
        self.invalidate(); self.onChange?()
    }
    public func check() {
        self.invalidate()
        let revision = self.revision
        do {
            let username = self.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { throw CIError.invalidConfiguration }
            guard let baseURL = URL(string: self.address), baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil else { throw CIError.invalidConfiguration }
            let connection = JenkinsConnection(id: self.connection?.id ?? UUID(), baseURL: baseURL, username: username)
            let enteredToken = self.enteredToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = enteredToken.isEmpty ? try self.token(for: connection) : enteredToken
            self.checking = true
            Task {
                do {
                    try await self.client.checkAccount(connection: connection, token: token)
                    guard self.revision == revision else { return }
                    self.checked = connection; self.checkedToken = token; self.verified = true; self.checking = false
                } catch {
                    guard self.revision == revision else { return }
                    self.checking = false; self.error = error as? JenkinsConnectionError ?? .transport(error as? CIError ?? .network)
                }
            }
        } catch { self.error = .transport(error as? CIError ?? .credential) }
    }
    public func save() {
        guard self.verified, let connection = self.checked else { return }
        do {
            try self.credentialSession.save(self.checkedToken, for: connection.id)
            self.defaults.set(try JSONEncoder().encode(connection), forKey: "jenkinsConnection")
            self.connection = connection; self.enteredToken = ""; self.onChange?()
        } catch { self.error = .transport(.credential) }
    }
    public func disconnect() {
        do { if let connection = self.connection { try self.credentialSession.remove(connection.id) } }
        catch { self.error = .transport(.credential); return }
        self.connection = nil; self.defaults.removeObject(forKey: "jenkinsConnection"); self.enteredToken = ""; self.onChange?()
    }
}
