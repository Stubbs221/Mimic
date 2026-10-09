//
//  BuildResult.swift
//  MimicCore
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import CoreFoundation

/// Bounded facts from an existing check. Execution status remains authoritative even when details are missing.
public struct BuildResult: Codable, Sendable {
    public struct Issue: Codable, Equatable, Sendable {
        public let severity: String
        public let message: String
        public let file: String?
        public let line: Int?
        public let source: String
    }
    public struct Test: Codable, Sendable {
        public let identifier: String
        public let status: String
        public let duration: Double?
    }
    public struct TestSummary: Codable, Sendable {
        public let total: Int
        public let passed: Int
        public let failed: Int
        public let skipped: Int
        public let expectedFailures: Int
    }
    public struct Artifact: Codable, Sendable {
        public let kind: String
        public let path: String
    }
    public var verification: TestVerification?
    public var sourceProvenance: SourceProvenance?
    public var sourceFreshness: String = "unknown"
    public var artifactAvailability: String = "unavailable"
    public var issues: [Issue] = []
    public var tests: [Test] = []
    public var testSummary: TestSummary?
    public var artifacts: [Artifact] = []
    public var sources: [String] = []
    public var extractionErrors: [String] = []
    public var diagnosticText = ""
    public var truncated = false
    public var outputUnavailable = true
    public var testResultsUnavailable = true
    public init() { }
}

/// Reads only artifact paths recorded by the native owner, with pinned Xcode and bounded subprocess output.
/// Parsing is separate from extraction so schema drift and corrupt bundles can be tested without running Xcode.
public enum BuildResultReader {
    public typealias Capture = @Sendable ([String], [String: String]) -> (Int32, String)

