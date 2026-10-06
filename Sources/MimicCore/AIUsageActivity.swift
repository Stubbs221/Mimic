//
//  AIUsageActivity.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation

/// Inference activity uses event timestamps, never file modification dates or chat titles.
public struct AIUsageActivity: Equatable, Codable, Sendable {
    public let provider: AIProvider
    public let date: Date
    public init(provider: AIProvider, date: Date) { self.provider = provider; self.date = date }
}

/// Shares one bounded, incremental metadata index between last-agent detection and local token history.
/// No message text, credentials or parsed log entries are written to disk.
public actor AIUsageActivityScanner {
    private struct Cursor {
        var offset: UInt64 = 0
        var modified: Date?
        var pending = Data()
        var skippingOversized = false
        var counters: String?
        var codex = CodexLogFileParser()
        var codexEvents: [CodexLogUsageScanner.Event] = []
        var claudeEntries: [ClaudeLogUsageParser.Entry] = []
    }
    private var cursors: [URL: Cursor] = [:]
    private var latest: AIUsageActivity?
    private let roots: [(URL, AIProvider)]
    private let pricing: AIUsagePricingStore

    public init(locations: AIUsageLocations = AIUsageLocations()) {
        self.roots = Self.roots(locations); self.pricing = AIUsagePricingStore()
    }
    init(locations: AIUsageLocations, pricing: AIUsagePricingStore) {
        self.roots = Self.roots(locations); self.pricing = pricing
    }
    private static func roots(_ locations: AIUsageLocations) -> [(URL, AIProvider)] {
        [(locations.codex.appendingPathComponent("sessions"), .codex), (locations.codex.appendingPathComponent("archived_sessions"), .codex), (locations.claude.appendingPathComponent("projects"), .claude), (locations.claudeDesktop, .claude)]
    }

    // MARK: - Incremental indexing

    /// Compatibility entry point for callers interested only in the latest inference.
    public func scan(now: Date = Date()) -> AIUsageActivity? {
        let since = Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: now)) ?? now
        var seen: Set<URL> = [], codexRelative: Set<String> = []
        for (root, provider) in self.roots {
            let resolved = root.resolvingSymlinksInPath()
            guard let enumerator = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
            for file in files {
                if Task.isCancelled { return self.latest }
                // Active rollout wins over an archived copy at the same relative path.
                if provider == .codex {
                    let relative = String(file.path.dropFirst(resolved.path.count))
                    guard codexRelative.insert(relative).inserted else { continue }
                }
                guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), info.isRegularFile == true, let size = info.fileSize else { continue }
                seen.insert(file)
                var cursor = self.cursors[file] ?? Cursor()
                cursor.codexEvents.removeAll { $0.timestamp < since }
                cursor.claudeEntries.removeAll { $0.timestamp < since }
                if cursor.offset == UInt64(size), cursor.modified == info.contentModificationDate {
                    self.cursors[file] = cursor; continue
                }
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                if UInt64(size) < cursor.offset || (UInt64(size) == cursor.offset && cursor.modified != info.contentModificationDate) { cursor = Cursor() }
                do {
                    try handle.seek(toOffset: cursor.offset)
                    repeat {
                        if Task.isCancelled { return self.latest }
                        let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                        if chunk.isEmpty { break }
                        cursor.offset += UInt64(chunk.count); cursor.modified = info.contentModificationDate
                        // A record over 1 MiB is discarded through its newline, even across chunks.
                        for fragment in chunk.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
                            if fragment.offset > 0 {
                                if !cursor.skippingOversized { self.parse(cursor.pending, provider: provider, cursor: &cursor, since: since, now: now) }
                                cursor.pending.removeAll(keepingCapacity: true); cursor.skippingOversized = false
                            }
                            if !cursor.skippingOversized {
                                if cursor.pending.count + fragment.element.count > 1024 * 1024 {
                                    cursor.pending.removeAll(keepingCapacity: true); cursor.skippingOversized = true
                                } else { cursor.pending.append(contentsOf: fragment.element) }
                            }
                        }
                    } while cursor.offset < UInt64(size)
                    self.cursors[file] = cursor
                } catch { continue }
            }
        }
        self.cursors = self.cursors.filter { seen.contains($0.key) }
        return self.latest
    }

    private func parse(_ line: Data, provider: AIProvider, cursor: inout Cursor, since: Date, now: Date) {
        guard !line.isEmpty else { return }
        if provider == .codex {
            let events = cursor.codex.parse(line)
            cursor.codexEvents.append(contentsOf: events.filter { $0.timestamp >= since && $0.timestamp <= now })
            if let date = events.last(where: { $0.timestamp <= now })?.timestamp {
                self.record(.codex, at: date); return
            }
            // Older activity-only logs carry just total_tokens. Full rollout records use the
            // parser's normalized events, so stale snapshots and child replay cannot select an agent.
            guard line.range(of: Data("\"token_count\"".utf8)) != nil, !cursor.codex.replaying,
                  let record = try? JSONDecoder().decode(ActivityRecord.self, from: line),
                  let usage = record.payload?.info?.total_token_usage,
                  usage.input_tokens == nil, usage.output_tokens == nil,
                  let date = AIUsageDecoder.date(record.timestamp), date <= now,
                  let signature = record.inferenceSignature(provider: provider), signature != cursor.counters else { return }
            cursor.counters = signature; self.record(provider, at: date)
        } else {
            guard line.range(of: Data("\"usage\"".utf8)) != nil else { return }
            cursor.claudeEntries.append(contentsOf: ClaudeLogUsageParser.parseEntries(line).filter { $0.timestamp >= since && $0.timestamp <= now })
            guard let record = try? JSONDecoder().decode(ActivityRecord.self, from: line), let date = AIUsageDecoder.date(record.timestamp), date <= now,
                  let signature = record.inferenceSignature(provider: provider), signature != cursor.counters else { return }
            cursor.counters = signature; self.record(provider, at: date)
        }
    }
    private func record(_ provider: AIProvider, at date: Date) {
        if self.latest.map({ date > $0.date }) ?? true { self.latest = AIUsageActivity(provider: provider, date: date) }
    }

    // MARK: - Daily history

    /// The same 31-day window and model eligibility rules as OpenUsage 0.7.13.
    /// Set `refreshPricing` false for offline reads; bundled catalogs remain available.
    public func scanUsage(now: Date = Date(), refreshPricing: Bool = true) async -> AIUsageScanResult {
        _ = self.scan(now: now)
        let pricing = await self.pricing.current(refresh: refreshPricing)
        var daily: [AIProvider: [AIUsageDailyPoint]] = [:], unknown: [AIProvider: Set<String>] = [:]
        var codexSeen: Set<CodexEventKey> = []
        for file in self.cursors.keys.sorted(by: { $0.path < $1.path }) {
            guard let cursor = self.cursors[file] else { continue }
            for event in cursor.codexEvents {
                guard codexSeen.insert(CodexEventKey(event)).inserted else { continue }
                let model = (event.pricingModel ?? event.model).trimmingCharacters(in: .whitespacesAndNewlines)
                let canonical = pricing.canonicalName(for: model)
                let base = canonical.hasSuffix("-fast") ? String(canonical.dropLast(5)) : canonical
                guard pricing.resolve(model: base) != nil || pricing.resolve(model: model) != nil else {
                    unknown[.codex, default: []].insert(event.model); continue
                }
                daily[.codex, default: []].append(AIUsageDailyPoint(date: event.timestamp, tokens: event.total))
            }
        }
        let claude = self.cursors.keys.sorted(by: { $0.path < $1.path }).flatMap { self.cursors[$0]?.claudeEntries ?? [] }
        for entry in ClaudeLogUsageParser.dedup(claude) {
            let model = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard entry.costUSD != nil || model.flatMap({ pricing.resolve(model: $0) }) != nil else {
                if let model, !model.isEmpty { unknown[.claude, default: []].insert(model) }; continue
            }
            daily[.claude, default: []].append(AIUsageDailyPoint(date: entry.timestamp, tokens: entry.tokens.totalTokens))
        }
        let histories = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { ($0, AIUsageHistory.points(daily: daily[$0] ?? [], now: now)) })
        return AIUsageScanResult(activity: self.latest, histories: histories, unknownModels: unknown.mapValues { $0.sorted() })
    }
}

