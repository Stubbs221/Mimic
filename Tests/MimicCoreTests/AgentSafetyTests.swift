//
//  AgentSafetyTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct AgentSafetyTests {
    private func git(_ root: URL, _ arguments: [String]) throws { try #require(EnvironmentInspector.capture("/usr/bin/git", arguments, directory: root.path).0 == 0) }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSafety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(root, ["init", "-b", "main"])
        try Data("generated/\nignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("one".utf8).write(to: root.appendingPathComponent("Source.swift"))
        try git(root, ["add", "."])
        try git(root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture"])
        return root
    }
    @Test func sourceIdentityTracksContentDeletionModesAndUntrackedWithoutFollowingLinks() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try SourceRevisionReader.capture(path: root.path)
        try Data("two".utf8).write(to: root.appendingPathComponent("Source.swift"))
        let edited = try SourceRevisionReader.capture(path: root.path); #expect(edited != initial)
        try Data("new".utf8).write(to: root.appendingPathComponent("New.swift"))
        let untracked = try SourceRevisionReader.capture(path: root.path); #expect(untracked != edited)
        try Data("cache".utf8).write(to: root.appendingPathComponent("ignored"))
        #expect(try SourceRevisionReader.capture(path: root.path) == untracked)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Source.swift").path)
        #expect(try SourceRevisionReader.capture(path: root.path) != untracked)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/does-not-exist")
        #expect(try SourceRevisionReader.entries(path: root.path).contains { $0.path == "link" && $0.kind == "symlink" })
        try FileManager.default.removeItem(at: root.appendingPathComponent("Source.swift"))
        #expect(try SourceRevisionReader.entries(path: root.path).contains { $0.path == "Source.swift" && $0.kind == "deleted" })
        #expect(throws: BuildError.arguments) { try SourceRevisionReader.capture(path: root.path, exclusions: ["../outside"]) }
    }
    @Test func explicitExclusionsAndProvenanceDoNotInventAnImmutableSnapshot() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try SourceRevisionReader.capture(path: root.path, exclusions: ["New.swift"])
        try Data("generated".utf8).write(to: root.appendingPathComponent("New.swift"))
        #expect(try SourceRevisionReader.capture(path: root.path, exclusions: ["New.swift"]) == a)
        var provenance = SourceProvenance(admitted: a); provenance.started = a; provenance.observe(a)
        #expect(provenance.stability == "unchangedObserved")
        provenance.observe(nil); #expect(provenance.stability == "unknown")
        provenance.observe(try SourceRevisionReader.capture(path: root.path)); #expect(provenance.stability == "changed")
    }
    @Test func exactSelectionRequiresExplicitClassScopeAndOffersRoundTripIdentifiers() throws {
        let parameters = BuildParameters(scheme: "Fixture", destinationID: UUID().uuidString)
        let catalogue = BuildTestCatalogue(project: .init(path: "/fixture"), developerDirectory: "/developer", parameters: parameters, tests: [.init(id: "Tests/Suite/check(value:)", target: "Tests", className: "Suite", name: "check(value:)"), .init(id: "Tests/Suite/plain()", target: "Tests", className: "Suite", name: "plain()")])
        let wrong = try VerifiedTestSelection.expand(["Tests/Suite/plain"], scope: "method", catalogue: catalogue)
        #expect(wrong.unknown.count == 1 && wrong.suggestions["Tests/Suite/plain"]?.contains("Tests/Suite/plain()") == true)
        #expect(try VerifiedTestSelection.expand(["Tests/Suite"], scope: "method", catalogue: catalogue).unknown.count == 1)
        #expect(try VerifiedTestSelection.expand(["Tests/Suite"], scope: "class", catalogue: catalogue).selected.count == 2)
    }
    private func testRecord() -> BuildActivity {
        var record = BuildActivity(project: .init(path: "/fixture"), parameters: .init(operation: .test, scheme: "Fixture", testIdentifiers: ["Tests/Suite/plain()"]), source: "Fixture")
        record.status = .succeeded; record.exitCode = 0
        let revision = SourceRevision(rulesRevision: "rules", digest: "code", fileCount: 1)
        var provenance = SourceProvenance(admitted: revision); provenance.started = revision; provenance.observe(revision); record.sourceProvenance = provenance
        return record
    }
    @Test func exitZeroCannotPassZeroSkippedMissingPartialUnexpectedOrUnstableChecks() {
        let record = testRecord()
        let summary = BuildResult.TestSummary(total: 1, passed: 1, failed: 0, skipped: 0, expectedFailures: 0)
        let passed: [[String: Any]] = [["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/plain()", "result": "Passed"]]
        #expect(TestVerificationReader.verify(record: record, nodes: passed, summary: summary, detailsComplete: true).verdict == "passed")
        #expect(TestVerificationReader.verify(record: record, nodes: [], summary: .init(total: 0, passed: 0, failed: 0, skipped: 0, expectedFailures: 0), detailsComplete: true).verdict == "incomplete")
        #expect(TestVerificationReader.verify(record: record, nodes: nil, summary: nil, detailsComplete: false).verdict == "unavailable")
        #expect(TestVerificationReader.verify(record: record, nodes: [["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/plain()", "result": "Skipped"]], summary: summary, detailsComplete: true).verdict == "incomplete")
        #expect(TestVerificationReader.verify(record: record, nodes: passed, summary: summary, detailsComplete: false).verdict == "incomplete")
        #expect(TestVerificationReader.verify(record: record, nodes: passed + [["nodeType": "Test Case", "nodeIdentifier": "Other/Suite/test", "result": "Passed"]], summary: summary, detailsComplete: true).verdict == "failed")
        var changed = record; changed.sourceProvenance?.stability = "changed"
        #expect(TestVerificationReader.verify(record: changed, nodes: passed, summary: summary, detailsComplete: true).verdict == "incomplete")
    }
    @Test func parameterizedCasesAndRetriesAreCountedSeparatelyAndFailuresWin() {
        let record = testRecord()
        let nodes: [[String: Any]] = [["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/plain()", "result": "Passed", "children": [["nodeType": "Test Case Run", "nodeIdentifier": "case-one", "result": "Failed"], ["nodeType": "Test Case Run", "nodeIdentifier": "case-one", "result": "Passed"], ["nodeType": "Test Case Run", "nodeIdentifier": "case-two", "result": "Passed"]]]]
        let result = TestVerificationReader.verify(record: record, nodes: nodes, summary: .init(total: 2, passed: 2, failed: 0, skipped: 0, expectedFailures: 0), detailsComplete: true)
        #expect(result.methodCount == 1 && result.caseCount == 2 && result.iterationCount == 3 && result.verdict == "failed")
    }
    @Test func managedArtifactIdentityRejectsForeignSymlinksAndDetectsChanges() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("artifact.log")
        try Data("one".utf8).write(to: file); let before = try ManagedArtifactReader.inspect(file, root: root)
        try Data("two".utf8).write(to: file); #expect(try ManagedArtifactReader.inspect(file, root: root) != before)
        let link = root.appendingPathComponent("foreign"); try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
        #expect(throws: BuildError.arguments) { try ManagedArtifactReader.inspect(link, root: root) }
        #expect(throws: BuildError.arguments) { try ManagedArtifactReader.inspect(file, root: root.appendingPathComponent("other")) }
    }
    @Test func statusChangesAreObservationsAndPreparationOnlyHashesDeclaredInputs() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try GitActivitySnapshot.capture(path: root.path)
        let requirement = PreparationRequirement(actionID: "prepare", platforms: [.ios], parameters: ["full": "true"], inputs: [".gitignore"], required: true)
        let input = try requirement.inputDigest(path: root.path)
        try Data("two".utf8).write(to: root.appendingPathComponent("Source.swift"))
        #expect(try requirement.inputDigest(path: root.path) == input)
        let changes = before.changes(after: try GitActivitySnapshot.capture(path: root.path))
        #expect(changes.observed.count == 1 && changes.observed[0].origin == "observedDuringOperation")
        #expect(AgentWorkflow.delivery(nil)["compatibility"] == .string("unknown"))
        #expect(AgentWorkflow.delivery(.init(version: "old", build: "1", toolSchemaRevision: 1))["nextStep"]["code"] == .string("reconnectPlugin"))
    }
    @Test func catalogueKeepsStructuredParameterizedMethodAndAllCaseIDs() throws {
        let data = Data(#"{"testNodes":[{"nodeType":"Test Case","nodeIdentifier":"Tests/Suite/check(value:label:)","children":[{"nodeType":"Test Case Run","nodeIdentifier":"case[0]"},{"nodeType":"Test Case Run","nodeIdentifier":"case[1]"}]}]}"#.utf8)
        let catalogue = try BuildTestCatalogue.parse(data)
        #expect(catalogue.count == 1 && catalogue[0].id == "Tests/Suite/check(value:label:)")
        #expect(catalogue[0].caseIdentifiers == ["case[0]", "case[1]"])
    }
    @Test func verdictIsComputedBeforeTruncationAndKnownSummaryFailureWins() {
        let record = testRecord()
        let nodes: [[String: Any]] = (0..<201).map { ["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/test\($0)()", "result": "Passed"] } + [["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/plain()", "result": "Failed"]]
        let result = TestVerificationReader.verify(record: record, nodes: nodes, summary: .init(total: 202, passed: 201, failed: 1, skipped: 0, expectedFailures: 0), detailsComplete: true)
        #expect(result.verdict == "failed" && result.responseTruncated && result.methodCount == 202 && result.executed.count == 200 && result.extractionComplete)
        #expect(TestVerificationReader.verify(record: record, nodes: nil, summary: .init(total: 1, passed: 0, failed: 1, skipped: 0, expectedFailures: 0), detailsComplete: false).verdict == "failed")
        #expect(throws: BuildError.sourceUnavailable) { try SourceRevisionReader.capture(path: "/does-not-exist") }
    }

    @Test func malformedEnumerationAndMissingCaseResultsCannotClaimCompleteness() throws {
        #expect(throws: BuildError.catalogueResponse) { try BuildTestCatalogue.parse(Data(#"{"values":["Tests/Suite/plain()","invalid"]}"#.utf8)) }
        let record = testRecord(), summary = BuildResult.TestSummary(total: 1, passed: 1, failed: 0, skipped: 0, expectedFailures: 0)
        let nodes: [[String: Any]] = [["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/plain()", "result": "Passed", "children": [["nodeType": "Test Case Run", "nodeIdentifier": "case[0]"]]]]
        let result = TestVerificationReader.verify(record: record, nodes: nodes, summary: summary, detailsComplete: true)
        #expect(result.verdict == "incomplete" && !result.extractionComplete)
    }

    @Test func enumeratedParameterizedCasesMustAllExecuteEvenWithSuccessfulPartialSummary() {
        var record = testRecord(); record.requestedTestCases = ["Tests/Suite/plain()": ["case[0]", "case[1]"]]
        let nodes: [[String: Any]] = [["nodeType": "Test Case", "nodeIdentifier": "Tests/Suite/plain()", "result": "Passed", "children": [["nodeType": "Test Case Run", "nodeIdentifier": "case[0]", "result": "Passed"]]]]
        let result = TestVerificationReader.verify(record: record, nodes: nodes, summary: .init(total: 1, passed: 1, failed: 0, skipped: 0, expectedFailures: 0), detailsComplete: true)
        #expect(result.verdict == "incomplete" && result.unmatchedCases["Tests/Suite/plain()"] == ["case[1]"])
    }

}
