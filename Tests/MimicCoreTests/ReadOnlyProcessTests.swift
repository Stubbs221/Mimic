//
//  ReadOnlyProcessTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 05.10.2026.
import Darwin
import Foundation
import Testing
@testable import MimicCore

struct ReadOnlyProcessTests {
    @Test func inheritedPipeAndIgnoringTERMRespectAbsoluteDeadline() {
        for script in ["sleep 30 & printf child-pid:%s $!", "trap '' TERM; printf ready; while :; do sleep 1; done"] {
            let start = ContinuousClock.now
            let result = ReadOnlyProcess.capture("/bin/sh", ["-c", script], directory: nil, environment: nil, timeout: 0.15)
            #expect(result.0 == ReadOnlyProcess.timeoutExitCode)
            #expect(start.duration(to: .now) < .seconds(2))
            if let pid = result.1.split(separator: ":").last.flatMap({ Int32($0) }) {
                #expect(terminated(pid))
            }
        }
    }
    private func terminated(_ pid: pid_t) -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            let state = EnvironmentInspector.capture("/bin/ps", ["-o", "stat=", "-p", String(pid)])
            if state.1.hasPrefix("Z") || kill(pid, 0) == -1 && errno == ESRCH { return true }
            var pause = pollfd(fd: -1, events: 0, revents: 0)
            _ = poll(&pause, 1, 10)
        } while ContinuousClock.now < deadline
        return false
    }
    @Test func successfulParentCannotLeaveDetachedStdoutDescendantsRunning() throws {
        let result = ReadOnlyProcess.capture("/bin/sh", ["-c", "sleep 30 </dev/null >/dev/null 2>&1 & printf '%s' $!"], directory: nil, environment: nil)
        #expect(result.0 == 0)
        let pid = try #require(Int32(result.1))
        #expect(terminated(pid))
    }

    @Test func oversizedStdoutFailsAndDoesNotReturnPartialSuccess() {
        let result = ReadOnlyProcess.capture("/usr/bin/yes", ["fixture"], directory: nil, environment: nil, timeout: 2, maximumBytes: 1024)
        #expect(result.0 == -1 && result.1.utf8.count <= 1024)
    }
    @Test func taskCancellationStopsOwnedGroupPromptly() async throws {
        let task = Task.detached {
            ReadOnlyProcess.capture("/bin/sh", ["-c", "trap '' TERM; printf ready; sleep 30"], directory: nil, environment: nil, timeout: 8)
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now; task.cancel()
        let result = await task.value
        #expect(result.0 == -1 && start.duration(to: .now) < .seconds(2))
    }
    @Test func literalArgumentsDirectoryUnicodeAndExitArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicQuery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = EnvironmentInspector.capture("/bin/sh", ["-c", "printf cwd > cwd-marker; printf '%s|%s|%s' \"$PWD\" \"$1\" \"$FIXTURE\"; exit 7", "fixture", "literal $(text) 🙂"], directory: root.path, environment: ["FIXTURE": "Привет"], trim: false)
        #expect(result.0 == 7)
        #expect(result.1.hasSuffix("|literal $(text) 🙂|Привет"))
        #expect(try String(contentsOf: root.appendingPathComponent("cwd-marker"), encoding: .utf8) == "cwd")
    }
}
