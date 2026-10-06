//
//  CodexLogUsageScanner.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
// Adapted from OpenUsage 0.7.13, Copyright (c) 2026 Robin Ebers (MIT).
import Foundation

/// OpenUsage rollout normalization, without pricing or persisted session caches.
enum CodexLogUsageScanner {
    struct Event: Codable, Sendable, Equatable {
        var timestamp: Date
        var model: String
        var pricingModel: String? = nil
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
        var isFast: Bool = false
        var isUltrafast: Bool = false
    }

    struct RawUsage: Sendable {
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int

        init(json: [String: Any]) {
            func int(_ keys: String...) -> Int? {
                for key in keys {
                    if let number = AIUsageDecoder.number(json[key]), number >= 0, number < Double(Int.max) { return Int(number) }
                }
                return nil
            }
            input = int("input_tokens", "prompt_tokens", "input") ?? 0
            cached = int("cached_input_tokens", "cache_read_input_tokens", "cached_tokens") ?? 0
            output = int("output_tokens", "completion_tokens", "output") ?? 0
            reasoning = int("reasoning_output_tokens", "reasoning_tokens") ?? 0
            let reported = int("total_tokens") ?? 0
            let recomputed = [input, output, reasoning].reduce(0) { total, value in
                let sum = total.addingReportingOverflow(value); return sum.overflow ? Int.max : sum.partialValue
            }
            total = (reported > 0 || recomputed == 0) ? reported : recomputed
        }

        private init(input: Int, cached: Int, output: Int, reasoning: Int, total: Int) {
            self.input = input
            self.cached = cached
            self.output = output
            self.reasoning = reasoning
            self.total = total
        }

        /// Same token counts as `other` — an unchanged cumulative snapshot re-emitted by Codex.
        func equalCounts(_ other: RawUsage) -> Bool {
            input == other.input && cached == other.cached && output == other.output
                && reasoning == other.reasoning && total == other.total
        }

        /// Recover a turn delta from cumulative totals (used when `last_token_usage` is absent).
        func subtracting(_ previous: RawUsage?) -> RawUsage {
            RawUsage(
                input: max(0, input - (previous?.input ?? 0)),
                cached: max(0, cached - (previous?.cached ?? 0)),
                output: max(0, output - (previous?.output ?? 0)),
                reasoning: max(0, reasoning - (previous?.reasoning ?? 0)),
                total: max(0, total - (previous?.total ?? 0))
            )
        }
    }

    /// A session_meta payload marking the file as a child session (subagent spawn or fork) whose
    /// leading `token_count` lines replay the parent's history.
    ///
    /// JSON `null` is `NSNull`, not Swift `nil` — treat null (and blank strings) as absent so a
    /// root session that declares `forked_from_id: null` is not misclassified as a child.
    static func isChildSessionMeta(_ payload: [String: Any]) -> Bool {
        if hasNonNullValue(payload["forked_from_id"]) { return true }
        if hasNonNullValue(payload["parent_thread_id"]) { return true }
        if payload["thread_source"] as? String == "subagent" { return true }
        if let source = payload["source"] as? [String: Any], hasNonNullValue(source["subagent"]) {
            return true
        }
        return false
    }

    /// `true` when JSONSerialization yielded a real value (not missing, not `null`, not blank text).
    private static func hasNonNullValue(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            return false
        case let text as String:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    /// An explicit model on the line updates the session's current model. Otherwise the tracked
    /// model applies, and a session with no metadata falls back to `gpt-5`.
    static func resolveModel(
        parsed: String?,
        currentModel: inout String?
    ) -> String {
        if let parsed {
            currentModel = parsed
        }
        var model: String
        if let parsed {
            model = parsed
        } else if let current = currentModel {
            model = current
        } else {
            currentModel = "gpt-5"
            model = "gpt-5"
        }
        return model
    }

    /// `codex-auto-review` release timeline (newest first), from ccusage's embedded snapshot: a
    /// line dated on/after a release prices as that codex model.
    ///
    /// The `gpt-5.6-luna` entry is ours; ccusage's snapshot still stops at gpt-5.5. OpenAI moved
    /// auto-review onto the GPT-5.6 family when it shipped on 2026-07-09, and the Codex model
    /// catalog (`~/.codex/models_cache.json`) lists `codex-auto-review` with Luna's exact profile.
    /// Without this entry every auto-review event since July prices at gpt-5.5 rates, which are 25x
    /// Luna's across input, cache reads and output alike.
    private static let autoReviewFallbacks: [(releasedOn: String, model: String)] = [
        ("2026-07-09", "gpt-5.6-luna"),
        ("2026-04-23", "gpt-5.5"),
        ("2026-03-05", "gpt-5.4"),
        ("2026-02-05", "gpt-5.3-codex"),
        ("2025-12-11", "gpt-5.2-codex"),
        ("2025-11-13", "gpt-5.1-codex"),
        ("2025-09-15", "gpt-5-codex"),
        ("2025-08-07", "gpt-5")
    ]

    static func autoReviewFallback(at timestamp: String) -> String {
        let date = String(timestamp.prefix(10))
        guard date.count == 10, date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return "gpt-5"
        }
        return autoReviewFallbacks.first(where: { date >= $0.releasedOn })?.model ?? "gpt-5"
    }

    /// Luna Reserve keeps its `gpt-reserve` slug in breakdowns while using Luna's cost estimates.
    static let reservePricingModel = "gpt-5.6-luna"

}
