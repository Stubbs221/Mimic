//
//  BuildResultTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct BuildResultTests {
    private func record(operation: BuildOperation = .build) -> BuildActivity {
        var record = BuildActivity(project: .init(path: "/private/tmp/Fixture", branch: "main", commit: "one"), parameters: .init(operation: operation), source: "MCP")
        record.status = .failed; record.exitCode = 65
        record.selectedDeveloperDirectory = "/fixture/Developer"
        return record
    }

    @Test func compilerLocationsAndMissingDetailsAreSeparateFromStatus() {
        let record = record()
        let result = BuildResultReader.read(record: record, output: Data("/private/tmp/Fixture/Screen.swift:12:8: error: Missing value\nwarning: Unused binding\n".utf8))
        #expect(result.issues.count == 2)
        #expect(result.issues[0].file == "/private/tmp/Fixture/Screen.swift" && result.issues[0].line == 12)
        #expect(result.issues[0].severity == "error")
        #expect(!result.outputUnavailable && result.testResultsUnavailable)
        #expect(result.testSummary == nil && result.extractionErrors.contains("resultBundleUnavailable"))
        let absent = BuildResultReader.read(record: record, output: Data())
        #expect(absent.outputUnavailable && absent.issues.isEmpty)
    }

    @Test func xcresultProducesTestFactsAndPinsXcode() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("BuildResult-" + UUID().uuidString + ".xcresult")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        var record = record(operation: .test); record.resultBundlePath = path.path
        let result = BuildResultReader.read(record: record, output: Data(), capture: { arguments, environment in
            #expect(environment["DEVELOPER_DIR"] == "/fixture/Developer")
            if arguments.contains("build-results") {
                return (0, #"{"errors":[{"message":"Invalid expression","sourceURL":"file:///private/tmp/File.swift#StartingLineNumber=42&EndingLineNumber=42"}],"warnings":[]}"#)
            }
            if arguments.contains("summary") {
                return (0, #"{"totalTestCount":2,"passedTests":1,"failedTests":1,"skippedTests":0,"expectedFailures":0,"testFailures":[{"testIdentifierString":"Tests/Screen/testOpen","failureText":"Expected visible screen"}]}"#)
            }
            return (0, #"{"testNodes":[{"nodeType":"Test Suite","children":[{"nodeType":"Test Case","nodeIdentifier":"Tests/Screen/testOpen","result":"Failed","durationInSeconds":0.4},{"nodeType":"Test Case","nodeIdentifier":"Tests/Screen/testClose","result":"Passed"}]}]}"#)
        })
        #expect(result.testSummary?.failed == 1 && result.testSummary?.passed == 1)
        #expect(!result.testResultsUnavailable && result.tests.count == 2)
        #expect(result.issues.first?.line == 42)
        #expect(result.issues.contains { $0.message == "Expected visible screen" })
        #expect(result.artifacts.first?.kind == "xcresult")
    }

    @Test func corruptionPrivateInputAndTruncationNeverInventSuccess() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("BuildResult-" + UUID().uuidString + ".xcresult")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        var record = record(operation: .test); record.resultBundlePath = path.path
        let corrupt = BuildResultReader.read(record: record, output: Data(), capture: { _, _ in (0, "{broken") })
        #expect(corrupt.testSummary == nil && corrupt.testResultsUnavailable && !corrupt.extractionErrors.isEmpty)
        record.hasPrivateInput = true
        let hidden = BuildResultReader.read(record: record, output: Data("Echo: PRIVATE-INPUT".utf8), capture: { _, _ in
            Issue.record("Private input must prevent every artifact query"); return (0, "{}")
        })
        #expect(hidden.diagnosticText.isEmpty && hidden.artifacts.isEmpty && hidden.issues.isEmpty)
        #expect(hidden.extractionErrors == ["privateInput"])
        record.hasPrivateInput = nil
        let large = BuildResultReader.read(record: record, output: Data(String(repeating: "warning: Fixture\n", count: 20_000).utf8), capture: { _, _ in (1, "") })
        #expect(large.truncated && large.diagnosticText.utf8.count <= 64 * 1024)
        #expect(try JSONEncoder().encode(large).count < 1024 * 1024)
    }

    @Test func legacyHistoryHasNoWorkflowAndRestartAdvancesActivityRevision() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("BuildResultHistory-" + UUID().uuidString)
        let store = BuildHistoryStore(directory: path)
        defer { try? FileManager.default.removeItem(at: path) }
        var record = record(); record.status = .running; record.stateRevision = 4; record.workflowID = UUID().uuidString
        try store.save([record])
        let restored = try #require(store.load().first)
        #expect(restored.status == .interrupted && restored.stateRevision == 5 && restored.workflowID == record.workflowID)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        old["stateRevision"] = nil; old["workflowID"] = nil
        let legacy = try JSONDecoder().decode(BuildActivity.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.stateRevision == nil && legacy.workflowID == nil)
    }
}
