//
//  PTYLifecycleTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import Testing
@testable import MimicCore

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct PTYLifecycleTests {
    @Test func testEndObservationAndExitDoNotCompleteBeforeEOF() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("PTYLifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        try Data("""
        #!/bin/bash
        printf '{"kind":"started","pid":1}\n' >&2
        printf '** TEST SUCCEEDED **\n'
        sleep 0.2
        printf '{"kind":"exit","code":0,"signal":0,"launchError":0}\n' >&2
        sleep 0.2
        printf 'TRAILING OUTPUT\n'
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let session = PTYSession()
        var sawEnd = false, sawExit = false, completed = false, tail = ""
        session.onOutput = { bytes in
            tail += String(decoding: bytes, as: UTF8.self)
            if tail.contains("TEST SUCCEEDED") { sawEnd = true }
        }
        session.onEvent = { event in if event.kind == "exit" { sawExit = true; #expect(session.running && !completed) } }
        session.onCompletion = { event in completed = true; #expect(event?.code == 0 && !session.running) }
        try session.start(helper: helper, command: .init(executable: "/bin/true", arguments: [], directory: root.path, environment: ["PATH": "/usr/bin:/bin"]))
        let deadline = ContinuousClock.now + .seconds(5)
        while !sawEnd && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sawEnd && session.running && !completed)
        while !completed && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sawExit && completed && tail.contains("TRAILING OUTPUT"))
    }
}
