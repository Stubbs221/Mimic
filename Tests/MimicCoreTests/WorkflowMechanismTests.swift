//
//  WorkflowMechanismTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct WorkflowMechanismTests {
    private func selection() -> VerifiedTestSelection {
        VerifiedTestSelection(catalogueID: UUID(), project: .init(path: "/fixture"), parameters: .init(operation: .test, scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"), developer: "/fixture/Developer", profileRevision: nil, revision: .init(rulesRevision: "fixture", digest: "one", fileCount: 0), owner: "chat")
    }
    @Test(arguments: [332, 818]) func largeManifestProducesOneExactResponseFile(count: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TestSelectionStore(root: root)
        var value = selection(); value.state = "draft"
        let ids = (0..<count).map { "Tests/Suite/test\($0)()" }
        for offset in stride(from: 0, to: count, by: 100) {
            let page = Array(ids.dropFirst(offset).prefix(100)), id = UUID()
            try store.append(page, requestID: id, to: &value)
            try store.append(page, requestID: id, to: &value)
        }
        value.state = "finalized"; try store.save(value)
        #expect(try store.load(value.id)?.parameters.testIdentifiers.count == count)
        let record = BuildActivity(project: value.project, parameters: value.parameters, source: "Fixture")
        let command = CommandSpec(executable: "/usr/bin/xcrun", arguments: ["xcodebuild"] + value.parameters.testIdentifiers.map { "-only-testing:" + $0 } + ["test"], directory: root.path, environment: [:])
        let prepared = try TestSelectionCommand.prepare(command, record: record, root: root, supportsResponseFile: true)
        #expect(prepared.arguments.filter { $0 == "test" }.count == 1 && prepared.arguments.filter { $0 == "-only-testing" }.count == 1)
        let path = try #require(prepared.arguments.last).dropFirst()
        #expect(try String(contentsOfFile: String(path), encoding: .utf8).split(separator: "\n").map(String.init) == ids.sorted())
        #expect(throws: BuildError.selectionTooLargeForToolchain) { try TestSelectionCommand.prepare(command, record: record, root: root, supportsResponseFile: false, argumentBudget: 1) }
    }
    @Test func draftMutationExpiryAndRequestConflictAreExplicit() throws {
        let store = TestSelectionStore(root: .init(fileURLWithPath: "/unused")), id = UUID()
        var value = selection(); value.state = "draft"
        try store.append(["Tests/Suite/a()", "Tests/Suite/a()"], requestID: id, to: &value)
        #expect(value.parameters.testIdentifiers == ["Tests/Suite/a()"])
        #expect(throws: BuildError.duplicate) { try store.append(["Tests/Suite/b()"], requestID: id, to: &value) }
        value.state = "finalized"
        #expect(throws: WorkflowFieldError.self) { try store.append(["Tests/Suite/b()"], requestID: UUID(), to: &value) }
        try store.append(["Tests/Suite/a()", "Tests/Suite/a()"], requestID: id, to: &value)
        value.createdAt = Date().addingTimeInterval(-86401)
        #expect(throws: BuildError.selectionExpired) { try store.append(["Tests/Suite/a()"], requestID: UUID(), to: &value) }
    }
    @Test func sharedSchemaValidationNamesTheInvalidField() throws {
        do { try WorkflowContract.validate(["selectionID": .string(UUID().uuidString), "limit": .number(101)], method: "get_test_selection"); Issue.record("accepted invalid limit") }
        catch let error as WorkflowFieldError { #expect(error.field == "limit" && error.limit == 100) }
        #expect(WorkflowContract.rules.keys.sorted() == WorkflowContract.tools.sorted())
        #expect(AgentWorkflow.schemaRevision == 4)
    }
}
