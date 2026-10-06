//
//  AIProcessTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 02.10.2026.
import Darwin
import Foundation
import Testing
@testable import MimicCore

@Suite(.serialized)
struct AIProcessTests {
    private func fixture(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AI-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("cli.py")
        try ("#!/usr/bin/python3\n# Created by Василий Маслов on 02.10.2026.\n" + source).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    @MainActor
    private func run(file: URL, input: String = "", timeout: TimeInterval = 3, limit: Int = 1024 * 1024) async throws -> AIProcessOutput {
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
        let runner = AIProcessRunner(helper: helper, timeLimit: timeout, outputLimit: limit)
        return try await AICLIInspector.invoke(runner: runner, executable: file.path, arguments: ["fixed-argument"], input: Data(input.utf8))
    }

    @Test @MainActor
    func stdinAndBothStreamsWithoutPTYOrFiles() async throws {
        let file = try self.fixture("import os, sys, json\nprompt=sys.stdin.read()\nprint(json.dumps({'stdin':prompt, 'args':sys.argv[1:], 'tty':os.isatty(0), 'files':os.listdir('.')}))\nprint('diagnostic stderr', file=sys.stderr)\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let output = try await self.run(file: file, input: "synthetic diagnostic")
        let value = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        #expect(value["stdin"] as? String == "synthetic diagnostic"); #expect(value["args"] as? [String] == ["fixed-argument"])
        #expect(value["tty"] as? Bool == false); #expect(value["files"] as? [String] == [])
        #expect(String(decoding: output.stderr, as: UTF8.self).contains("diagnostic stderr")); #expect(output.exitCode == 0)
    }

    @Test @MainActor
    func outputLimitAndTimeout() async throws {
        let large = try self.fixture("import sys\nsys.stdin.read()\nprint('x'*100000)\n")
        let slow = try self.fixture("import time\ntime.sleep(20)\n")
        defer { try? FileManager.default.removeItem(at: large.deletingLastPathComponent()); try? FileManager.default.removeItem(at: slow.deletingLastPathComponent()) }
        await #expect(throws: AIError.outputLimit) { try await self.run(file: large, limit: 100) }
        await #expect(throws: AIError.timeout) { try await self.run(file: slow, timeout: 0.2) }
    }

    @Test @MainActor
    func cancelStopsOwnChildAndDoesNotReturnPartialSuccess() async throws {
        let file = try self.fixture("import subprocess, os, time\nchild=subprocess.Popen(['/bin/sleep','20'])\nopen(os.path.join(os.path.dirname(__file__),'child.pid'),'w').write(str(child.pid))\ntime.sleep(20)\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["20"]
        try unrelated.run(); defer { if unrelated.isRunning { unrelated.terminate() } }
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
        let runner = AIProcessRunner(helper: helper, timeLimit: 10)
        defer { runner.cancel() }
        let operation = Task { @MainActor in try await AICLIInspector.invoke(runner: runner, executable: file.path, arguments: [], input: Data()) }
        let pidFile = file.deletingLastPathComponent().appendingPathComponent("child.pid")
        for _ in 0 ..< 400 {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8), Int32(value) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        runner.cancel()
        await #expect(throws: AIError.cancelled) { try await operation.value }
        for _ in 0 ..< 100 {
            if kill(pid, 0) != 0 { break }; try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) == -1); #expect(unrelated.isRunning)
        // Reuse exercises request identity: queued EOF/events from cancellation cannot finish this run.
        let next = try self.fixture("import sys\nprint(sys.stdin.read())\n")
        defer { try? FileManager.default.removeItem(at: next.deletingLastPathComponent()) }
        let output = try await AICLIInspector.invoke(runner: runner, executable: next.path, arguments: [], input: Data("second request".utf8))
        #expect(String(decoding: output.stdout, as: UTF8.self) == "second request\n")
    }
}

extension AIProcessTests {
    @Test @MainActor
    func startupOutputCannotBlockLargeStdin() async throws {
        let file = try self.fixture("import sys\nsys.stdout.write('x'*200000); sys.stdout.flush()\nprompt=sys.stdin.read()\nprint(len(prompt))\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let output = try await self.run(file: file, input: String(repeating: "я", count: 50000), timeout: 5)
        #expect(String(decoding: output.stdout.suffix(6), as: UTF8.self) == "50000\n")
    }
}

extension AIProcessTests {
    @Test(arguments: AIProvider.allCases)
    @MainActor
    func bothAdaptersUseExactRestrictedArgvAndStdin(_ provider: AIProvider) async throws {
        let disabled = ["shell_tool", "unified_exec", "shell_snapshot", "hooks", "apps", "plugins", "remote_plugin", "multi_agent", "memories", "skill_search", "skill_mcp_dependency_install", "browser_use", "computer_use", "image_generation", "view_image", "workspace_dependencies", "code_mode_host", "tool_suggest", "daemon_auto_start"]
        var codex = ["exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never", "--enable", "skip_host_skill_discovery"]
        for feature in disabled {
            codex += ["--disable", feature]
        }
        for config in ["approval_policy=\"never\"", "web_search=\"disabled\"", "tools.view_image=false", "mcp_servers={}", "project_doc_max_bytes=0", "suppress_unstable_features_warning=true", "feedback.enabled=false", "analytics.enabled=false"] { codex += ["--config", config] }
        codex += ["--model", "fixture-model", "-"]
        let claude = ["-p", "--bare", "--restricted", "--tools", "", "--disallowedTools", "*", "--no-session-persistence", "--output-format", "json", "--permission-mode", "dontAsk", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--model", "fixture-model"]
        let expected = try JSONSerialization.data(withJSONObject: provider == .codex ? codex : claude).base64EncodedString()
        let output = provider == .codex ? "print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':'fixture reason'}})); print(json.dumps({'type':'turn.completed'}))" : "print(json.dumps({'type':'result','subtype':'success','is_error':False,'result':'fixture reason'}))"
        let file = try self.fixture("""
            import os, sys, json, base64
            expected=json.loads(base64.b64decode('\(expected)'))
            assert sys.argv[1:]==expected
            assert os.listdir('.')==[] and not os.isatty(0)
            assert 'GITLAB_TOKEN' not in os.environ
            prompt=sys.stdin.read()
            assert '1: diagnostic-fixture-marker' in prompt and 'SHA: original-sha' in prompt
            assert 'diagnostic-fixture-marker' not in str(sys.argv)
            \(output)
            """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/TaskHost")
        let runner = AIProcessRunner(helper: helper)
        let record = TaskRecord(action: .format, project: ProjectContext(path: "/original-checkout", branch: "original", commit: "original-sha"))
        let prompt = DiagnosticSnapshot(record: record, output: "diagnostic-fixture-marker").prompt(fragment: "diagnostic-fixture-marker", comment: "")
        let adapter = AIProviderAdapters.make(provider)
        let result = try await AICLIInspector.invoke(runner: runner, executable: file.path, arguments: adapter.arguments(model: "fixture-model"), input: Data(prompt.utf8))
        #expect(result.exitCode == 0); #expect(try adapter.response(stdout: result.stdout) == "fixture reason")
        for file in try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            let text = try String(decoding: Data(contentsOf: file), as: UTF8.self)
            // The fixture source itself contains the marker, never the actual diagnostic prompt.
            #expect(!text.contains("Разбери локальную ошибку Mimic"))
        }
    }
}
