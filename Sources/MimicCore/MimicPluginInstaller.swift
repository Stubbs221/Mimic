//
//  MimicPluginInstaller.swift
//  MimicCore
//
//  Created by Василий Маслов on 04.10.2026.
import Darwin
import Foundation

/// Runs fixed official plugin commands without a shell, credentials or captured CLI output.
public enum MimicPluginInstaller {
    public static func findCodex() -> URL? {
        let homes = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for home in homes {
            for name in ["ChatGPT.app", "Codex.app"] {
                let cli = home.appendingPathComponent(name + "/Contents/Resources/codex-cli/bin/codex")
                if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
            }
        }
        return nil
    }
    public static func check(codex: URL, timeout: TimeInterval = 30) async throws {
        for args in [["plugin", "marketplace", "add", "--help"], ["plugin", "add", "--help"], ["plugin", "remove", "--help"]] {
            try await self.run(codex: codex, arguments: args, timeout: timeout)
        }
    }
    public static func install(marketplace: URL, codex: URL, timeout: TimeInterval = 30) async throws {
        try await self.check(codex: codex, timeout: timeout)
        for args in [["plugin", "marketplace", "add", marketplace.path], ["plugin", "add", "mimic@mimic-desktop"]] {
            try await self.run(codex: codex, arguments: args, timeout: timeout)
        }
    }
    /// Removes only Mimic; the marketplace can contain unrelated plugins and is retained.
    public static func uninstall(codex: URL, timeout: TimeInterval = 30) async throws {
        try await self.run(codex: codex, arguments: ["plugin", "remove", "mimic@mimic-desktop"], timeout: timeout)
    }
    @concurrent private static func run(codex: URL, arguments: [String], timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        let process = Process(); process.executableURL = codex; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
            if process.isRunning { throw MimicBridgeError.timeout }
            guard process.terminationStatus == 0 else { throw MimicBridgeError.unavailable }
        } catch {
            if process.isRunning {
                process.terminate()
                for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            throw error
        }
    }
}