/// Speed flags do not enter OpenUsage's copied-rollout dedup key.
private struct CodexEventKey: Hashable {
    let date: Date
    let model: String
    let pricingModel: String?
    let counts: [Int]
    init(_ event: CodexLogUsageScanner.Event) {
        self.date = event.timestamp; self.model = event.model; self.pricingModel = event.pricingModel
        self.counts = [event.input, event.cached, event.output, event.reasoning, event.total]
    }
}

/// Unknown fields (including message content) are skipped by Decodable.
private struct ActivityRecord: Decodable {
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let total_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
        var signature: String { "\(input_tokens ?? 0):\(output_tokens ?? 0):\(total_tokens ?? 0)" }
        var measured: Bool { (input_tokens ?? 0) > 0 || (output_tokens ?? 0) > 0 || (total_tokens ?? 0) > 0 || (cache_read_input_tokens ?? 0) > 0 || (cache_creation_input_tokens ?? 0) > 0 }
    }
    struct Message: Decodable { let role: String?; let usage: Usage?; let id: String? }
    struct Info: Decodable { let total_token_usage: Usage? }
    struct Payload: Decodable { let type: String?; let info: Info? }
    let type: String?
    let timestamp: String?
    let payload: Payload?
    let message: Message?
    let uuid: String?
    func inferenceSignature(provider: AIProvider) -> String? {
        if provider == .codex, type == "event_msg", payload?.type == "token_count", let usage = payload?.info?.total_token_usage, usage.measured { return usage.signature }
        if provider == .claude, type == "assistant", message?.role == "assistant", let usage = message?.usage, usage.measured { return message?.id ?? uuid ?? usage.signature }
        return nil
    }
}
