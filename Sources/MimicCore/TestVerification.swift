//
//  TestVerification.swift
//  MimicCore
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation

/// Process success and request coverage are independent. Arrays are bounded after computing the verdict.
public struct TestVerification: Codable, Sendable {
    public var verdict = "unavailable"
    public var selection = "unverified"
    public var requested: [String] = []
    public var executed: [String] = []
    public var unmatched: [String] = []
    public var skipped: [String] = []
    public var unexpected: [String] = []
    public var unmatchedCases: [String: [String]] = [:]
    public var methodCount = 0
    public var caseCount = 0
    public var iterationCount = 0
    public var responseTruncated = false
    public var extractionComplete = false
    public init() { }
}

public enum TestVerificationReader {
    private struct Fact { let method: String; let caseID: String; let status: String }
    /// Only structural parentage establishes case→method identity. There is no fuzzy ID matching.
    public static func verify(record: BuildActivity, nodes: [[String: Any]]?, summary: BuildResult.TestSummary?, detailsComplete: Bool) -> TestVerification {
        var result = TestVerification(); result.requested = record.parameters.testIdentifiers
        result.selection = record.selectionID == nil ? "unverified" : "catalogueVerified"
        var facts: [Fact] = [], complete = detailsComplete, observedFailure = false
        func walk(_ nodes: [[String: Any]], parent: String?, depth: Int) {
            guard depth < 24 else { complete = false; return }
            for node in nodes {
                let type = node["nodeType"] as? String ?? ""
                let rawIdentifier = node["nodeIdentifier"] as? String ?? ""
                let identifier = rawIdentifier.hasPrefix("test://") ? String(rawIdentifier.dropFirst(7)) : rawIdentifier
                let method = type == "Test Case" && identifier.split(separator: "/").count == 3 ? identifier : parent
                let children = node["children"] as? [[String: Any]] ?? []
                if let method, let status = node["result"] as? String {
                    if status == "Failed" { observedFailure = true }
                    if children.isEmpty { facts.append(.init(method: method, caseID: identifier.isEmpty ? method : identifier, status: status)) }
                } else if method != nil && children.isEmpty {
                    complete = false
                }
                walk(children, parent: method, depth: depth + 1)
            }
        }
        if let nodes { walk(nodes, parent: nil, depth: 0) } else { complete = false }
        if let summary {
            let methods = Set(facts.map(\.method)).count
            let cases = Set(facts.map { $0.method + "\0" + $0.caseID }).count
            if summary.total != methods && summary.total != cases { complete = false }
        }
        let requested = Set(result.requested)
        func selected(_ id: String) -> Bool { requested.contains(id) || requested.contains(where: { $0.split(separator: "/").count == 2 && id.hasPrefix($0 + "/") }) }
        let knownStatuses: Set<String> = ["Passed", "Failed", "Skipped", "Expected Failure", "ExpectedFailure"]
        if facts.contains(where: { !knownStatuses.contains($0.status) }) { complete = false }
        let executed = Set(facts.filter { $0.status != "Skipped" }.map(\.method))
        let skipped = Set(facts.filter { $0.status == "Skipped" && selected($0.method) }.map(\.method))
        result.methodCount = executed.count
        result.caseCount = Set(facts.filter { $0.status != "Skipped" }.map { $0.method + "\0" + $0.caseID }).count
        result.iterationCount = facts.filter { $0.status != "Skipped" }.count
        for (method, expected) in record.requestedTestCases ?? [:] {
            let executedCases = Set(facts.filter { $0.method == method && $0.status != "Skipped" }.map(\.caseID))
            let missing = expected.filter { !executedCases.contains($0.hasPrefix("test://") ? String($0.dropFirst(7)) : $0) }
            if !missing.isEmpty { result.unmatchedCases[method] = missing }
        }
        let unmatched = requested.filter { id in id.split(separator: "/").count == 2 ? !executed.contains(where: { $0.hasPrefix(id + "/") }) : !executed.contains(id) }
        let unexpected = executed.filter { !selected($0) }
        let anyFailed = record.status == .failed || observedFailure || facts.contains { $0.status == "Failed" } || (summary?.failed ?? 0) > 0
        result.extractionComplete = complete
        if anyFailed || !unexpected.isEmpty { result.verdict = "failed" }
        else if nodes == nil || summary == nil { result.verdict = "unavailable" }
        else if record.status != .succeeded || record.exitCode != 0 || !complete || executed.isEmpty || !unmatched.isEmpty || !result.unmatchedCases.isEmpty || !skipped.isEmpty || record.sourceProvenance?.stability != "unchangedObserved" { result.verdict = "incomplete" }
        else { result.verdict = "passed" }
        result.executed = Array(executed.sorted().prefix(200)); result.unmatched = unmatched.sorted(); result.skipped = Array(skipped.sorted().prefix(200)); result.unexpected = Array(unexpected.sorted().prefix(200))
        let missingCaseCount = result.unmatchedCases.values.reduce(0) { $0 + $1.count }
        var caseBudget = 100
        for method in result.unmatchedCases.keys.sorted() {
            let bounded = Array((result.unmatchedCases[method] ?? []).prefix(caseBudget)); caseBudget -= bounded.count
            result.unmatchedCases[method] = bounded.map { DiagnosticText.bounded(DiagnosticText.clean($0), limit: 1024).text }
        }
        result.responseTruncated = executed.count > 200 || skipped.count > 200 || unexpected.count > 200 || missingCaseCount > 100
        func clean(_ ids: [String]) -> [String] { ids.map { DiagnosticText.bounded(DiagnosticText.clean($0), limit: 1024).text } }
        result.requested = clean(result.requested); result.executed = clean(result.executed); result.unmatched = clean(result.unmatched); result.skipped = clean(result.skipped); result.unexpected = clean(result.unexpected)
        return result
    }
}