    public static func read(record: BuildActivity, output: Data, capture: Capture? = nil) -> BuildResult {
        let capture = capture ?? { arguments, environment in
            ReadOnlyProcess.capture("/usr/bin/xcrun", arguments, directory: nil, environment: environment, timeout: 8, maximumBytes: 512 * 1024)
        }
        var result = BuildResult()
        result.sourceProvenance = record.sourceProvenance
        if record.parameters.operation == .test { result.verification = TestVerificationReader.verify(record: record, nodes: nil, summary: nil, detailsComplete: false) }
        result.truncated = record.truncated
        // Neither artifacts nor echoed output may bypass private terminal input protection.
        guard record.hasPrivateInput != true else { result.extractionErrors = ["privateInput"]; return result }
        let text = DiagnosticText.bounded(DiagnosticText.visible(String(decoding: output, as: UTF8.self)))
        result.diagnosticText = text.text; result.truncated = result.truncated || text.truncated
        result.outputUnavailable = text.text.isEmpty
        let outputSource = record.parameters.backend == .cli ? "sanitizedOutput" : "xcodeMCP"
        if !text.text.isEmpty {
            result.sources.append(outputSource)
            appendOutput(text.text, source: outputSource, to: &result)
        }
        guard !record.status.isPending else { result.extractionErrors.append("notFinished"); return result }
        if let summary = record.resultSummaryPath {
            let url = URL(fileURLWithPath: summary)
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
               let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                let bytes = (try? handle.read(upToCount: DiagnosticText.maximumBytes + 1)) ?? Data()
                let cleaned = DiagnosticText.bounded(DiagnosticText.visible(String(decoding: bytes, as: UTF8.self)))
                result.truncated = result.truncated || cleaned.truncated
                if !cleaned.text.isEmpty {
                    result.sources.append("xcodeSummary"); result.outputUnavailable = false
                    appendOutput(cleaned.text, source: "xcodeSummary", to: &result)
                    result.artifacts.append(.init(kind: "xcodeSummary", path: DiagnosticText.bounded(summary, limit: 4096).text))
                }
            } else { result.extractionErrors.append("summaryUnavailable") }
        }
        guard let path = record.resultBundlePath, FileManager.default.fileExists(atPath: path) else {
            result.artifactAvailability = record.resultBundlePath == nil ? "notRecorded" : "expired"
            result.extractionErrors.append("resultBundleUnavailable"); return result
        }
        result.artifactAvailability = "available"
        result.artifacts.append(.init(kind: "xcresult", path: DiagnosticText.bounded(path, limit: 4096).text))
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        if let developer = record.selectedDeveloperDirectory { environment["DEVELOPER_DIR"] = developer }
        func query(_ arguments: [String], code: String) -> [String: Any]? {
            let (status, output) = capture(["xcresulttool", "get"] + arguments + ["--path", path, "--compact"], environment)
            guard status == 0, output.utf8.count <= 512 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
                result.extractionErrors.append(code); return nil
            }
            return object
        }
        if let build = query(["build-results"], code: "buildResultsUnavailable") {
            if let errors = build["errors"] as? [[String: Any]], let warnings = build["warnings"] as? [[String: Any]] {
                result.sources.append("xcresultBuild")
                appendIssues(errors, severity: "error", to: &result)
                appendIssues(warnings, severity: "warning", to: &result)
            } else { result.extractionErrors.append("buildResultsMalformed") }
        }
        if record.parameters.operation == .test {
            if let summary = query(["test-results", "summary"], code: "testSummaryUnavailable"),
               let total = count(summary["totalTestCount"]), let passed = count(summary["passedTests"]),
               let failed = count(summary["failedTests"]), let skipped = count(summary["skippedTests"]),
               let expected = count(summary["expectedFailures"]) {
                result.testSummary = .init(total: total, passed: passed, failed: failed, skipped: skipped, expectedFailures: expected)
                result.sources.append("xcresultTests"); result.testResultsUnavailable = false
                if let failures = summary["testFailures"] as? [[String: Any]] {
                    for failure in failures.prefix(128) {
                        if let message = failure["failureText"] as? String {
                            append(.init(severity: "error", message: clean(message), file: nil, line: nil, source: "xcresultTestFailure"), to: &result)
                        }
                    }
                    result.truncated = result.truncated || failures.count > 128
                }
            } else if !result.extractionErrors.contains("testSummaryUnavailable") { result.extractionErrors.append("testSummaryMalformed") }
            result.verification = TestVerificationReader.verify(record: record, nodes: nil, summary: result.testSummary, detailsComplete: false)
            if let tests = query(["test-results", "tests"], code: "testDetailsUnavailable") {
                let nodes = tests["testNodes"] as? [[String: Any]]
                result.verification = TestVerificationReader.verify(record: record, nodes: nodes, summary: result.testSummary, detailsComplete: nodes != nil)
                if let nodes = tests["testNodes"] as? [[String: Any]] { appendTests(nodes, depth: 0, to: &result) }
                else { result.extractionErrors.append("testDetailsMalformed") }
            }
        }
        return result
    }

    // MARK: - Bounded schema and output parsing

    private static func clean(_ text: String) -> String { DiagnosticText.clean(text) }
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
    private static func append(_ issue: BuildResult.Issue, to result: inout BuildResult) {
        guard result.issues.count < 128 else { result.truncated = true; return }
        let message = DiagnosticText.bounded(issue.message, limit: 1024)
        let file = issue.file.map { DiagnosticText.bounded($0, limit: 1024) }
        result.truncated = result.truncated || message.truncated || file?.truncated == true
        let bounded = BuildResult.Issue(severity: issue.severity, message: message.text, file: file?.text, line: issue.line, source: issue.source)
        if !result.issues.contains(bounded) { result.issues.append(bounded) }
    }
    private static func appendOutput(_ text: String, source: String, to result: inout BuildResult) {
        let pattern = #"^(.*?):([0-9]+)(?::[0-9]+)?: (error|warning): (.*)$"#
        let expression = try? NSRegularExpression(pattern: pattern)
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = expression?.firstMatch(in: line, range: range) {
                func group(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "" }
                append(.init(severity: group(3), message: clean(group(4)), file: clean(group(1)), line: Int(group(2)), source: source), to: &result)
            } else if line.hasPrefix("error:") || line.hasPrefix("warning:") {
                append(.init(severity: line.hasPrefix("error:") ? "error" : "warning", message: clean(line), file: nil, line: nil, source: source), to: &result)
            }
        }
    }
    private static func appendIssues(_ issues: [[String: Any]], severity: String, to result: inout BuildResult) {
        for issue in issues.prefix(128) {
            guard let message = issue["message"] as? String else { continue }
            var file: String?, line: Int?
            if let source = issue["sourceURL"] as? String, let url = URLComponents(string: source), url.scheme == "file" {
                file = clean(url.path)
                if let fragment = url.fragment {
                    line = fragment.split(separator: "&").first(where: { $0.hasPrefix("StartingLineNumber=") }).flatMap { Int($0.dropFirst("StartingLineNumber=".count)) }
                }
            }
            append(.init(severity: severity, message: clean(message), file: file, line: line, source: "xcresultBuild"), to: &result)
        }
        result.truncated = result.truncated || issues.count > 128
    }
    private static func appendTests(_ nodes: [[String: Any]], depth: Int, to result: inout BuildResult) {
        guard depth < 24 else { result.truncated = true; return }
        for node in nodes {
            guard result.tests.count < 200 else { result.truncated = true; return }
            if node["nodeType"] as? String == "Test Case", let identifier = node["nodeIdentifier"] as? String, let status = node["result"] as? String {
                let duration = (node["durationInSeconds"] as? NSNumber)?.doubleValue
                let boundedIdentifier = DiagnosticText.bounded(identifier, limit: 1024), boundedStatus = DiagnosticText.bounded(status, limit: 64)
                result.truncated = result.truncated || boundedIdentifier.truncated || boundedStatus.truncated
                result.tests.append(.init(identifier: boundedIdentifier.text, status: boundedStatus.text, duration: duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }))
            }
            if let children = node["children"] as? [[String: Any]] { appendTests(children, depth: depth + 1, to: &result) }
        }
    }
}
