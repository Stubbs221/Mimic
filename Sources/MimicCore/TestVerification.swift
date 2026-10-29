//
//  TestVerification.swift
//  MimicCore
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation

/// Small durable presentation data; full identifiers and executions remain in the result store.
public struct BuildVerificationSummary: Codable, Sendable {
    public let verdict: String
    public let methodCoverage: String?
    public let caseCoverage: String?
    public let methodCount: Int
    public let caseCount: Int
    public let iterationCount: Int
    public init(_ verification: TestVerification) {
        verdict = verification.verdict; methodCoverage = verification.methodCoverage; caseCoverage = verification.caseCoverage
        methodCount = verification.methodCount; caseCount = verification.caseCount; iterationCount = verification.iterationCount
    }
}

/// Process success and request coverage are independent. Arrays are bounded after computing the verdict.
public struct TestVerification: Codable, Sendable {
    public var methodCoverage: String?
    public var caseCoverage: String?
    public var identityErrors: [String]?
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
    /// The full selection/facts remain native-owned; transport responses contain bounded summaries.
    public var compactMetadata: BridgeValue {
        var fields = (try? BridgeValue.encode(self).object) ?? [:]
        fields["requestedCount"] = .number(Double(requested.count)); fields["requested"] = nil
        fields["unmatchedCount"] = .number(Double(unmatched.count))
        for key in ["executed", "unmatched", "skipped", "unexpected"] { fields[key] = .array(Array((fields[key]?.array ?? []).prefix(100))) }
        fields["responseTruncated"] = .bool(responseTruncated || executed.count > 100 || unmatched.count > 100 || skipped.count > 100 || unexpected.count > 100)
        return .object(fields)
    }
    public init() { }
}

public enum TestVerificationReader {
    /// Structural identity is shared with catalogue enumeration and public test facts.
    public static func verify(record: BuildActivity, nodes: [[String: Any]]?, summary: BuildResult.TestSummary?, detailsComplete: Bool) -> TestVerification {
        let parsed = nodes.map { TestIdentityParser.parse($0) }
        return verify(record: record, parsed: parsed, summary: summary, detailsComplete: detailsComplete)
    }
    public static func verify(record: BuildActivity, parsed: ParsedTestIdentities?, summary: BuildResult.TestSummary?, detailsComplete: Bool) -> TestVerification {
        var result = TestVerification(); result.requested = record.parameters.testTarget.map { [$0] } ?? record.parameters.testIdentifiers
        result.selection = record.parameters.testTarget != nil ? "target" : record.selectionID == nil ? "unverified" : "catalogueVerified"
        let facts = parsed?.facts ?? []
        var complete = detailsComplete && parsed?.complete == true
        let observedFailure = parsed?.observedFailure == true
        result.identityErrors = parsed?.errors
        if let summary {
            let methods = Set(facts.map(\.method)).count
            let cases = Set(facts.map { $0.method + "\0" + $0.caseID }).count
            let contextualCases = Set(facts.map { [$0.method, $0.caseID, $0.configurationID ?? "", $0.deviceID ?? ""].joined(separator: "\0") }).count
            if summary.total != methods && summary.total != cases && summary.total != contextualCases { complete = false }
        }
        let requested = Set(result.requested)
        func selected(_ id: String) -> Bool { record.parameters.testTarget.map { id.hasPrefix($0 + "/") } == true || requested.contains(id) || requested.contains(where: { $0.split(separator: "/").count == 2 && id.hasPrefix($0 + "/") }) }
        let knownStatuses: Set<String> = ["Passed", "Failed", "Skipped", "Expected Failure", "ExpectedFailure"]
        if facts.contains(where: { !knownStatuses.contains($0.status) }) { complete = false }
        let executed = Set(facts.filter { $0.status != "Skipped" }.map(\.method))
        let skipped = Set(facts.filter { $0.status == "Skipped" && selected($0.method) }.map(\.method))
        result.methodCount = executed.count
        result.caseCount = Set(facts.filter { $0.status != "Skipped" }.map { $0.method + "\0" + $0.caseID }).count
        result.iterationCount = facts.filter { $0.status != "Skipped" }.count
        for (method, expected) in record.requestedTestCases ?? [:] {
            let contextual = Dictionary(grouping: facts.filter { $0.method == method }, by: { ($0.configurationID ?? "") + "\0" + ($0.deviceID ?? "") })
            var missing = Set<String>()
            if contextual.isEmpty { missing.formUnion(expected) }
            for executions in contextual.values {
                let executedCases = Set(executions.filter { $0.status != "Skipped" }.map(\.caseID))
                missing.formUnion(expected.filter { !executedCases.contains($0) && !executedCases.contains($0.hasPrefix("test://") ? String($0.dropFirst(7)) : $0) })
            }
            if !missing.isEmpty { result.unmatchedCases[method] = missing.sorted() }
        }
        let unmatched = requested.filter { id in id.split(separator: "/").count <= 2 ? !executed.contains(where: { $0.hasPrefix(id + "/") }) : !executed.contains(id) }
        let unexpected = executed.filter { !selected($0) }
        let anyFailed = record.status == .failed || observedFailure || facts.contains { $0.status == "Failed" } || (summary?.failed ?? 0) > 0
        result.methodCoverage = complete && !executed.isEmpty && unmatched.isEmpty && skipped.isEmpty && unexpected.isEmpty ? "complete" : "incomplete"
        let expected = record.requestedTestCases ?? [:]
        let hasUnknownCases = facts.contains { $0.caseID != $0.method && expected[$0.method] == nil }
        result.caseCoverage = !result.unmatchedCases.isEmpty ? "incomplete" : hasUnknownCases ? "unknown" : complete ? "complete" : "unknown"
        result.extractionComplete = complete
        if anyFailed || !unexpected.isEmpty { result.verdict = "failed" }
        else if parsed == nil || summary == nil { result.verdict = "unavailable" }
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
