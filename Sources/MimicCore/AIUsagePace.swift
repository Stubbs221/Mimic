//
//  AIUsagePace.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
// Adapted from OpenUsage 0.7.13, Copyright (c) 2026 Robin Ebers (MIT).
import Foundation

/// One verdict drives meter color, warning, tooltip and even-pace marker together.
public enum AIUsagePace {
    /// Missing or stale data cannot carry a live forecast. Level states have no reliable pacing signal.
    public enum State: Equatable, Sendable {
        case unavailable, stale, level(Severity), spent
        case healthy(projectedPercent: Double)
        case closeToLimit(sparePercent: Int, projectedPercent: Double, tick: Double)
        case runningOut(at: Date?, projectedPercent: Double, tick: Double)

        public var severity: Severity? {
            switch self {
            case .unavailable, .stale: nil
            case let .level(severity): severity
            case .healthy: .normal
            case .closeToLimit: .warning
            case .spent, .runningOut: .critical
            }
        }
        public var tick: Double? {
            switch self {
            case let .closeToLimit(_, _, tick), let .runningOut(_, _, tick): tick
            default: nil
            }
        }
        public var projectedPercent: Double? {
            switch self {
            case let .healthy(percent), let .closeToLimit(_, percent, _), let .runningOut(_, percent, _): percent
            default: nil
            }
        }
    }
    public enum Severity: Sendable { case normal, warning, critical }

    /// Mirrors OpenUsage's whole-percent meter safeguards. A deadline is returned only before reset.
    public static func evaluate(window: AIUsageWindow?, stale: Bool = false, now: Date) -> State {
        guard let window, let measured = window.usedPercent, measured.isFinite else { return .unavailable }
        guard !stale, !window.hasReset(at: now) else { return .stale }
        let used = min(100, max(0, measured))
        if (100 - used).rounded() <= 0 { return .spent }
        func level() -> State {
            let rounded = used.rounded()
            return .level(rounded >= 90 ? .critical : rounded >= 80 ? .warning : .normal)
        }
        guard used > 0, let reset = window.resetsAt, let duration = window.duration,
              duration.isFinite, duration > 0 else { return level() }
        let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-duration))
        guard elapsed >= max(60, duration * 0.01), now < reset else { return level() }
        let projected = used / elapsed * duration
        guard projected.isFinite else { return level() }
        if projected <= 90 { return .healthy(projectedPercent: projected) }
        // Whole-percent early readings otherwise cause fictitious run-out alarms.
        guard used >= 5 else { return level() }
        let tick = min(1, max(0, 1 - elapsed / duration))
        if projected <= 100 {
            let spare = Int(((100 - projected)).rounded())
            if spare >= 1 { return .closeToLimit(sparePercent: spare, projectedPercent: projected, tick: tick) }
            return .runningOut(at: nil, projectedPercent: projected, tick: tick)
        }
        let eta = (100 - used) / (used / elapsed)
        let deadline = eta > 0 && eta < reset.timeIntervalSince(now) ? now.addingTimeInterval(eta) : nil
        return .runningOut(at: deadline, projectedPercent: projected, tick: tick)
    }
}
