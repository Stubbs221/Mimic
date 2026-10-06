//
//  MimicInstanceLockTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 05.10.2026.
import Darwin
import Foundation
import Testing
@testable import MimicCore

struct MimicInstanceLockTests {
    @Test func repeatedAcquisitionAndStaleFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock").path
        var owner = try MimicInstanceLock.acquire(path: path)
        try #require(owner != nil)
        #expect(try MimicInstanceLock.acquire(path: path) == nil)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        withExtendedLifetime(owner) {}
        owner = nil
        #expect(FileManager.default.fileExists(atPath: path))
        let replacement = try #require(try MimicInstanceLock.acquire(path: path))
        #expect(try MimicInstanceLock.acquire(path: path) == nil)
        withExtendedLifetime(replacement) {}
    }

    @Test func invalidPathFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) { try MimicInstanceLock.acquire(path: directory.path) }
    }

    @Test func competingProcessesAndCrashRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock").path
        var contenders: [(Process, Pipe)] = []
        defer {
            for (process, _) in contenders where process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        for _ in 0..<8 {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
            import fcntl, os, sys, time
            fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print('blocked', flush=True)
                sys.exit(0)
            print('owner', flush=True)
            time.sleep(30)
            """, path]
            process.standardOutput = output
            try process.run()
            contenders.append((process, output))
        }
        var owners: [Process] = []
        for (process, output) in contenders {
            let result = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            if result == "owner\n" { owners.append(process) }
            else { #expect(result == "blocked\n") }
        }
        let owner = try #require(owners.first)
        #expect(owners.count == 1)
        #expect(try MimicInstanceLock.acquire(path: path) == nil)
        kill(owner.processIdentifier, SIGKILL)
        owner.waitUntilExit()
        let replacement = try #require(try MimicInstanceLock.acquire(path: path))
        #expect(try MimicInstanceLock.acquire(path: path) == nil)
        withExtendedLifetime(replacement) {}
    }

    @Test func executedHelperDoesNotInheritLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock").path
        var owner = try MimicInstanceLock.acquire(path: path)
        try #require(owner != nil)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        helper.arguments = ["30"]
        try helper.run()
        defer { helper.terminate(); helper.waitUntilExit() }
        withExtendedLifetime(owner) {}
        owner = nil
        #expect(helper.isRunning)
        let replacement = try #require(try MimicInstanceLock.acquire(path: path))
        withExtendedLifetime(replacement) {}
    }
}
