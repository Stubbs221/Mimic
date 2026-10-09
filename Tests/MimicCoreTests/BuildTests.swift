// Created by Василий Маслов on 04.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct BuildTests {
    let destination = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    @Test func buildArgumentsAreLiteralAndTestsCannotBroaden() throws {
        let project = ProjectContext(path: "/private/tmp/Project ' with spaces", branch: "local", commit: "abc", developerDirectory: "/fixture/Xcode.app/Contents/Developer", appleTarget: AppleTarget(path: "App/App.xcodeproj"))
        var parameters = BuildParameters(scheme: "Scheme $(literal)", destinationID: destination)
        let command = try parameters.command(project: project)
        #expect(command.executable == "/usr/bin/xcrun")
        #expect(command.arguments.contains("Scheme $(literal)"))
        #expect(command.arguments.contains("-hideShellScriptEnvironment"))
        #expect(command.arguments.last == "build")
        #expect(command.environment["DEVELOPER_DIR"] == project.developerDirectory)
        let buildWithResult = try parameters.command(project: project, resultBundlePath: "/private/tmp/build-result.xcresult")
        #expect(buildWithResult.arguments.contains("-resultBundlePath") && buildWithResult.arguments.last == "build")
        parameters.operation = .test
        #expect(throws: BuildError.testsRequired) { try parameters.validate() }
        for invalid in ["Target", "Target/*", "Target/Class/", "Target/Class/method/extra"] {
            parameters.testIdentifiers = [invalid]; #expect(throws: BuildError.testsRequired) { try parameters.validate() }
        }
        parameters.testIdentifiers = ["Tests/Class/testMethod", "Tests/OtherClass"]
        let tests = try parameters.command(project: project, resultBundlePath: "/private/tmp/result.xcresult")
        #expect(tests.arguments.filter { $0.hasPrefix("-only-testing:") } == ["-only-testing:Tests/Class/testMethod", "-only-testing:Tests/OtherClass"])
        #expect(tests.arguments.contains("-resultBundlePath")); #expect(tests.arguments.last == "test")
    }
    @Test func destinationsKeepAppleSimulatorsAndRejectIneligibleDevices() {
        let text = """
        Available destinations:
        { platform:iOS Simulator, arch:arm64, id:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA, OS:26.5, name:iPhone 17 }
        { platform:iOS Simulator, arch:x86_64, id:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA, OS:26.5, name:iPhone 17 }
        { platform:tvOS Simulator, id:BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB, name:Apple TV }
        Ineligible destinations:
        { platform:iOS Simulator, id:CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC, name:Missing Runtime }
        """
        #expect(BuildCatalogue.destinations(from: text) == [.init(id: destination, name: "iPhone 17 · iOS 26.5", platform: .ios), .init(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", name: "Apple TV", platform: .tvos)])
    }
    @Test func streamRedactsAcrossChunksAndPreservesValidUnicodeAndColour() {
        var output = BuildOutput()
        #expect(output.append(Data("TOKEN=glpat-fixture".utf8)).isEmpty)
        let emitted = output.append(Data("-secret\n\u{1B}[32mПривет\u{1B}[0m\n-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----\n".utf8))
        let text = String(decoding: emitted, as: UTF8.self)
        #expect(!text.contains("fixture-secret")); #expect(!text.contains("\nfixture\n"))
        #expect(text.contains("\u{1B}[32mПривет"))
        let unicode = Array("🙂\n".utf8); _ = output.append(Data(unicode.prefix(2))); #expect(output.append(Data(unicode.dropFirst(2))).count > 0)
        #expect(!output.read(after: 0).text.contains("�"))
    }
    @Test func outputLimitsKeepReadingAndCursorsReportGaps() {
        var output = BuildOutput()
        for _ in 0..<600 { _ = output.append(Data((String(repeating: "Compile /fixture/File.swift ", count: 40) + "\n").utf8)) }
        #expect(output.bytes.count <= 512 * 1024); #expect(output.truncated)
        let first = output.read(after: 0, limit: 1000); #expect(first.gap); #expect(first.text.utf8.count <= 1000)
        let second = output.read(after: first.nextCursor, limit: 1000); #expect(!second.gap); #expect(second.nextCursor > first.nextCursor)
        _ = output.append(Data(repeating: 65, count: 70 * 1024)); _ = output.append(Data("\nTAIL\n".utf8))
        #expect(output.lastLines.last == "TAIL"); #expect(output.lastLines.contains("[TRUNCATED OUTPUT LINE]"))
    }
    @Test func cachedTailAndPhaseKeepSanitizedUnicodeAcrossChunks() {
        var output = BuildOutput()
        let line = String(repeating: "source/File.swift ", count: 50) + "\n"
        _ = output.append(Data(String(repeating: line, count: 700).utf8))
        #expect(output.bytes.count == 512 * 1024)
        _ = output.append(Data("\u{1B}[32mSwiftCompile Привет🙂\u{1B}[0m\nTOKEN=split-".utf8))
        #expect(output.phase == "compile")
        #expect(output.lastLines.last == "SwiftCompile Привет🙂")
        _ = output.append(Data("secret\nLd /fixture/App\nTest Case 'fixture' passed\n".utf8))
        #expect(output.phase == "test")
        #expect(output.lastLines.contains("TOKEN=[REDACTED]"))
        let tail = output.lastLines
        for _ in 0..<1000 { #expect(output.lastLines == tail) }
        let slice = output.read(after: output.cursor - 150, limit: 149)
        #expect(!slice.text.contains("split-secret") && !slice.text.contains("�"))
        #expect(!output.lastLines.joined().contains("\u{1B}"))
    }
    @Test func outputWorkerOrdersDiskWritesAndFinalPartialLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicOutput-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("fixture.log"), worker = BuildOutputWorker()
        try await worker.open(path)
        for index in 0..<12 {
            let batch = await worker.append(Data("line-\(index)🙂\n".utf8))
            #expect(batch.output.lastLines.last == "line-\(index)🙂")
        }
        _ = await worker.append(Data("PASSWORD=split".utf8))
        let last = await worker.append(Data("-fixture\nTAIL🙂".utf8), final: true)
        #expect(last.output.lastLines.last == "TAIL🙂")
        #expect(!last.logFailed && !last.logTruncated)
        let disk = try String(contentsOf: path, encoding: .utf8)
        #expect(disk == (0..<12).map { "line-\($0)🙂\n" }.joined() + "PASSWORD=[REDACTED]\nTAIL🙂\n")
    }

    @Test func savedSanitizedTailIgnoresEmptyControlLinesAndKeepsUnicode() {
        let data = Data(((0..<8).map { "line-\($0)🙂\n" }.joined() + String(repeating: "\u{1B}[0m\r\n", count: 100)).utf8)
        #expect(BuildOutput.savedTail(data) == (3..<8).map { "line-\($0)🙂" })
        #expect(BuildOutput.savedTail(Data("final🙂".utf8)) == ["final🙂"])
        #expect(BuildOutput.savedTail(Data()).isEmpty)
    }

    @Test func fullBufferTailBenchmarkReportsCostWithoutTimingGate() {
        var output = BuildOutput()
        let line = String(repeating: "compile source file ", count: 50) + "\n"
        let started = ContinuousClock.now
        _ = output.append(Data(String(repeating: line, count: 530).utf8))
        let append = started.duration(to: .now).components
        #expect(output.bytes.count == 512 * 1024)
        var samples: [Double] = [], count = 0
        for _ in 0..<9 {
            let start = ContinuousClock.now
            let lines = output.lastLines
            count += lines.count
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        #expect(count == 45)
        print("MIMIC_FIX tail_bytes=\(output.bytes.count) median_ms=\(samples.sorted()[4]) max_ms=\(samples.max()!) append_ms=\(Double(append.seconds) * 1000 + Double(append.attoseconds) / 1e15)")
    }

    @Test func historyIsSeparateAndRecoveryNeverRerunsOrClaimsMCPFailed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildHistory-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("history.json"); try Data("legacy untouched".utf8).write(to: legacy)
        let store = BuildHistoryStore(directory: root)
        var cli = BuildActivity(project: .init(path: "/fixture"), parameters: .init(scheme: "App", destinationID: destination), source: "test"); cli.status = .running; cli.startedAt = Date()
        var mcp = BuildActivity(project: cli.project, parameters: .init(backend: .xcodeMCP, configuration: "", workspaceTab: "tab1"), source: "test"); mcp.status = .running; mcp.startedAt = Date()
        try store.save([cli, mcp]); let restored = try store.load()
        #expect(restored.map(\.status) == [.interrupted, .unknown]); #expect(restored.allSatisfy { $0.tracking == .lost })
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy untouched")
    }
    @Test func capturedXcode265SchemasAreSupportedAndChangedSchemasRejected() throws {
        let path = try #require(Bundle.module.url(forResource: "Xcode26_5Tools", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(BridgeValue.self, from: Data(contentsOf: path))
        for tool in fixture["tools"].array ?? [] {
            let name = try #require(tool["name"].string)
            #expect(XcodeBuildProfile.accepts(name: name, input: tool["inputSchema"], output: tool["outputSchema"]) == (name != "GetBuildLog"))
            if name == "BuildProject" { var input = try #require(tool["inputSchema"].object); input["required"] = .array([.string("tabIdentifier"), .string("newRequiredField")]); #expect(!XcodeBuildProfile.accepts(name: name, input: .object(input), output: tool["outputSchema"])) }
        }
    }
    @Test func capturedBoundResultsHaveAuthoritativeSuccess() throws {
        let path = try #require(Bundle.module.url(forResource: "Xcode26_5Results", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(BridgeValue.self, from: Data(contentsOf: path))
        for operation in BuildOperation.allCases {
            #expect(XcodeBuildProfile.status(operation: operation, result: fixture["results"][operation.rawValue], isError: false) == .succeeded)
        }
        #expect(fixture["results"]["test"]["counts"]["total"].integer == 1)
    }
    @Test func sharedFIFOOrdersOldToolsBuildsAndTestsAndHoldsUncertainWork() {
        let context = ProjectContext(path: "/fixture")
        var old = TaskRecord(action: .derivedDataCleanup, project: context)
        var earlier = BuildActivity(project: context, parameters: .init(), source: "fixture", createdAt: old.createdAt.addingTimeInterval(-1))
        let later = BuildActivity(project: context, parameters: .init(operation: .test), source: "fixture", createdAt: old.createdAt.addingTimeInterval(1))
        #expect(QueuePolicy.nextActivity(in: [old], builds: [later, earlier]) == .build(earlier.id))
        earlier.status = .succeeded
        #expect(QueuePolicy.nextActivity(in: [old], builds: [later, earlier]) == .legacy(old.id))
        old.status = .running
        #expect(QueuePolicy.nextActivity(in: [old], builds: [later, earlier]) == nil)
        old.status = .succeeded; earlier.status = .unknown
        #expect(QueuePolicy.nextActivity(in: [old], builds: [later, earlier]) == nil)
        #expect(!earlier.canCancel)
        earlier.queueReleased = true
        #expect(earlier.status == .unknown)
        #expect(QueuePolicy.nextActivity(in: [old], builds: [later, earlier]) == .build(later.id))
    }
    @Test func numericWireIDsKeepOriginalSDKIdentityAndNotifications() throws {
        var identity = XcodeRPCIdentity()
        let request = try identity.outgoing(Data(#"{"jsonrpc":"2.0","id":"sdk-uuid","method":"initialize"}"#.utf8))
        let wire = try JSONDecoder().decode(BridgeValue.self, from: request)
        let id = try #require(wire["id"].integer)
        #expect(id == 1_000_001)
        let reply = try identity.incoming(JSONEncoder().encode(BridgeValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": .object([:])])))
        #expect(try JSONDecoder().decode(BridgeValue.self, from: reply)["id"].string == "sdk-uuid")
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"operation","progress":1}}"#.utf8)
        #expect(try JSONDecoder().decode(BridgeValue.self, from: identity.incoming(notification))["params"]["progressToken"].string == "operation")
        let numbered = Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call"}"#.utf8)
        #expect(try JSONDecoder().decode(BridgeValue.self, from: identity.outgoing(numbered))["id"].integer == 4)
    }
    @Test func nativeResultsNeedAuthoritativeFieldsAndLogsCannotBecomeTools() throws {
        #expect(XcodeBuildProfile.status(operation: .build, result: .object(["buildResult": .string("Build succeeded")]), isError: false) == .succeeded)
        #expect(XcodeBuildProfile.status(operation: .build, result: .object(["buildResult": .string("The project built successfully.")]), isError: false) == .succeeded)
        #expect(XcodeBuildProfile.status(operation: .build, result: .object(["buildResult": .string("The project could not build successfully.")]), isError: false) == .unknown)
        #expect(XcodeBuildProfile.status(operation: .build, result: .object(["buildResult": .string("The project built successfully.")]), isError: true) == .unknown)
        #expect(XcodeBuildProfile.status(operation: .build, result: .object(["text": .string("BUILD SUCCEEDED")]), isError: false) == .unknown)
        #expect(XcodeBuildProfile.status(operation: .test, result: .object(["counts": .object(["total": .number(0), "failed": .number(0), "notRun": .number(0)])]), isError: false) == .unknown)
        #expect(!XcodeBuildProfile.accepts(name: "GetBuildLog", input: .null, output: .null)); #expect(!BuildBridge.tools.contains("get_build_log"))
        #expect(XcodeBuildProfile.windows("* tabIdentifier: tab1, workspacePath: /private/tmp/App with spaces.xcworkspace\n")["tab1"] == "/private/tmp/App with spaces.xcworkspace")
        #expect(throws: BuildError.arguments) { try BuildBridge.parameters(.object(["backend": .string("cli"), "executable": .string("/bin/sh")]), operation: .build) }
    }
}
