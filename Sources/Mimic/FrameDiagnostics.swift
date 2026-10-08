//
//  FrameDiagnostics.swift
//  Mimic
//
//  Created by Василий Маслов on 08.10.2026.
import Foundation
import Observation
import os
import Darwin

@MainActor enum FrameMainThreadCPU {
    static func seconds() -> Double {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }
}

/// Numeric, window-scoped diagnostics. Signposts contain no checkout, account or task metadata.
@MainActor enum FramePerformanceTrace {
    private static let log = OSLog(subsystem: "local.vmaslov.Mimic", category: .pointsOfInterest)
    static weak var view: FrameDiagnosticsNativeView?
    static func begin(_ name: StaticString) -> OSSignpostID? {
        guard view?.displayLink != nil else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }
    static func end(_ name: StaticString, _ id: OSSignpostID?) {
        guard let id else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
    static func event(_ name: StaticString) {
        guard view?.displayLink != nil else { return }
        os_signpost(.event, log: log, name: name)
    }
    static func frameMiss(durationMS: Double, budgetMS: Double) {
        os_signpost(.event, log: log, name: "Frame budget exceeded", "interval=%{public}.3f ms budget=%{public}.3f ms", durationMS, budgetMS)
    }
}

struct FrameDiagnosticsReport: Codable {
    let intervalCount: Int
    let elapsedSeconds: Double
    let p95MS: Double
    let p99MS: Double
    let maximumMS: Double
    let overTwoBudgets: Int
}

/// Desktop-only opt-in. Sampling never forwards notifications through TaskCoordinator.
@MainActor @Observable final class FrameDiagnosticsSettings {
    var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.key) } }
    private static let key = "showFrameDiagnostics"
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Self.key)
    }
}

struct FrameDiagnosticsSnapshot {
    var fps: Double?
    /// Oldest to newest, with gaps instead of invented frames when no callbacks arrived.
    var peaks: [Double?] = Array(repeating: nil, count: 40)
    var budgetMS: Double = 1000 / 60
    var maximumMS: Double { peaks.compactMap { $0 }.max() ?? 0 }
    var scaleMS: Double { max(budgetMS * 2, maximumMS * 1.1) }
}

/// Main-thread callback cadence, not compositor presentation statistics.
/// Constant-size graph storage and an amortized queue keep the per-callback path cheap.
struct FrameDiagnosticsSamples {
    private struct Bucket { var index = -1; var peak: Double = 0 }
    private struct Interval { let end: Double; let duration: Double }
    private var buckets = Array(repeating: Bucket(), count: 40)
    private var intervals: [Interval] = []
    private var head = 0
    private var origin: Double?
    private var previous: Double?
    private var publication: Double?
    private var budgetMS: Double = 1000 / 60
    private(set) var lastIntervalMS: Double = 0
    var frameBudgetMS: Double { budgetMS }
    private struct Measurement { let end: Double; let durationMS: Double; let overBudget: Bool }
    private var measurements: [Measurement] = []
    private var measurementHead = 0

    mutating func reset() { self = Self() }

    /// Returns true only when a new display snapshot is due, at most once per 250 ms.
    mutating func record(at now: Double, budget: Double) -> Bool {
        guard now.isFinite else { return false }
        if budget.isFinite, budget > 0 { budgetMS = budget * 1000 }
        guard let previous, let origin else {
            self.origin = now; self.previous = now; self.publication = now
            return false
        }
        guard now > previous else {
            if now < previous { reset() }
            return false
        }
        let duration = now - previous
        lastIntervalMS = duration * 1000
        self.previous = now
        measurements.append(Measurement(end: now, durationMS: duration * 1000, overBudget: duration * 1000 > budgetMS * 2 + 0.001))
        while measurementHead < measurements.count, measurements[measurementHead].end <= now - 90 { measurementHead += 1 }
        measurementHead = max(measurementHead, measurements.count - 16384)
        if measurementHead >= 256 { measurements.removeFirst(measurementHead); measurementHead = 0 }
        let index = Int((now - origin) / 0.25)
        let slot = index % buckets.count
        if buckets[slot].index != index { buckets[slot] = Bucket(index: index) }
        buckets[slot].peak = max(buckets[slot].peak, duration * 1000)
        intervals.append(Interval(end: now, duration: duration))
        while head < intervals.count, intervals[head].end <= now - 1 { head += 1 }
        // The safety cap also bounds synthetic or pathological callback rates.
        head = max(head, intervals.count - 4096)
        if head >= 256 { intervals.removeFirst(head); head = 0 }
        guard now - (publication ?? now) >= 0.25 - 0.0000001 else { return false }
        publication = now
        return true
    }

    func snapshot() -> FrameDiagnosticsSnapshot {
        guard let now = previous, let origin, now > origin else { return .init(budgetMS: budgetMS) }
        let window = min(1, now - origin), cutoff = now - window
        // Fractional overlap makes a long interval crossing the window boundary count fairly.
        let count = intervals.dropFirst(head).reduce(0.0) { value, interval in
            value + min(interval.duration, max(0, interval.end - cutoff)) / interval.duration
        }
        let current = Int((now - origin) / 0.25)
        let peaks: [Double?] = (current - 39...current).map { index in
            guard index >= 0 else { return nil }
            let bucket = buckets[index % buckets.count]
            return bucket.index == index ? bucket.peak : nil
        }
        return .init(fps: count / window, peaks: peaks, budgetMS: budgetMS)
    }

    /// Percentile sorting occurs only on explicit inspection, never on the display-link callback.
    func report() -> FrameDiagnosticsReport {
        let window = measurements.dropFirst(measurementHead)
        let durations = window.map(\.durationMS).sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !durations.isEmpty else { return 0 }
            return durations[max(0, Int(ceil(Double(durations.count) * fraction)) - 1)]
        }
        let elapsed = window.first.flatMap { first in window.last.map { $0.end - first.end + first.durationMS / 1000 } } ?? 0
        return .init(intervalCount: durations.count, elapsedSeconds: min(90, elapsed), p95MS: percentile(0.95), p99MS: percentile(0.99), maximumMS: durations.last ?? 0, overTwoBudgets: window.filter(\.overBudget).count)
    }
}
