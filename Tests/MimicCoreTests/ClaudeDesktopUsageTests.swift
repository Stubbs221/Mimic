//
//  ClaudeDesktopUsageTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 12.10.2026.
import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import MimicCore

@Suite @MainActor
struct ClaudeDesktopUsageTests {
    let account = "11111111-1111-4111-8111-111111111111"
    let org = "22222222-2222-4222-8222-222222222222"
    let client = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    let now = Date(timeIntervalSince1970: 1000)
    var cacheKey: String { "\(self.client):\(self.org):https://api.anthropic.com:user:profile user:inference" }
    func entry(_ token: String = "fixture-only", expiry: Double = 2000000) -> [String: Any] { ["token": token, "expiresAt": expiry, "subscriptionType": "max"] }

    @Test func scopedAliasesTombstonesAndForeignAccounts() throws {
        let scoped = "acct:\(self.account)|\(self.cacheKey)"
        let credential = try #require(try ClaudeDesktopUsageCredentials.select(v2: [self.cacheKey: self.entry("old"), scoped: self.entry("current")], v1: nil, account: self.account, organization: self.org, generation: "g", now: self.now))
        #expect(credential.accessToken == "current" && credential.desktopAccount == self.account)
        #expect(throws: AIUsageError.authentication) {
            try ClaudeDesktopUsageCredentials.select(v2: [scoped: NSNull()], v1: [self.cacheKey: self.entry()], account: self.account, organization: self.org, generation: "g", now: self.now)
        }
        let other = "acct:33333333-3333-4333-8333-333333333333|\(self.cacheKey)"
        let fallback = try #require(try ClaudeDesktopUsageCredentials.select(v2: [other: NSNull()], v1: [scoped: self.entry()], account: self.account, organization: self.org.uppercased(), generation: "g", now: self.now))
        #expect(fallback.accessToken == "fixture-only")
    }

    @Test(arguments: [0.0, 1000000, 1120000])
    func expiredAndNearlyExpiredTokens(expiry: Double) {
        #expect(throws: AIUsageError.authentication) {
            try ClaudeDesktopUsageCredentials.select(v2: [self.cacheKey: self.entry(expiry: expiry)], v1: [self.cacheKey: self.entry()], account: self.account, organization: self.org, generation: "g", now: self.now)
        }
    }

    @Test func hostScopeAndProductionClientRanking() throws {
        let profile = self.cacheKey.replacingOccurrences(of: "user:profile user:inference", with: "user:profile")
        let selected = try #require(try ClaudeDesktopUsageCredentials.select(v2: [self.cacheKey: self.entry("full"), profile: self.entry("partial", expiry: 9000000)], v1: nil, account: nil, organization: self.org, generation: "g", now: self.now))
        #expect(selected.accessToken == "full")
        for key in [self.cacheKey.replacingOccurrences(of: "api.anthropic.com", with: "example.com"), self.cacheKey.replacingOccurrences(of: "user:profile", with: "user:other"), self.cacheKey.replacingOccurrences(of: self.org, with: self.account)] {
            #expect(throws: AIUsageError.authentication) {
                try ClaudeDesktopUsageCredentials.select(v2: [key: self.entry()], v1: nil, account: nil, organization: self.org, generation: "g", now: self.now)
            }
        }
    }

    @Test(arguments: [false, true])
    func encryptedDesktopStorageAndAccountSwitch(encryptedCookie: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeDesktop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let password = Data("fixture-password".utf8), key = try ClaudeDesktopUsageCredentials.deriveKey(password)
        let cache = try Self.encrypt(JSONSerialization.data(withJSONObject: ["acct:\(self.account)|\(self.cacheKey)": self.entry()]), key: key)
        var config: [String: Any] = ["lastKnownAccountUuid": self.account, "oauth:tokenCacheV2": cache.base64EncodedString()]
        let configURL = root.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        let host = ".claude.ai"
        let cookie = encryptedCookie ? try Self.encrypt(Data(SHA256.hash(data: Data(host.utf8))) + Data(self.org.utf8), key: key) : Data()
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("Cookies").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let hex = cookie.map { String(format: "%02x", $0) }.joined()
        let value = encryptedCookie ? "" : self.org
        let sql = "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, last_update_utc INTEGER); INSERT INTO cookies VALUES ('\(host)', 'lastActiveOrg', '\(value)', X'\(hex)', 1)"
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        var interactions: [Bool] = []
        let reader = ClaudeDesktopUsageCredentials(directory: root, password: { manual in interactions.append(manual); return password }, now: { self.now })
        let originalConfig = try Data(contentsOf: configURL), originalCookies = try Data(contentsOf: root.appendingPathComponent("Cookies"))
        let denied = ClaudeDesktopUsageCredentials(directory: root, password: { _ in throw AIUsageError.keychainAccess }, now: { self.now })
        #expect(throws: AIUsageError.keychainAccess) { try denied.read(manual: false) }
        let credential = try #require(try reader.read(manual: false))
        #expect(credential.accessToken == "fixture-only" && credential.plan == "max")
        #expect(reader.isCurrent(credential) && interactions == [false])
        _ = try reader.read(manual: true)
        #expect(interactions == [false, true])
        #expect(try Data(contentsOf: configURL) == originalConfig)
        #expect(try Data(contentsOf: root.appendingPathComponent("Cookies")) == originalCookies)
        config["lastKnownAccountUuid"] = "33333333-3333-4333-8333-333333333333"
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        #expect(!reader.isCurrent(credential))
        #expect(throws: AIUsageError.authentication) { try reader.read(manual: false) }
        #expect(try Data(contentsOf: configURL) == JSONSerialization.data(withJSONObject: config))
    }

    @Test func missingStorageDoesNotReadKeychainAndInvalidCipherFails() throws {
        let reader = ClaudeDesktopUsageCredentials(directory: URL(fileURLWithPath: "/nonexistent-fixture"), password: { _ in Issue.record("Unexpected Keychain access"); return nil })
        #expect(try reader.read(manual: false) == nil)
        #expect(throws: AIUsageError.invalidResponse) { try ClaudeDesktopUsageCredentials.decrypt(Data("invalid".utf8), key: Data(count: 16)) }
    }

    private static func encrypt(_ data: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128), capacity = data.count + kCCBlockSizeAES128
        var result = Data(count: capacity), length = 0
        let status = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, data.count, output.baseAddress, capacity, &length)
                    }
                }
            }
        }
        #expect(status == kCCSuccess)
        result.count = length
        return Data("v10".utf8) + result
    }
}
