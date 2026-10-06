//
//  AIUsageHistory.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
// Calendar window and aggregation adapted from OpenUsage 0.7.13 (MIT).
import Foundation

/// A measured local-calendar day's tokens. Idle days retain their position in the trend.
public struct AIUsageDailyPoint: Equatable, Sendable {
    public let date: Date
    public let tokens: Int
    public init(date: Date, tokens: Int) { self.date = date; self.tokens = max(0, tokens) }
}

/// Activity is independent of pricing: an unknown model still identifies the last agent used.
public struct AIUsageScanResult: Equatable, Sendable {
    public let activity: AIUsageActivity?
    public let histories: [AIProvider: [AIUsageDailyPoint]]
    public let unknownModels: [AIProvider: [String]]
    public init(activity: AIUsageActivity?, histories: [AIProvider: [AIUsageDailyPoint]] = [:], unknownModels: [AIProvider: [String]] = [:]) {
        self.activity = activity; self.histories = histories; self.unknownModels = unknownModels
    }
}

/// Today plus 30 prior days, oldest first. A completely idle window has no chart.
public enum AIUsageHistory {
    public static func points(daily: [AIUsageDailyPoint], now: Date, calendar: Calendar = .current) -> [AIUsageDailyPoint] {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -30, to: today) else { return [] }
        var totals: [Date: Int] = [:]
        for point in daily {
            let day = calendar.startOfDay(for: point.date)
            guard day >= start, day <= today else { continue }
            let sum = totals[day, default: 0].addingReportingOverflow(point.tokens)
            totals[day] = sum.overflow ? Int.max : sum.partialValue
        }
        guard totals.values.contains(where: { $0 > 0 }) else { return [] }
        return (0...30).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { AIUsageDailyPoint(date: $0, tokens: totals[$0] ?? 0) }
        }
    }
}
