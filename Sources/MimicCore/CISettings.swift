//
//  CISettings.swift
//  MimicCore
//
//  Created by Василий Маслов on 02.10.2026.
import Combine
import Foundation
import Security
import LocalAuthentication

/// Credentials are kept outside configuration/history and never exposed as a stored UI value.
@MainActor
public protocol CICredentialStore {
    func token(for id: UUID, interaction: CICredentialInteraction) throws -> String
    func save(_ token: String, for id: UUID) throws
    func remove(_ id: UUID) throws
}

@MainActor
public struct KeychainCICredentialStore: CICredentialStore {
    private let service: String
    public init(service: String = "local.vmaslov.Mimic.gitlab") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: self.service, kSecAttrAccount as String: id.uuidString]
    }

    public func token(for id: UUID, interaction: CICredentialInteraction = .silent) throws -> String {
        let context = LAContext(); context.interactionNotAllowed = interaction == .silent
        var query = query(id); query[kSecUseAuthenticationContext as String] = context; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecInteractionNotAllowed, errSecAuthFailed: throw CICredentialAccessError.accessRequired
        case errSecUserCanceled: throw CICredentialAccessError.cancelled
        case errSecItemNotFound: throw CICredentialAccessError.missing
        default: throw CICredentialAccessError.unavailable
        }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw CICredentialAccessError.missing }
        return token
    }

    public func save(_ token: String, for id: UUID) throws {
        let query = query(id), data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = self.service.hasSuffix(".jenkins") ? "Mimic · Jenkins" : "Mimic · GitLab"
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CIError.credential }
        } else if status != errSecSuccess { throw CIError.credential }
    }

    public func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CIError.credential }
    }
}

/// Multiple checkouts may share a connection; the mapping contains only UUID references.
public struct CIConfiguration: Codable, Sendable {
    public var connections: [GitLabConnection] = []
    public var checkouts: [String: UUID] = [:]
    public init() { }
    public func connection(for path: String) -> GitLabConnection? {
        self.connections.first { $0.id == self.checkouts[path] }
    }
}

@MainActor
public protocol CIConfigurationStore {
    func load() -> CIConfiguration
    func save(_ value: CIConfiguration)
}

@MainActor
public struct DefaultsCIConfigurationStore: CIConfigurationStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> CIConfiguration {
        guard let data = defaults.data(forKey: "gitLabConnections") else { return CIConfiguration() }
        return (try? JSONDecoder().decode(CIConfiguration.self, from: data)) ?? CIConfiguration()
    }

    public func save(_ value: CIConfiguration) {
        if let data = try? JSONEncoder().encode(value) { self.defaults.set(data, forKey: "gitLabConnections") }
    }
}

/// A saved connection must first be verified; switching checkout invalidates an in-flight check.
@MainActor
public final class CISettingsModel: ObservableObject {
    @Published
    public var address = "" { didSet { if self.address != oldValue { self.invalidate() } } }
    @Published
    public var projectPath = "" { didSet { if self.projectPath != oldValue { self.invalidate() } } }
    @Published
    public var enteredToken = "" { didSet { if self.enteredToken != oldValue { self.invalidate() } } }
    @Published
    public private(set) var checking = false
    @Published
    public private(set) var verified = false
    @Published
    public private(set) var error: CIError?
    @Published
    public private(set) var connection: GitLabConnection?
    @Published public private(set) var user: CIUser?
    public var onConnectionChange: (() -> Void)?
    public let credentialSession: CICredentialSession
    public var authenticatedClient: GitLabClient { GitLabClient(transport: CredentialCIHTTPTransport(session: self.credentialSession)) }
    private let store: any CIConfigurationStore
    public let client: any GitLabService
    private var configuration: CIConfiguration
    private var checkout = ""
    private var revision = UUID()
    private var checkTask: Task<Void, Never>?
    private var checkedConnection: GitLabConnection?
    private var checkedUser: CIUser?
    private var checkedToken = ""

    public init(credentials: any CICredentialStore = KeychainCICredentialStore(), store: any CIConfigurationStore = DefaultsCIConfigurationStore(), client: (any GitLabService)? = nil) {
        let session = CICredentialSession(store: credentials)
        self.credentialSession = session; self.store = store; self.client = client ?? GitLabClient(transport: CredentialCIHTTPTransport(session: session)); self.configuration = store.load()
    }

