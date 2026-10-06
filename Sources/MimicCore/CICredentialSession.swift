//
//  CICredentialSession.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Combine
import Foundation

/// Only an explicit native access action may permit a Keychain dialog.
public enum CICredentialInteraction: Sendable { case silent, userInitiated }

public enum CICredentialAccessError: Error, Equatable, Sendable {
    case accessRequired, cancelled, missing, unavailable, rejected
    public var localizationKey: String {
        switch self {
        case .accessRequired: "credentials.required"
        case .cancelled: "credentials.cancelled"
        case .missing: "credentials.missing"
        case .unavailable: "credentials.unavailable"
        case .rejected: "credentials.rejected"
        }
    }
}

/// One service-owned cache survives panel/branch changes. Neither tokens nor leases are persisted.
@MainActor public final class CICredentialSession: ObservableObject {
    @Published public private(set) var failures: [UUID: CICredentialAccessError] = [:]
    @Published public private(set) var granting: Set<UUID> = []
    private struct Cached { let token: String; let generation: UUID }
    struct Lease: Sendable { let id: UUID; let generation: UUID }
    private let store: any CICredentialStore
    private var cached: [UUID: Cached] = [:]
    private var grants: [UUID: Task<Bool, Never>] = [:]

    public init(store: any CICredentialStore) { self.store = store }

    // MARK: - Cached and explicit access

    public func token(for id: UUID) throws -> String {
        if let value = self.cached[id] { return value.token }
        guard self.failures[id] == nil else { throw CIError.credential }
        return try self.read(id, interaction: .silent)
    }

    /// Concurrent native actions share one prompt; cancellation stays blocked until another action.
    public func requestAccess(for id: UUID) async -> Bool {
        if let task = self.grants[id] { return await task.value }
        self.granting.insert(id)
        let task = Task { @MainActor in
            do { _ = try self.read(id, interaction: .userInitiated); return true }
            catch { return false }
        }
        self.grants[id] = task
        let result = await task.value
        self.grants[id] = nil; self.granting.remove(id)
        return result
    }

    public func save(_ token: String, for id: UUID) throws {
        try self.store.save(token, for: id)
        self.cached[id] = Cached(token: token, generation: UUID()); self.failures[id] = nil
    }

    public func remove(_ id: UUID) throws { try self.store.remove(id); self.forget(id) }
    public func forget(_ id: UUID) { self.cached[id] = nil; self.failures[id] = nil }

    // MARK: - Request generations

    func leases(matching token: String, connectionID: UUID? = nil) -> [Lease] {
        self.cached.compactMap { id, value in value.token == token && (connectionID == nil || connectionID == id) ? Lease(id: id, generation: value.generation) : nil }
    }

    /// A late authorization failure cannot revoke credentials saved after this request started.
    func reject(_ leases: [Lease]) {
        for lease in leases where self.cached[lease.id]?.generation == lease.generation {
            self.cached[lease.id] = nil; self.failures[lease.id] = .rejected
        }
    }

    private func read(_ id: UUID, interaction: CICredentialInteraction) throws -> String {
        do {
            let token = try self.store.token(for: id, interaction: interaction)
            guard !token.isEmpty else { throw CICredentialAccessError.missing }
            self.cached[id] = Cached(token: token, generation: UUID()); self.failures[id] = nil
            return token
        } catch {
            self.cached[id] = nil
            self.failures[id] = error as? CICredentialAccessError ?? .unavailable
            throw CIError.credential
        }
    }
}

/// Task-local connection identity does not alter HTTP headers, URLs or public wire contracts.
enum CICredentialRequestContext {
    @TaskLocal static var connectionID: UUID?
}

/// Captures the credential generation before HTTP suspension and observes only authentication failures.
public struct CredentialCIHTTPTransport: CIHTTPTransport {
    private let base: any CIHTTPTransport
    private let session: CICredentialSession
    public init(session: CICredentialSession, base: any CIHTTPTransport = URLSessionCITransport()) {
        self.session = session; self.base = base
    }
    public func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        let token: String?
        if let value = request.value(forHTTPHeaderField: "PRIVATE-TOKEN") { token = value }
        else if let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Basic "),
                let data = Data(base64Encoded: String(header.dropFirst(6))), let value = String(data: data, encoding: .utf8),
                let colon = value.firstIndex(of: ":") { token = String(value[value.index(after: colon)...]) }
        else { token = nil }
        let leases: [CICredentialSession.Lease] = if let id = CICredentialRequestContext.connectionID { await self.session.leases(matching: token ?? "", connectionID: id) } else { [] }
        let response = try await self.base.send(request)
        if response.status == 401 || ((300 ... 399).contains(response.status) && !(request.httpMethod == "POST" && response.status == 303)) {
            await self.session.reject(leases)
        }
        return response
    }
}
