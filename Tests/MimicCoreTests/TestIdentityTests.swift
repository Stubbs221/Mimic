//
//  TestIdentityTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct TestIdentityTests {
    private func fixture(_ name: String) throws -> [[String: Any]] {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let data = try Data(contentsOf: root.appendingPathComponent("CIWorkflow/" + name + ".json"))
        return try #require((JSONSerialization.jsonObject(with: data) as? [String: Any])?["testNodes"] as? [[String: Any]])
    }
    private func record(_ methods: [String]) -> BuildActivity {
        var value = BuildActivity(project: .init(path: "/fixture"), parameters: .init(operation: .test, testIdentifiers: methods), source: "Fixture")
        value.status = .succeeded; value.exitCode = 0
        let revision = SourceRevision(rulesRevision: "fixture", digest: "unchanged", fileCount: 0)
        var source = SourceProvenance(admitted: revision); source.started = revision; source.observe(revision); value.sourceProvenance = source
        return value
    }
    @Test func realXCTestShapeMatchesSixMethodsAndRejectsOtherTarget() throws {
        let nodes = try fixture("xctest"), parsed = TestIdentityParser.parse(nodes)
        #expect(parsed.complete && parsed.methods.count == 6 && parsed.facts.count == 6)
        let methods = parsed.methods.map(\.id), summary = BuildResult.TestSummary(total: 6, passed: 6, failed: 0, skipped: 0, expectedFailures: 0)
        #expect(TestVerificationReader.verify(record: record(methods), parsed: parsed, summary: summary, detailsComplete: true).verdict == "passed")
        let wrong = record(methods.map { $0.replacingOccurrences(of: "FixtureTests/", with: "OtherTests/") })
        let verification = TestVerificationReader.verify(record: wrong, parsed: parsed, summary: summary, detailsComplete: true)
        #expect(verification.verdict == "failed" && verification.unmatched.count == 6 && verification.unexpected.count == 6)
    }
    @Test func realSwiftTestingShapeKeepsFourOpaqueCasesAndUnknownExpectation() throws {
        let parsed = TestIdentityParser.parse(try fixture("swift-testing"))
        #expect(parsed.complete && parsed.methods.count == 1 && parsed.facts.count == 4)
        let summary = BuildResult.TestSummary(total: 1, passed: 1, failed: 0, skipped: 0, expectedFailures: 0)
        var value = record(parsed.methods.map(\.id))
        let result = TestVerificationReader.verify(record: value, parsed: parsed, summary: summary, detailsComplete: true)
        #expect(result.verdict == "passed" && result.methodCount == 1 && result.caseCount == 4 && result.iterationCount == 4)
        #expect(result.methodCoverage == "complete" && result.caseCoverage == "unknown")
        value.requestedTestCases = [parsed.methods[0].id: parsed.facts.map(\.caseID) + ["missing-case"]]
        #expect(TestVerificationReader.verify(record: value, parsed: parsed, summary: summary, detailsComplete: true).caseCoverage == "incomplete")
    }
    @Test func conflictingStructuralTargetAndMalformedChildrenFailClosed() {
        let nodes: [[String: Any]] = [["nodeType": "Unit test bundle", "name": "One", "nodeIdentifierURL": "test://com.apple.xcode/Fixture/Two", "children": [["nodeType": "Test Case", "nodeIdentifier": "Suite/test()", "result": "Passed"]]]]
        #expect(!TestIdentityParser.parse(nodes).complete)
        #expect(!TestIdentityParser.parse([["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/test()", "children": "invalid", "result": "Passed"]]).complete)
    }
    @Test func configurationsDevicesAndAttemptsRemainSeparate() {
        let nodes: [[String: Any]] = ["A", "B"].map { configuration in
            ["nodeType": "Configuration", "nodeIdentifier": configuration, "children": [["nodeType": "Device", "nodeIdentifier": "phone", "children": [["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/test()", "result": "Passed", "children": [["nodeType": "Test Case Run", "nodeIdentifier": "one", "result": "Failed"], ["nodeType": "Test Case Run", "nodeIdentifier": "one", "result": "Passed"]]]]]]]
        }
        let parsed = TestIdentityParser.parse(nodes)
        #expect(parsed.complete && parsed.facts.count == 4 && parsed.observedFailure)
        #expect(parsed.facts.map(\.attempt) == [1, 2, 1, 2])
        #expect(Set(parsed.facts.compactMap(\.configurationID)) == ["A", "B"])
    }
    @Test func persistedFactsSurviveWithoutTheOriginalBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BuildResultStore(root: root), id = UUID()
        var result = BuildResult(); result.executions = TestIdentityParser.parse(try fixture("swift-testing")).facts
        try store.save(result, id: id)
        #expect(try store.load(id)?.executions?.count == 4)
    }
    @Test func argumentCaseIdentitySurvivesNestedRetryIdentifiers() {
        let url = "test://com.apple.xcode/Fixture/Tests/Suite/check(value:)?args=opaque"
        let nodes: [[String: Any]] = [["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/check(value:)", "children": [["nodeType": "Arguments", "nodeIdentifierURL": url, "result": "Passed", "children": [["nodeType": "Test Case Run", "nodeIdentifier": "attempt-one", "result": "Failed"], ["nodeType": "Test Case Run", "nodeIdentifier": "attempt-two", "result": "Passed"]]]]]]
        let parsed = TestIdentityParser.parse(nodes)
        #expect(parsed.complete && parsed.facts.map(\.caseID) == [url, url])
        #expect(parsed.facts.map(\.attempt) == [1, 2] && parsed.observedFailure)
    }
    @Test func expectedCaseCannotBeBorrowedFromAnotherConfiguration() {
        let nodes: [[String: Any]] = ["A", "B"].map { configuration in
            ["nodeType": "Configuration", "nodeIdentifier": configuration, "children": [["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/test()", "result": "Passed", "children": (configuration == "A" ? ["one", "two"] : ["one"]).map { ["nodeType": "Test Case Run", "nodeIdentifier": $0, "result": "Passed"] }]]]
        }
        var value = record(["Tests/Suite/test()"]); value.requestedTestCases = ["Tests/Suite/test()": ["one", "two"]]
        let result = TestVerificationReader.verify(record: value, nodes: nodes, summary: .init(total: 2, passed: 2, failed: 0, skipped: 0, expectedFailures: 0), detailsComplete: true)
        #expect(result.verdict == "incomplete" && result.unmatchedCases["Tests/Suite/test()"] == ["two"])
    }
}