    public func selectCheckout(_ path: String) {
        guard self.checkout != path else { return }
        self.invalidate(); self.user = nil; self.checkout = path; self.connection = self.configuration.connection(for: path)
        self.address = self.connection?.baseURL.absoluteString ?? ""
        self.projectPath = self.connection?.projectPath ?? ""; self.enteredToken = ""
    }

    public func invalidate() {
        self.revision = UUID(); self.checkTask?.cancel(); self.checkTask = nil
        self.checking = false; self.verified = false; self.checkedConnection = nil; self.checkedUser = nil; self.checkedToken = ""; self.error = nil
    }

    /// Reads a checkout-scoped connection without changing the native settings form.
    public func connection(forCheckout path: String, services: ProfileServices? = nil) -> GitLabConnection? {
        let configuration = store.load()
        if let connection = configuration.connection(for: path) { return connection }
        guard let services else { return nil }
        return configuration.connections.first { $0.baseURL.absoluteString == services.gitLabURL && $0.projectPath == services.gitLabProject }
    }

    public func token(for connection: GitLabConnection) throws -> String { try self.credentialSession.token(for: connection.id) }

    public func requestCredentialAccess(connection requested: GitLabConnection? = nil) async {
        guard let connection = requested ?? self.connection, await self.credentialSession.requestAccess(for: connection.id) else { return }
        self.user = nil; self.invalidate(); self.onConnectionChange?()
    }

    public func check() {
        guard !self.checking, !self.checkout.isEmpty else { return }
        self.invalidate()
        let revision = revision
        do {
            let base = try GitLabClient.baseURL(self.address)
            let path = self.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
            // Each checkout gets its own reference on Save; another checkout's token is never replaced.
            if self.enteredToken.isEmpty, self.connection?.baseURL != base { throw CIError.invalidConfiguration }
            let shared = self.connection.map { existing in self.configuration.checkouts.contains { $0.key != self.checkout && $0.value == existing.id } } ?? false
            let id = shared ? UUID() : self.connection?.id ?? UUID()
            let token: String
            if self.enteredToken.isEmpty, let existing = connection { token = try self.credentialSession.token(for: existing.id) }
            else { token = self.enteredToken }
            guard !token.isEmpty else { throw CIError.invalidConfiguration }
            let credentialID = self.enteredToken.isEmpty ? self.connection?.id : nil
            self.checking = true
            self.checkTask = Task { [weak self, client] in
                do {
                    let project = try await CICredentialRequestContext.$connectionID.withValue(credentialID) { try await client.project(baseURL: base, path: path, token: token) }
                    guard let self, self.revision == revision, !Task.isCancelled else { return }
                    let connection = GitLabConnection(id: id, baseURL: base, projectID: project.id, projectPath: project.pathWithNamespace)
                    let user = try await client.currentUser(connection: connection, token: token)
                    guard self.revision == revision, !Task.isCancelled else { return }
                    self.checkedConnection = connection; self.checkedUser = user
                    self.checkedToken = token; self.checking = false; self.verified = true; self.checkTask = nil
                } catch {
                    guard let self, self.revision == revision, !Task.isCancelled else { return }
                    self.checking = false; self.error = error as? CIError ?? .network; self.checkTask = nil
                }
            }
        } catch { self.error = error as? CIError ?? .invalidConfiguration }
    }

    public func save() {
        guard self.verified, let checkedConnection, !checkout.isEmpty else { return }
        do {
            try self.credentialSession.save(self.checkedToken, for: checkedConnection.id)
            self.configuration.connections.removeAll { $0.id == checkedConnection.id }
            self.configuration.connections.append(checkedConnection); self.configuration.checkouts[self.checkout] = checkedConnection.id
            self.store.save(self.configuration); self.connection = checkedConnection; self.user = self.checkedUser
            self.address = checkedConnection.baseURL.absoluteString; self.projectPath = checkedConnection.projectPath
            self.enteredToken = ""; self.invalidate(); self.onConnectionChange?()
        } catch { self.error = .credential }
    }

    public func disconnect() {
        guard let connection else { return }
        do {
            let shared = self.configuration.checkouts.contains { $0.key != self.checkout && $0.value == connection.id }
            if !shared { try self.credentialSession.remove(connection.id); self.configuration.connections.removeAll { $0.id == connection.id } }
            self.credentialSession.forget(connection.id)
            self.configuration.checkouts.removeValue(forKey: self.checkout); self.store.save(self.configuration)
            self.invalidate(); self.connection = nil; self.user = nil; self.enteredToken = ""; self.onConnectionChange?()
        } catch { self.error = .credential }
    }
}
