//
//  TestArtifactTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 28.10.2026.
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MimicCore

struct TestArtifactTests {
    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let bytes = NSMutableData(), image = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil); try #require(CGImageDestinationFinalize(writer)); return bytes as Data
    }
    private func record(root: URL) throws -> BuildActivity {
        var record = BuildActivity(project: .init(path: "/fixture", commit: "one"), parameters: .init(operation: .test), source: "Fixture")
        record.status = .failed; record.exitCode = 65; record.selectedDeveloperDirectory = "/fixture/Developer"
        record.resultBundlePath = root.appendingPathComponent(record.id.uuidString + ".xcresult").path
        try FileManager.default.createDirectory(atPath: record.resultBundlePath!, withIntermediateDirectories: true)
        return record
    }
    @Test func attachmentsAreImmutableActivityScopedAndHaveVerifiedDigest() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("TestArtifacts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try record(root: root), second = try record(root: root), image = try png(), store = TestArtifactStore(root: root)
        let facts = [TestExecutionFact(method: "Tests/Suite/test()", caseID: "Tests/Suite/test()", status: "Failed", duration: nil, identifierURL: nil, configurationID: nil, deviceID: nil, attempt: 1)]
        let export: TestArtifactStore.Export = { args, env in
            #expect(env["DEVELOPER_DIR"] == "/fixture/Developer" && args.contains("--test-id"))
            let path = URL(fileURLWithPath: args[args.firstIndex(of: "--output-path")! + 1])
            do {
                try image.write(to: path.appendingPathComponent("fixture.png"))
                try Data(#"[{"testIdentifier":"Tests/Suite/test()","attachments":[{"exportedFileName":"fixture.png","suggestedHumanReadableName":"actual","isAssociatedWithFailure":true,"configurationName":"Fixture","deviceName":"Phone","deviceId":"fixture"}]}]"#.utf8).write(to: path.appendingPathComponent("manifest.json"))
                return (0, "")
            } catch { return (1, "") }
        }
        let a = try #require(store.list(record: first, methodID: facts[0].method, facts: facts, export: export).items.first)
        let b = try #require(store.list(record: second, methodID: facts[0].method, facts: facts, export: export).items.first)
        #expect(a.id != b.id && a.originalPath != b.originalPath && a.digest == b.digest)
        #expect(a.role == "unknown" && a.width == 2 && a.height == 2)
        #expect(try store.artifact(a.id).activityID == first.id)
        #expect(try store.original(a) == image && store.preview(a).count <= 400 * 1024)
        let repeated = try store.list(record: first, methodID: facts[0].method, facts: facts, export: { _, _ in Issue.record("immutable export repeated"); return (1, "") })
        #expect(repeated.items.first?.id == a.id)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: a.originalPath))
        #expect(throws: BuildError.sourceChanged) { try store.original(a) }
    }
    @Test func missingAttachmentsRemainUnavailableAndNeverReadGeneralTemporaryFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try record(root: root), store = TestArtifactStore(root: root)
        #expect(try store.list(record: value, methodID: "Tests/Suite/test()", facts: []).reason == "methodNotObserved")
        let facts = [TestExecutionFact(method: "Tests/Suite/test()", caseID: "one", status: "Failed", duration: nil, identifierURL: nil, configurationID: nil, deviceID: nil, attempt: 1)]
        let result = try store.list(record: value, methodID: facts[0].method, facts: facts, export: { _, _ in (1, "") })
        #expect(result.availability == "unavailable" && result.reason == "attachmentExportUnavailable")
    }
}
