//
//  AIUsage.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import CoreFoundation

/// Subscription windows are normalized independently of a provider's primary/secondary slots.
public enum AIUsagePeriod: String, Codable, CaseIterable, Sendable { case session, weekly }

/// Automatic follows the subscription tier; an override never substitutes a missing window.
public enum AIUsagePreference: String, Codable, CaseIterable, Sendable { case automatic, session, weekly }

/// A measured usage percentage. Missing and non-finite measurements remain unavailable.
public struct AIUsageWindow: Equatable, Sendable {
    public let period: AIUsagePeriod
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let duration: TimeInterval?
    public init(period: AIUsagePeriod, usedPercent: Double?, resetsAt: Date? = nil, duration: TimeInterval? = nil) {
        self.period = period; self.usedPercent = usedPercent?.isFinite == true ? usedPercent : nil
        self.resetsAt = resetsAt; self.duration = duration
    }
    public var remainingPercent: Double? { self.usedPercent.map { min(100, max(0, 100 - $0)) } }
    public func hasReset(at date: Date) -> Bool { self.resetsAt.map { $0 <= date } ?? false }
}

/// Safe errors deliberately omit HTTP bodies, stderr, credentials and account labels.
public enum AIUsageError: Error, Equatable, Sendable {
    case authentication, keychainAccess, missingCLI, unsupported, invalidResponse, network, timeout, cancelled, accountChanged
    case rateLimited(retryAt: Date?)
    public var localizationKey: String {
        switch self {
        case .rateLimited: "usage.error.rateLimited"
        default: "usage.error." + String(describing: self)
        }
    }
}

/// Account identity is memory-only; snapshots are never written to settings or task history.
public struct AIUsageSnapshot: Equatable, Sendable {
    public let provider: AIProvider
    public let accountID: String
    public let plan: String?
    public let windows: [AIUsageWindow]
    public let fetchedAt: Date
    public init(provider: AIProvider, accountID: String, plan: String?, windows: [AIUsageWindow], fetchedAt: Date) {
        self.provider = provider; self.accountID = accountID; self.plan = plan; self.windows = windows; self.fetchedAt = fetchedAt
    }
    public func period(preference: AIUsagePreference) -> AIUsagePeriod {
        switch preference {
        case .session: return .session
        case .weekly: return .weekly
        case .automatic:
            let tier = self.plan?.lowercased() ?? ""
            let weekly = self.provider == .codex ? ["pro", "prolite", "promax"].contains(tier) || tier.hasPrefix("pro_") || tier.hasPrefix("pro ") : tier.contains("max")
            return weekly ? .weekly : .session
        }
    }
    public func window(_ period: AIUsagePeriod) -> AIUsageWindow? { self.windows.first { $0.period == period } }
    public func isStale(at date: Date) -> Bool { date.timeIntervalSince(self.fetchedAt) >= 300 }
    public func percentage(preference: AIUsagePreference, at date: Date) -> Int? {
        guard !self.isStale(at: date), let window = self.window(self.period(preference: preference)), !window.hasReset(at: date), let remaining = window.remainingPercent else { return nil }
        return Int(remaining.rounded(.down))
    }
}

/// Revisions are memory-only account generations; successful fetches identify the revision they acquired.
@MainActor
public protocol AIUsageFetching: AnyObject {
    var provider: AIProvider { get }
    func revision() -> String
    func fetch(manual: Bool) async throws -> AIUsageFetchResult
}

/// A result carries the revision acquired inside its fetch, rather than a stale pre-fetch revision.
public struct AIUsageFetchResult: Sendable {
    public let snapshot: AIUsageSnapshot
    public let revision: String
    public init(snapshot: AIUsageSnapshot, revision: String) { self.snapshot = snapshot; self.revision = revision }
}

/// Only the provider, last observed inference timestamp and display preferences are persisted.
public struct AIUsageSettings: Codable, Equatable, Sendable {
    public var lastProvider: AIProvider?
    public var lastActivity: Date?
    public var codex: AIUsagePreference = .automatic
    public var claude: AIUsagePreference = .automatic
    public init(lastProvider: AIProvider? = nil, lastActivity: Date? = nil) { self.lastProvider = lastProvider; self.lastActivity = lastActivity }
    public func preference(for provider: AIProvider) -> AIUsagePreference { provider == .codex ? self.codex : self.claude }
}

/// Provider wire decoding is pure, so compatibility and missing-data behavior can be tested offline.
public enum AIUsageDecoder {
    public static func codex(account: Data, limits: Data, now: Date) throws -> AIUsageSnapshot {
        let accountObject = try object(account)
        guard let account = accountObject["account"] as? [String: Any], account["type"] as? String == "chatgpt" else { throw AIUsageError.authentication }
        let response = try object(limits)
        let buckets = response["rateLimitsByLimitId"] as? [String: Any]
        guard let bucket = (buckets?["codex"] as? [String: Any]) ?? (buckets == nil ? response["rateLimits"] as? [String: Any] : nil) else { throw AIUsageError.invalidResponse }
        var windows: [AIUsageWindow] = []
        for (key, fallback) in [("primary", AIUsagePeriod.session), ("secondary", AIUsagePeriod.weekly)] {
            guard let value = bucket[key] as? [String: Any] else { continue }
            let minutes = number(value["windowDurationMins"])
            let period: AIUsagePeriod
            if let minutes, minutes > 0 { period = minutes >= 7 * 24 * 60 ? .weekly : .session } else { period = fallback }
            // Duration-based decoding permits a weekly-only response in primary.
            if !windows.contains(where: { $0.period == period }) {
                windows.append(AIUsageWindow(period: period, usedPercent: number(value["usedPercent"]), resetsAt: number(value["resetsAt"]).map(Date.init(timeIntervalSince1970:)), duration: minutes.map { $0 * 60 }))
            }
        }
        let identity = account["id"] as? String ?? account["accountId"] as? String ?? account["email"] as? String ?? "chatgpt"
        return AIUsageSnapshot(provider: .codex, accountID: identity, plan: bucket["planType"] as? String ?? account["planType"] as? String, windows: windows, fetchedAt: now)
    }

    public static func claude(usage: Data, profile: Data?, identity: String, fallbackPlan: String?, now: Date) throws -> AIUsageSnapshot {
        let response = try object(usage)
        let profile = profile.flatMap { try? object($0) }
        let organization = profile?["organization"] as? [String: Any]
        let account = profile?["account"] as? [String: Any]
        let plan = organization?["rate_limit_tier"] as? String ?? organization?["subscription_type"] as? String ?? fallbackPlan
        let accountID = account?["uuid"] as? String ?? identity
        let organizationID = organization?["uuid"] as? String ?? ""
        let windows = [("five_hour", AIUsagePeriod.session, 18000.0), ("seven_day", AIUsagePeriod.weekly, 604800.0)].compactMap { key, period, duration -> AIUsageWindow? in
            guard let value = response[key] as? [String: Any] else { return nil }
            return AIUsageWindow(period: period, usedPercent: number(value["utilization"]), resetsAt: date(value["resets_at"] as? String), duration: duration)
        }
        guard response.keys.contains("five_hour") || response.keys.contains("seven_day") else { throw AIUsageError.invalidResponse }
        return AIUsageSnapshot(provider: .claude, accountID: accountID + ":" + organizationID, plan: plan, windows: windows, fetchedAt: now)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1024 * 1024, let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AIUsageError.invalidResponse }
        return result
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    public static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
}
