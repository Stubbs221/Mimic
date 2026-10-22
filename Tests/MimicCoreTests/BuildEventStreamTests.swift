//
//  BuildEventStreamTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 22.10.2026.
import Darwin
import Foundation
import Testing
@testable import MimicCore

struct BuildEventStreamTests {
    private func event(_ name: String, section: Int = 1, action: Int = 0, result: Int = 0, title: String = "Compile ProfileView.swift (arm64)", outcome: String = "succeeded", exit: String = "0", command: Bool = true) throws -> Data {
        func scalar(_ text: String) -> [String: String] { ["_value": text] }
        let payload: [String: Any] = [
            "resultInfo": ["actionIndex": scalar(String(action)), "resultIndex": scalar(String(result))], "sectionIndex": scalar(String(section)),
            "head": ["_type": ["_name": command ? "ActivityLogCommandInvocationSectionHead" : "ActivityLogSectionHead"], "title": scalar(title), "commandDetails": scalar("PRIVATE COMMAND AND ENVIRONMENT MUST NEVER ENTER PROGRESS")],
            "tail": ["result": scalar(outcome), "exitCode": scalar(exit)]
        ]
        var data = try JSONSerialization.data(withJSONObject: ["name": scalar(name), "structuredPayload": payload]); data.append(10); return data
    }

    @Test func splitRecordsTrackOnlySuccessfulCommandsAndCurrentOperation() throws {
        var parser = BuildEventParser()
        let first = try event("logSectionCreated", title: "Компиляция Профиль.swift 🙂")
        for byte in first { parser.append(Data([byte])) }
        #expect(parser.progress.operation == "Компиляция Профиль.swift 🙂")
        #expect(parser.progress.completedOperations == 0)
        parser.append(try event("logSectionCreated", section: 2, title: "Link DemoUI"))
        parser.append(try event("logSectionClosed", section: 2))
        #expect(parser.progress.operation == "Компиляция Профиль.swift 🙂")
        #expect(parser.progress.completedOperations == 1)
        parser.append(try event("logSectionClosed", section: 2))
        parser.append(try event("logSectionClosed", outcome: "failed", exit: "1"))
        parser.append(try event("logSectionClosed", section: 50))
        #expect(parser.progress.operation == nil)
        #expect(parser.progress.completedOperations == 1)
        // Nested action/result indices can legitimately reuse a section number.
        parser.append(try event("logSectionCreated", section: 2, action: 1))
        parser.append(try event("logSectionClosed", section: 2, action: 1))
        #expect(parser.progress.completedOperations == 2)
    }

    @Test func malformedOversizedAndNonCommandRecordsCannotInventWork() throws {
        var parser = BuildEventParser()
        parser.append(Data("invalid JSON\n".utf8))
        parser.append(try event("logSectionCreated", command: false))
        parser.append(try event("logSectionClosed"))
        parser.append(try event("logTextAppended"))
        parser.append(Data(repeating: 65, count: 1024 * 1024 + 100)); parser.append(Data([10]))
        #expect(parser.progress == .init())
        parser.append(try event("logSectionCreated", title: String(repeating: "Объект ", count: 100)))
        #expect((parser.progress.operation?.count ?? 0) <= 240)
        #expect(parser.progress.operation?.contains("PRIVATE COMMAND") == false)
        parser.append(try event("logSectionClosed"))
        #expect(parser.progress.completedOperations == 1)
    }

    @Test func fifoConsumesEventsWithoutPersistingRawOutputAndClosesAfterFinish() async throws {
        let stream = try BuildEventStream(), path = stream.path
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try writer.write(contentsOf: event("logSectionCreated"))
        try writer.write(contentsOf: event("logSectionClosed"))
        try writer.close()
        let snapshot = await stream.finish()
        #expect(snapshot?.completedOperations == 1)
        #expect(stream.snapshot == nil)
        stream.stop()
        for _ in 0..<100 { if !FileManager.default.fileExists(atPath: path) { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func privateInputDiscardsMetadataWhileKeepingTheWriterUsable() async throws {
        let stream = try BuildEventStream(), path = stream.path
        defer { stream.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.size] as? NSNumber)?.intValue == 0)
        var info = stat(); #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFIFO)
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? writer.close() }
        stream.makePrivate()
        // More than the pipe capacity proves that the private stream continues draining.
        let flags = fcntl(writer.fileDescriptor, F_GETFL)
        #expect(fcntl(writer.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0)
        var data = Data(repeating: 88, count: 256 * 1024)
        data.append(try event("logSectionCreated", title: "Private echoed input"))
        var offset = 0
        let deadline = ContinuousClock.now + .seconds(3)
        while offset < data.count {
            try #require(ContinuousClock.now < deadline, "Private channel stopped draining")
            let count = data.withUnsafeBytes { Darwin.write(writer.fileDescriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count > 0 { offset += count }
            else if errno == EAGAIN { try await Task.sleep(for: .milliseconds(2)) }
            else { Issue.record("Unexpected FIFO write error"); break }
        }
        #expect(stream.snapshot == nil)
        #expect(await stream.finish() == nil)
    }

    @Test func onlyThePinnedXcodeCommandReceivesTheStreamFlag() throws {
        let stream = try BuildEventStream(); defer { stream.stop() }
        let command = CommandSpec(executable: "/usr/bin/xcrun", arguments: ["xcodebuild", "-scheme", "Fixture", "-resultBundlePath", "/fixture/Result.xcresult", "build"], directory: "/fixture", environment: ["DEVELOPER_DIR": "/fixture/Developer"])
        let observed = try #require(stream.attaching(to: command))
        #expect(observed.arguments.suffix(2) == ["-resultStreamPath", stream.path])
        #expect(observed.environment == command.environment && observed.directory == command.directory)
        #expect(stream.attaching(to: observed) == nil)
        #expect(stream.attaching(to: .init(executable: "/usr/bin/xcrun", arguments: ["xcodebuild", "test", "-enumerate-tests"], directory: "/fixture", environment: [:])) == nil)
        #expect(stream.attaching(to: .init(executable: "/bin/bash", arguments: ["fixture"], directory: "/fixture", environment: [:])) == nil)
    }

    @Test func largeBlockingWriterCannotStallThePrivateChannel() async throws {
        let stream = try BuildEventStream(); stream.makePrivate()
        defer { stream.stop() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/dd")
        process.arguments = ["if=/dev/zero", "of=" + stream.path, "bs=262144", "count=1"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let stalled = process.isRunning
        if stalled { process.terminate() }
        process.waitUntilExit()
        #expect(!stalled && process.terminationStatus == 0)
        #expect(await stream.finish() == nil)
    }
}
