//
//  PTYInputBudgetTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 12.10.2026.
import Darwin
import Foundation
import Testing
@testable import MimicCore

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct PTYInputBudgetTests {
    private func pipeWriter() throws -> (Pipe, PTYInputWriter) {
        let pipe = Pipe()
        let writer = try PTYInputWriter(fileDescriptor: pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw POSIXError(.EIO) }
        return (pipe, writer)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(condition(), "PTY fixture deadline exceeded")
    }

    @Test func byteBudgetIncludesPartiallyWrittenFrameAndResizeIsCoalesced() async throws {
        let (pipe, writer) = try self.pipeWriter()
        defer { writer.stop(); try? pipe.fileHandleForReading.close() }
        let payload = Data(repeating: 65, count: 1024 * 1024 - 5)
        for _ in 0..<4 { #expect(writer.enqueue(payload)) }
        #expect(writer.pending.bytes == PTYInputWriter.byteBudget)
        #expect(!writer.enqueue(Data([66])))
        #expect(!writer.enqueue(Data(repeating: 67, count: 1024 * 1024 + 1)))
        for _ in 0..<5000 { writer.resize(Data([0, 91, 0, 27])) }
        #expect(writer.pending.resizes == 1)
        #expect(writer.pending.bytes == PTYInputWriter.byteBudget)
        writer.stop()
        #expect(writer.pending.bytes == 0 && writer.pending.frames == 0 && writer.pending.resizes == 0)
        #expect(!writer.enqueue(Data([68])))
    }

    @Test func slowReaderGetsEveryAcceptedFrameInOrderAndAdmissionRecovers() async throws {
        let (pipe, writer) = try self.pipeWriter()
        defer { writer.stop(); try? pipe.fileHandleForReading.close() }
        var expected = Data(), refused = 0
        for index in 0..<5000 {
            let payload = Data(repeating: UInt8(index % 251), count: 8192)
            if writer.enqueue(payload) {
                expected.append(contentsOf: [1, 0, 0, 32, 0]); expected.append(payload)
            } else { refused += 1 }
            #expect(writer.pending.bytes <= PTYInputWriter.byteBudget)
            #expect(writer.pending.frames <= PTYInputWriter.frameBudget)
        }
        #expect(refused > 0)
        let fd = pipe.fileHandleForReading.fileDescriptor
        var received = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while received.count < expected.count, ContinuousClock.now < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count > 0 { received.append(contentsOf: buffer.prefix(count)) }
            else { #expect(count < 0 && (errno == EAGAIN || errno == EINTR)) }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(received == expected)
        try await self.waitUntil { writer.pending.bytes == 0 }
        // A drained/suspended source must resume, and its final resize must remain intact.
        writer.resize(Data([0, 100, 0, 30]))
        #expect(writer.enqueue(Data([99])))
        let tail = Data([2, 0, 0, 0, 4, 0, 100, 0, 30, 1, 0, 0, 0, 1, 99])
        received.removeAll()
        while received.count < tail.count, ContinuousClock.now < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count > 0 { received.append(contentsOf: buffer.prefix(count)) }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(received == tail)
        writer.stop()
        try await self.waitUntil {
            buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) } == 0
        }
    }

    @Test func closedReaderRejectsFurtherInputWithoutSIGPIPE() async throws {
        let (pipe, writer) = try self.pipeWriter()
        defer { writer.stop() }
        try pipe.fileHandleForReading.close()
        #expect(writer.enqueue(Data([65])))
        try await self.waitUntil { writer.pending.bytes == 0 }
        #expect(!writer.enqueue(Data([66])))
    }

    private func helper() -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
    }

    @Test func actualPTYSlowConsumerReceivesAcceptedInputAndResumesAfterFullQueue() async throws {
        let session = PTYSession()
        defer { session.cancel() }
        // Synthetic input only; acknowledgements report sequence/size, never echo payloads.
        let script = """
        import sys,time
        print('READY',flush=True)
        for index in range(768):
            line=sys.stdin.buffer.readline()
            if line != bytes([65+index%26])*8191+b'\\n': sys.exit(7)
            print('ACK:'+str(index),flush=True)
            time.sleep(.002)
        print('DONE',flush=True)
        """
        let command = CommandSpec(executable: "/bin/bash", arguments: ["-c", "stty -echo -icanon; exec \"$@\"", "fixture", "/usr/bin/python3", "-u", "-c", script], directory: "/private/tmp", environment: ["PATH": "/usr/bin:/bin"])
        var output = Data(), completed = false, event: HostEvent?
        session.onOutput = { output.append($0) }
        session.onCompletion = { event = $0; completed = true }
        try session.start(helper: self.helper(), command: command)
        try await self.waitUntil { String(decoding: output, as: UTF8.self).contains("READY") }
        var refused = 0
        for index in 0..<768 {
            let payload = Data(repeating: UInt8(65 + index % 26), count: 8191) + Data([10])
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !session.send(payload), ContinuousClock.now < deadline {
                refused += 1
                #expect(session.running)
                try await Task.sleep(for: .milliseconds(2))
            }
            try #require(ContinuousClock.now < deadline)
            #expect(session.pendingInputBytes <= PTYSession.maximumQueuedInputBytes)
            #expect(session.pendingInputFrames <= PTYInputWriter.frameBudget)
        }
        try await self.waitUntil { completed }
        let acknowledgements = String(decoding: output, as: UTF8.self).components(separatedBy: .newlines).filter { $0.hasPrefix("ACK:") }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(acknowledgements == (0..<768).map { "ACK:\($0)" })
        #expect(refused > 0 && event?.code == 0 && event?.cancelled == false)
        #expect(session.pendingInputBytes == 0 && !session.send(Data([65])))
        session.onOutput = nil; session.onCompletion = nil
    }

    @Test func cancellationAndEOFClearFullQueueAndStopOwnChild() async throws {
        for disconnect in [false, true] {
            let session = PTYSession()
            defer { session.cancel() }
            let command = CommandSpec(executable: "/bin/bash", arguments: ["-c", "stty -echo -icanon; printf READY; exec /bin/sleep 90"], directory: "/private/tmp", environment: ["PATH": "/usr/bin:/bin"])
            var ready = false, completed = false, child: Int32?, event: HostEvent?
            session.onOutput = { ready = ready || String(decoding: $0, as: UTF8.self).contains("READY") }
            session.onEvent = { if $0.kind == "started" { child = $0.pid.map(Int32.init) } }
            session.onCompletion = { event = $0; completed = true }
            try session.start(helper: self.helper(), command: command)
            try await self.waitUntil { ready && child != nil }
            let payload = Data(repeating: 65, count: 8192)
            var refused = 0
            for _ in 0..<5000 {
                if !session.send(payload) { refused += 1 }
                session.resize(columns: 100, rows: 30)
                #expect(session.pendingInputBytes <= PTYSession.maximumQueuedInputBytes)
            }
            #expect(refused > 0)
            let start = ContinuousClock.now
            if disconnect { session.disconnect() } else { session.cancel() }
            #expect(session.pendingInputBytes == 0 && !session.send(payload))
            try await self.waitUntil { completed }
            #expect(start.duration(to: .now) < .seconds(5))
            #expect(event?.cancelled == true && !session.running)
            if let child { #expect(kill(child, 0) != 0 && errno == ESRCH) }
            session.onOutput = nil; session.onEvent = nil; session.onCompletion = nil
        }
    }

    @Test func cancellationBeforeStartedEventStillStopsHelper() async throws {
        let session = PTYSession()
        defer { session.cancel() }
        var completed = false, event: HostEvent?, child: Int32?
        session.onEvent = { if $0.kind == "started" { child = $0.pid.map(Int32.init) } }
        session.onCompletion = { event = $0; completed = true }
        let command = CommandSpec(executable: "/bin/sleep", arguments: ["90"], directory: "/private/tmp", environment: ["PATH": "/usr/bin:/bin"])
        try session.start(helper: self.helper(), command: command)
        session.cancel()
        #expect(!session.send(Data([65])))
        let start = ContinuousClock.now
        try await self.waitUntil { completed }
        #expect(start.duration(to: .now) < .seconds(5))
        #expect(event?.cancelled == true && session.pendingInputBytes == 0)
        if let child { #expect(kill(child, 0) != 0 && errno == ESRCH) }
        session.onEvent = nil; session.onCompletion = nil
    }
}
