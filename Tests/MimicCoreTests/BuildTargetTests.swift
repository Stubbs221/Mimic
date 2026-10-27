//
//  BuildTargetTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 23.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct BuildTargetTests {
    @Test func readsDefaultPlanFirstWithoutEnumeratingAndRejectsEscapingPlan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let schemes = root.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        let scheme = schemes.appendingPathComponent("App.xcscheme")
        try Data(#"<Scheme><TestAction><TestPlans><TestPlanReference reference="container:Other.xctestplan"/><TestPlanReference reference="container:Main.xctestplan" default="YES"/></TestPlans></TestAction></Scheme>"#.utf8).write(to: scheme)
        try Data(#"{"testTargets":[{"target":{"name":"AppTests"}},{"enabled":false,"target":{"name":"Disabled"}},{"target":{"name":"PushTests"}}]}"#.utf8).write(to: root.appendingPathComponent("Main.xctestplan"))
        try Data(#"{"testTargets":[{"target":{"name":"AppTests"}},{"target":{"name":"OtherTests"}}]}"#.utf8).write(to: root.appendingPathComponent("Other.xctestplan"))
        let project = ProjectContext(path: root.path, branch: "main", commit: "one", appleTarget: .init(path: "App.xcodeproj"))
        #expect(try BuildTestTargetReader.read(project: project, scheme: "App") == [.init(name: "AppTests", testPlan: "Main"), .init(name: "PushTests", testPlan: "Main"), .init(name: "OtherTests", testPlan: "Other")])
        try Data(#"<Scheme><TestAction><TestPlans><TestPlanReference reference="container:../Outside.xctestplan"/></TestPlans></TestAction></Scheme>"#.utf8).write(to: scheme)
        #expect(throws: (any Error).self) { try BuildTestTargetReader.read(project: project, scheme: "App") }
        try Data(#"<Scheme><TestAction><Testables><TestableReference><BuildableReference BlueprintName="DirectTests"/></TestableReference><TestableReference skipped="YES"><BuildableReference BlueprintName="Skipped"/></TestableReference></Testables></TestAction></Scheme>"#.utf8).write(to: scheme)
        #expect(try BuildTestTargetReader.read(project: project, scheme: "App") == [.init(name: "DirectTests")])
    }
    @Test func wholeTargetIsExactAndCannotMixWithMethodsOrPublicStrictSelection() throws {
        let project = ProjectContext(path: "/fixture", branch: "main", commit: "one", appleTarget: .init(path: "App.xcodeproj"))
        var parameters = BuildParameters(operation: .test, scheme: "App", destinationID: UUID().uuidString)
        parameters.testTarget = "AppTests"
        let command = try parameters.command(project: project)
        #expect(command.arguments.filter { $0.hasPrefix("-only-testing:") } == ["-only-testing:AppTests"])
        #expect(!command.arguments.contains("-enumerate-tests"))
        var payload = try #require(BridgeValue.encode(parameters).object); payload.removeValue(forKey: "operation")
        #expect(throws: BuildError.arguments) { try BuildBridge.parameters(.object(payload), operation: .test) }
        parameters.testIdentifiers = ["AppTests/Suite/testOne()"]
        #expect(throws: BuildError.arguments) { try parameters.validate() }
        parameters.testIdentifiers = []; parameters.testTarget = "AppTests/*"
        #expect(throws: BuildError.arguments) { try parameters.validate() }
    }
    @Test func targetResultsNeedObservedExecutionAndRejectOtherTargets() {
        let project = ProjectContext(path: "/fixture", branch: "main", commit: "one")
        var parameters = BuildParameters(operation: .test); parameters.testTarget = "AppTests"
        var record = BuildActivity(id: UUID(), project: project, parameters: parameters, source: "fixture")
        record.status = .succeeded; record.exitCode = 0; record.sourceProvenance = .init(admitted: nil); record.sourceProvenance?.stability = "unchangedObserved"
        let nodes: [[String: Any]] = [["nodeType": "Test Case", "nodeIdentifier": "AppTests/Suite/test()", "result": "Passed"]]
        let summary = BuildResult.TestSummary(total: 1, passed: 1, failed: 0, skipped: 0, expectedFailures: 0)
        #expect(TestVerificationReader.verify(record: record, nodes: nodes, summary: summary, detailsComplete: true).verdict == "passed")
        #expect(TestVerificationReader.verify(record: record, nodes: [], summary: .init(total: 0, passed: 0, failed: 0, skipped: 0, expectedFailures: 0), detailsComplete: true).verdict == "incomplete")
        #expect(TestVerificationReader.verify(record: record, nodes: nodes, summary: summary, detailsComplete: false).verdict == "incomplete")
        #expect(TestVerificationReader.verify(record: record, nodes: [["nodeType": "Test Case", "nodeIdentifier": "OtherTests/Suite/test()", "result": "Passed"]], summary: summary, detailsComplete: true).verdict == "failed")
    }
}
