//
//  ClaudeDesktopUsageCredentials.swift
//  MimicCore
//
//  Created by Василий Маслов on 12.10.2026.
// Electron decryption and cache selection adapted from OpenUsage (MIT).
import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SQLite3

/// Borrows only a valid access token from Desktop. Its refresh token and storage remain externally owned.
@MainActor
struct ClaudeDesktopUsageCredentials {
    private let directory: URL
    private let password: @MainActor (Bool) throws -> Data?
    private let now: () -> Date

    init(directory: URL, password: @escaping @MainActor (Bool) throws -> Data? = ClaudeDesktopUsageCredentials.readPassword, now: @escaping () -> Date = Date.init) {
        self.directory = directory; self.password = password; self.now = now
    }

    // MARK: - Current Desktop login

    func read(manual: Bool) throws -> ClaudeUsageCredential? {
        guard let root = self.root(), root["oauth:tokenCacheV2"] is String || root["oauth:tokenCache"] is String,
              let cookie = self.organizationCookie() else { return nil }
        guard let password = try self.password(manual) else { return nil }
        let key = try Self.deriveKey(password)
        let organization: Data
        if cookie.plain.isEmpty {
            let decoded = try Self.decrypt(cookie.encrypted, key: key)
            let hostHash = Data(SHA256.hash(data: Data(cookie.host.utf8)))
            guard decoded.starts(with: hostHash) else { throw AIUsageError.authentication }
            organization = decoded.dropFirst(hostHash.count)
        } else { organization = cookie.plain }
        guard let org = String(data: organization, encoding: .utf8)?.lowercased(), UUID(uuidString: org) != nil else { throw AIUsageError.authentication }
        let account = (root["lastKnownAccountUuid"] as? String).flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        let v2 = try Self.decodeCache(root["oauth:tokenCacheV2"], key: key)
        let v1 = try Self.decodeCache(root["oauth:tokenCache"], key: key)
        return try Self.select(v2: v2, v1: v1, account: account, organization: org, generation: Self.generation(root: root, cookie: cookie), now: self.now())
    }

    /// Rejects a late response after Desktop switches accounts or organizations, without another Keychain read.
    func isCurrent(_ credential: ClaudeUsageCredential) -> Bool {
        guard let generation = credential.desktopGeneration else { return true }
        guard let root = self.root(), let cookie = self.organizationCookie() else { return false }
        return Self.generation(root: root, cookie: cookie) == generation
    }

