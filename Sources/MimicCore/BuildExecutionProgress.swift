//
//  BuildExecutionProgress.swift
//  MimicCore
//
//  Created by Василий Маслов on 22.10.2026.
import Foundation

/// Observed Xcode operations have no known total; they never imply a compiler percentage.
public struct BuildExecutionProgress: Codable, Equatable, Sendable {
    public var operation: String?
    public var completedOperations: Int
    /// The compiler's reported fraction, never estimated from elapsed time or old builds.
    public var fraction: Double?
    public init(operation: String? = nil, completedOperations: Int = 0, fraction: Double? = nil) {
        self.operation = operation; self.completedOperations = completedOperations
        self.fraction = fraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
    }
}

/// Consumes bounded JSONL records. Command text, output and environment are deliberately ignored.
struct BuildEventParser {
    private var buffer = Data()
    private var droppingLine = false
    private var active: [String: String] = [:]
    private var order: [String] = []
    private var completed: Set<String> = []
    private(set) var progress = BuildExecutionProgress()

    mutating func append(_ data: Data) {
        for byte in data {
            if byte == 10 {
                if !droppingLine { consume(buffer) }
                buffer.removeAll(keepingCapacity: true); droppingLine = false
            } else if !droppingLine {
                if buffer.count < 1024 * 1024 { buffer.append(byte) }
                else { buffer.removeAll(keepingCapacity: true); droppingLine = true }
            }
        }
    }

    private mutating func consume(_ line: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let name = scalar(event["name"]), let payload = event["structuredPayload"] as? [String: Any],
              let info = payload["resultInfo"] as? [String: Any],
              let action = index(info["actionIndex"]), let result = index(info["resultIndex"]), let section = index(payload["sectionIndex"]) else { return }
        let id = action + ":" + result + ":" + section
        if name == "logSectionCreated" {
            guard active.count < 4096, completed.count < 65_536, !completed.contains(id),
                  let head = payload["head"] as? [String: Any],
                  (head["_type"] as? [String: Any])?["_name"] as? String == "ActivityLogCommandInvocationSectionHead",
                  let title = scalar(head["title"]), !title.isEmpty else { return }
            let visible = DiagnosticText.clean(title).components(separatedBy: .newlines).joined(separator: " ")
            let operation = String(visible.prefix(240))
            if active[id] == nil { order.append(id) }
            active[id] = operation; progress.operation = operation
        } else if name == "logSectionClosed", active.removeValue(forKey: id) != nil {
            order.removeAll { $0 == id }
            progress.operation = order.last.flatMap { active[$0] }
            // Failed, cancelled and duplicate closes do not count as completed work.
            guard let tail = payload["tail"] as? [String: Any], scalar(tail["result"]) == "succeeded",
                  scalar(tail["exitCode"]) == "0", completed.insert(id).inserted else { return }
            progress.completedOperations += 1
        }
    }

    private func scalar(_ value: Any?) -> String? { (value as? [String: Any])?["_value"] as? String }
    private func index(_ value: Any?) -> String? {
        guard let text = scalar(value), !text.isEmpty, text.utf8.count <= 20, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return text
    }
}
