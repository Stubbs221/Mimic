//
//  ClaudeLogUsageParser.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
// Adapted from OpenUsage 0.7.13, Copyright (c) 2026 Robin Ebers (MIT).
import Foundation

/// Only usage metadata is retained; message text never enters the parsed-entry cache.
enum ClaudeLogUsageParser {
    struct Entry: Codable, Sendable, Equatable {
        var timestamp: Date
        var tokens: TokenBreakdown
        var messageID: String?
        var requestID: String?
        var isSidechain: Bool = false
        /// The line carried a `speed` field at all (dedup tiebreaker); `tokens.isFast` says it was "fast".
        var hasSpeed: Bool = false
        var costUSD: Double?
        /// `nil` when the line has no model or the placeholder `<synthetic>` (tokens count, cost is $0).
        var model: String?
    }

    static func parseLine(_ data: Data) -> Entry? {
        parseEntries(data).first
    }

    /// A Claude log line can carry nested advisor work in `usage.iterations`. The top-level usage
    /// remains the main-model entry; only advisor-message iterations become additional entries,
    /// matching ccusage without recounting the ordinary message iterations that feed that total.
    static func parseEntries(_ data: Data) -> [Entry] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = AIUsageDecoder.date(timestampRaw),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              !hasUnsupportedNullField(object, message: message, usage: usage),
              let parsedUsage = tokenBreakdown(from: usage),
              isValidEntry(object, message: message)
        else { return [] }

        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        let parent = Entry(
            timestamp: timestamp,
            tokens: parsedUsage.tokens,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            hasSpeed: parsedUsage.hasSpeed,
            costUSD: (object["costUSD"] as? NSNumber)?.doubleValue,
            model: model
        )

        guard let iterations = usage["iterations"] as? [[String: Any]] else { return [parent] }

        var entries = [parent]
        var advisorIndex = 0
        for iteration in iterations {
            guard iteration["type"] as? String == "advisor_message",
                  let advisorModel = iteration["model"] as? String,
                  !advisorModel.isEmpty,
                  let advisorUsage = tokenBreakdown(from: iteration)
            else { continue }

            entries.append(Entry(
                timestamp: parent.timestamp,
                tokens: advisorUsage.tokens,
                messageID: parent.messageID.map { "\($0):advisor:\(advisorIndex)" },
                requestID: parent.requestID,
                isSidechain: parent.isSidechain,
                hasSpeed: advisorUsage.hasSpeed,
                costUSD: nil,
                model: advisorModel
            ))
            advisorIndex += 1
        }
        return entries
    }

    private static func tokenBreakdown(
        from usage: [String: Any]
    ) -> (tokens: TokenBreakdown, hasSpeed: Bool)? {
        guard let input = usage["input_tokens"] as? NSNumber,
              let output = usage["output_tokens"] as? NSNumber
        else { return nil }

        // Claude tags fast-mode requests with `speed`; any value outside the known set marks a log
        // shape we don't understand, so the line is skipped (ccusage's enum parse does the same).
        let speed = usage["speed"] as? String
        if let speed, speed != "fast", speed != "standard" { return nil }

        // Cache writes: the 5m/1h split when present (1h bills at 2x input), else the legacy
        // aggregate `cache_creation_input_tokens` treated as all-5m.
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        if let cacheCreation = usage["cache_creation"] as? [String: Any] {
            cacheWrite5m = (cacheCreation["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0
            cacheWrite1h = (cacheCreation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        } else {
            cacheWrite5m = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        }

        return (TokenBreakdown(
            input: input.intValue,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
            output: output.intValue,
            isFast: speed == "fast"
        ), speed != nil)
    }

    /// ccusage's validity rules: a `version` that isn't semver-ish marks a foreign log format, and
    /// ids/model that are present but empty mark a malformed line.
    private static func isValidEntry(_ object: [String: Any], message: [String: Any]) -> Bool {
        if let version = object["version"] as? String, !isSemverPrefix(version) { return false }
        for value in [object["sessionId"], object["requestId"], message["id"], message["model"]] {
            if let text = value as? String, text.isEmpty { return false }
        }
        return true
    }

    /// `digits.digits.digit…` — accepts "1.0.24" and pre-release suffixes, rejects e.g. "unknown".
    static func isSemverPrefix(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        func digits() -> Bool {
            let start = index
            while index < bytes.count, bytes[index].isASCIIDigit { index += 1 }
            return index > start
        }
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        return index < bytes.count && bytes[index].isASCIIDigit
    }

    /// Claude never writes `null` into the schema fields we consume; a line that does is a
    /// foreign/corrupt shape that ccusage skips. The check is scoped to the exact objects we read
    /// (top level, `message`, `message.usage`) so unrelated nested keys sharing a name — such as
    /// `usage.iterations[].model`, which Claude Code 2.1.270 writes as `null` for ordinary message
    /// iterations — don't invalidate an otherwise valid record.
    static func hasUnsupportedNullField(
        _ object: [String: Any], message: [String: Any], usage: [String: Any]
    ) -> Bool {
        let levels: [([String: Any], [String])] = [
            (object, ["cwd", "costUSD", "version", "sessionId", "requestId", "isApiErrorMessage"]),
            (message, ["id", "model"]),
            (usage, ["speed", "cache_read_input_tokens", "cache_creation_input_tokens"])
        ]
        for (container, fields) in levels {
            for field in fields where container[field] is NSNull { return true }
        }
        return false
    }

    // MARK: - Deduplication

    private struct ExactKey: Hashable {
        var messageID: String
        var requestID: String?
    }

    /// Drop replayed usage lines, keeping ccusage's preferences. Entries are keyed by
    /// `(message.id, requestId)`; a second index on `message.id` alone catches sidechain logs that
    /// replay a parent message under a new request id. On a collision the existing entry is replaced
    /// only when the candidate wins `shouldReplace`. Entries without a message id are always kept.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var deduped: [Entry] = []
        var exactIndex: [ExactKey: Int] = [:]
        var messageIndex: [String: [Int]] = [:]

        for entry in entries {
            guard let messageID = entry.messageID else {
                deduped.append(entry)
                continue
            }
            let key = ExactKey(messageID: messageID, requestID: entry.requestID)
            let collision = exactIndex[key] ?? messageIndex[messageID]?.first(where: { index in
                entry.isSidechain || deduped[index].isSidechain
            })

            if let index = collision {
                if shouldReplace(candidate: entry, existing: deduped[index]) {
                    let old = deduped[index]
                    if let oldID = old.messageID {
                        exactIndex.removeValue(forKey: ExactKey(messageID: oldID, requestID: old.requestID))
                    }
                    deduped[index] = entry
                    exactIndex[key] = index
                }
                continue
            }

            let index = deduped.count
            deduped.append(entry)
            exactIndex[key] = index
            messageIndex[messageID, default: []].append(index)
        }
        return deduped
    }

    /// Preference order on a duplicate: the non-sidechain (parent) entry, then the larger token
    /// total, then the entry that carries a `speed` field (richer log shape).
    static func shouldReplace(candidate: Entry, existing: Entry) -> Bool {
        if candidate.isSidechain != existing.isSidechain {
            return existing.isSidechain
        }
        let candidateTotal = candidate.tokens.totalTokens
        let existingTotal = existing.tokens.totalTokens
        if candidateTotal != existingTotal {
            return candidateTotal > existingTotal
        }
        return candidate.hasSpeed && !existing.hasSpeed
    }

}
private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}
