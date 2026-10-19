// Created by Василий Маслов on 13.10.2026.
import Foundation
import Security
import LocalAuthentication
import MCP
import MimicCore

/// Credentials have an endpoint-derived namespace and are never encoded in presentation values.
final class AtlassianKeychain: TokenStorage, @unchecked Sendable {
    let namespace: String
    private let lock = NSLock()
    private var oauth: OAuthAccessToken?
    private var persistenceFailed = false
    init(namespace: String) { self.namespace = namespace }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.vmaslov.Mimic.atlassian", kSecAttrAccount as String: namespace + ":" + account]
    }
    func data(_ account: String) throws -> Data {
        let context = LAContext(); context.interactionNotAllowed = true
        var q = query(account); q[kSecUseAuthenticationContext as String] = context; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw AtlassianError.accessRequired }
        guard status == errSecSuccess, let data = result as? Data else { throw AtlassianError.authenticationRequired }; return data
    }
    func write(_ data: Data, account: String) throws {
        let q = query(account); let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data; item[kSecAttrLabel as String] = "Mimic · Atlassian"; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AtlassianError.accessRequired }
        } else if status != errSecSuccess { throw AtlassianError.accessRequired }
    }
    func remove(_ account: String) { _ = SecItemDelete(query(account) as CFDictionary) }
    func save(_ token: OAuthAccessToken) {
        do { try write(JSONEncoder().encode(token), account: "oauth"); lock.withLock { oauth = token; persistenceFailed = false } }
        catch { lock.withLock { persistenceFailed = true } }
    }
    func verifyPersistence() throws { if lock.withLock({ persistenceFailed }) { throw AtlassianError.accessRequired } }
    func load() -> OAuthAccessToken? {
        if let cached = lock.withLock({ oauth }) { return cached }
        guard let data = try? data("oauth"), let token = try? JSONDecoder().decode(OAuthAccessToken.self, from: data) else { return nil }
        lock.withLock { oauth = token }; return token
    }
    func clear() { lock.withLock { oauth = nil; persistenceFailed = false }; remove("oauth") }
}

struct AtlassianCookie: Codable {
    var name: String; var value: String; var domain: String; var path: String
    var expires: Date?; var secure: Bool; var httpOnly: Bool
    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path; expires = cookie.expiresDate; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
    }
    func applies(to url: URL, date: Date = Date()) -> Bool {
        domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == url.host?.lowercased()
            && (expires == nil || expires! > date) && (!secure || url.scheme == "https")
            && (url.path == path || url.path.hasPrefix(path.hasSuffix("/") ? path : path + "/"))
    }
}

// MARK: - REST sessions

extension AtlassianKeychain {
    /// Both verified services are replaced by one Keychain update, so cancelling the second login preserves the previous pair.
    func writeRESTSessions(_ sessions: [String: Data]) throws {
        try write(JSONEncoder().encode(sessions), account: "restSessions")
    }
    /// Header material is constructed only in the native process and for an exact API origin.
    func restHeaders(_ preset: AtlassianPreset) throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        let sessions: [String: Data]?
        do { sessions = try JSONDecoder().decode([String: Data].self, from: data("restSessions")) }
        catch AtlassianError.authenticationRequired { sessions = nil } // Previously saved per-service sessions remain readable.
        func session(_ service: String) throws -> Data {
            if let sessions { guard let value = sessions[service] else { throw AtlassianError.authenticationRequired }; return value }
            return try data(service)
        }
        for (service, base) in [("jira", preset.jiraURL), ("confluence", preset.confluenceURL)] {
            guard let base, let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/rest/api/") else { continue }
            if preset.authentication == .personalAccessToken {
                guard let token = String(data: try session(service), encoding: .utf8), !token.isEmpty else { throw AtlassianError.authenticationRequired }
                result[service] = ["Authorization": "Bearer " + token]
            } else {
                let cookies = try JSONDecoder().decode([AtlassianCookie].self, from: session(service)).filter { $0.applies(to: url) }
                guard !cookies.isEmpty else { throw AtlassianError.authenticationRequired }
                result[service] = ["Cookie": cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")]
            }
        }
        return result
    }
}