    private func root() -> [String: Any]? {
        let url = self.directory.appendingPathComponent("config.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? AIUsageDecoder.object(data)
    }

    private struct OrganizationCookie {
        let host: String
        let plain: Data
        let encrypted: Data
    }

    /// Reads only lastActiveOrg through a read-only SQLite handle; cookies never enter diagnostics.
    private func organizationCookie() -> OrganizationCookie? {
        for path in ["Cookies", "Network/Cookies"] {
            var database: OpaquePointer?
            let status = sqlite3_open_v2(self.directory.appendingPathComponent(path).path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            defer { sqlite3_close(database) }
            guard status == SQLITE_OK else { continue }
            sqlite3_busy_timeout(database, 200)
            var statement: OpaquePointer?
            let sql = "SELECT host_key, value, encrypted_value FROM cookies WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai') ORDER BY last_update_utc DESC LIMIT 1"
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
                  let host = sqlite3_column_text(statement, 0) else { continue }
            func bytes(_ column: Int32) -> Data {
                let count = Int(sqlite3_column_bytes(statement, column))
                guard count > 0, count <= 4096, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
                return Data(bytes: pointer, count: count)
            }
            return OrganizationCookie(host: String(cString: host), plain: bytes(1), encrypted: bytes(2))
        }
        return nil
    }

    private static func generation(root: [String: Any], cookie: OrganizationCookie) -> String {
        var data = Data((root["lastKnownAccountUuid"] as? String ?? "").lowercased().utf8)
        data.append(0); data.append(contentsOf: cookie.host.utf8); data.append(0)
        data.append(cookie.plain); data.append(0); data.append(cookie.encrypted)
        return usageDigest(data)
    }

    // MARK: - Account-scoped token caches

    /// V2 entries and account-scoped tombstones supersede older aliases; foreign accounts are excluded.
    static func select(v2: [String: Any]?, v1: [String: Any]?, account: String?, organization: String, generation: String, now: Date) throws -> ClaudeUsageCredential? {
        func normalized(_ cache: [String: Any]?) -> [String: Any] {
            var legacy: [String: Any] = [:], scoped: [String: Any] = [:]
            for (raw, value) in (cache ?? [:]).sorted(by: { $0.key < $1.key }) {
                var key = raw
                if raw.hasPrefix("acct:") {
                    guard let separator = raw.firstIndex(of: "|"),
                          let owner = UUID(uuidString: String(raw.dropFirst(5).prefix(upTo: separator))),
                          let account, let active = UUID(uuidString: account), owner == active else { continue }
                    key = String(raw[raw.index(after: separator)...])
                }
                // Scope ordering does not create a second identity for the same cache key.
                guard let range = key.range(of: ":https://api.anthropic.com:") else { continue }
                let prefix = String(key[..<range.lowerBound]).lowercased()
                let scopes = key[range.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init).sorted().joined(separator: " ")
                let canonical = prefix + ":https://api.anthropic.com:" + scopes
                if raw.hasPrefix("acct:") { scoped[canonical] = value } else { legacy[canonical] = value }
            }
            return legacy.merging(scoped) { _, scoped in scoped }
        }
        let latest = normalized(v2)
        let older = normalized(v1).filter { latest[$0.key] == nil }
        for cache in [latest, older] {
            var candidates: [(credential: ClaudeUsageCredential, rank: (Int, Int, Int, Double))] = []
            for (key, raw) in cache {
                guard let range = key.range(of: ":https://api.anthropic.com:") else { continue }
                let ids = key[..<range.lowerBound].split(separator: ":")
                let scopes = key[range.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
                guard ids.count == 2, UUID(uuidString: String(ids[0])) != nil,
                      String(ids[1]) == organization.lowercased(), scopes.contains("user:profile"),
                      let entry = raw as? [String: Any], let token = entry["token"] as? String,
                      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let expiry = AIUsageDecoder.number(entry["expiresAt"]), expiry > (now.timeIntervalSince1970 + 120) * 1000 else { continue }
                let full = scopes.contains("user:inference")
                let production = ids[0] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
                let credential = ClaudeUsageCredential(desktopToken: token, expiresAt: Date(timeIntervalSince1970: expiry / 1000), plan: entry["rateLimitTier"] as? String ?? entry["subscriptionType"] as? String, account: account, organization: organization.lowercased(), generation: generation)
                candidates.append((credential, (production && full ? 1 : 0, full ? 1 : 0, scopes.count, expiry)))
            }
            if let best = candidates.max(by: { $0.rank < $1.rank }) { return best.credential }
        }
        throw AIUsageError.authentication
    }

    // MARK: - Electron safe storage

    private static func readPassword(_ manual: Bool) throws -> Data? {
        let context = LAContext(); context.interactionNotAllowed = !manual
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Claude Safe Storage", kSecAttrAccount as String: "Claude Key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else { throw AIUsageError.authentication }
            return data
        case errSecItemNotFound: return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: throw AIUsageError.keychainAccess
        default: throw AIUsageError.authentication
        }
    }

    private static func decodeCache(_ value: Any?, key: Data) throws -> [String: Any]? {
        guard let value else { return nil }
        guard let string = value as? String, let encrypted = Data(base64Encoded: string) else { throw AIUsageError.invalidResponse }
        return try AIUsageDecoder.object(Self.decrypt(encrypted, key: key))
    }

    static func deriveKey(_ password: Data) throws -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else { throw AIUsageError.authentication }
        return key
    }

    static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8), key.count == kCCKeySizeAES128 else { throw AIUsageError.invalidResponse }
        let payload = encrypted.dropFirst(3), iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = payload.count + kCCBlockSizeAES128
        var output = Data(count: capacity), length = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, ivBytes.baseAddress, payloadBytes.baseAddress, payload.count, outputBytes.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw AIUsageError.invalidResponse }
        output.count = length
        return output
    }
}
