//
//  AIDiagnosticsTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct AIDiagnosticsTests {
    @Test
    func masksKnownCredentialsAndPreservesUsefulError() {
        let synthetic = "Authorization: Bearer synthetic-value\nPASSWORD='synthetic-value'\nhttps://user:synthetic-value@example.test/path?token=synthetic-value\nError: dependency not found"
        let cleaned = DiagnosticText.clean(synthetic)
        #expect(!cleaned.contains("synthetic-value"))
        #expect(cleaned.contains("dependency not found"))
    }

    @Test
    func masksPrivateKeysAndBearerFormats() {
        let text = "-----BEGIN RSA PRIVATE KEY-----\nsynthetic-key\n-----END RSA PRIVATE KEY-----\nglpat-synthetic-token"
        let clean = DiagnosticText.clean(text)
        #expect(!clean.contains("synthetic-key")); #expect(!clean.contains("synthetic-token"))
    }

    @Test
    func removesCSIAndOSCHyperlinks() {
        #expect(DiagnosticText.clean("\u{1B}[31mError\u{1B}[0m\r\n\u{1B}]8;;https://example.test\u{07}link\u{1B}]8;;\u{07}") == "Error\nlink")
        #expect(DiagnosticText.numbered("one\ntwo") == "1: one\n2: two")
    }

    @Test
    func boundedSuffixKeepsUnicodeAndMarksTruncation() {
        let fragment = DiagnosticText.bounded(String(repeating: "я", count: 100), limit: 31)
        #expect(fragment.truncated); #expect(fragment.text.utf8.count <= 31); #expect(!fragment.text.contains("�"))
    }

    @Test
    func snapshotKeepsOriginalContextAndEditedFragment() {
        var record = TaskRecord(action: .bootstrap, project: ProjectContext(path: "/original", branch: "feature/original", commit: "abc"))
        record.status = .failed; record.error = "preflight failed"; record.exitCode = 7
        let snapshot = DiagnosticSnapshot(record: record, output: "old log")
        let prompt = snapshot.prompt(fragment: "edited\nsecond", comment: "extra")
        #expect(prompt.contains("feature/original")); #expect(prompt.contains("SHA: abc")); #expect(prompt.contains("1: edited"))
        #expect(!prompt.contains("old log")); #expect(prompt.contains("preflight failed")); #expect(prompt.contains("extra"))
    }

    @Test
    func secretsAddedByUserAreMaskedAtSendBoundary() {
        let record = TaskRecord(action: .format, project: ProjectContext(path: "/original"))
        let prompt = DiagnosticSnapshot(record: record, output: "").prompt(fragment: "token=synthetic-value", comment: "password=synthetic-value")
        #expect(!prompt.contains("synthetic-value"))
    }

    @Test @MainActor
    func failedBootstrapOnlyAndEightEntryLimit() {
        let memory = DiagnosticMemory()
        var records: [TaskRecord] = []
        for _ in 0 ..< 9 {
            var record = TaskRecord(action: .bootstrap, project: ProjectContext(path: "/fixture")); record.status = .failed; records.append(record)
            memory.capture(record: record, output: Data("token=synthetic-value\nerror".utf8))
        }
        #expect(memory.fragment(id: records[0].id) == nil)
        #expect(memory.fragment(id: records[8].id)?.contains("synthetic-value") == false)
        var success = TaskRecord(action: .bootstrap, project: ProjectContext(path: "/fixture")); success.status = .succeeded
        memory.capture(record: success, output: Data("output".utf8)); #expect(memory.fragment(id: success.id) == nil)
        success.status = .cancelled; memory.capture(record: success, output: Data("output".utf8)); #expect(memory.fragment(id: success.id) == nil)
        memory.retain(ids: [records[8].id]); #expect(memory.fragment(id: records[7].id) == nil)
        memory.clear(); #expect(memory.fragment(id: records[8].id) == nil)
    }
}

struct AIProviderTests {
    @Test
    func restrictiveCodexArgumentsHaveNoDiagnosticOrCheckout() {
        let argv = CodexAIAdapter().arguments(model: "model-name")
        #expect(argv.contains("--ephemeral")); #expect(argv.contains("read-only")); #expect(argv.last == "-")
        #expect(argv.contains("mcp_servers={}")); #expect(argv.contains("web_search=\"disabled\""))
        for name in CodexAIAdapter.disabledFeatures {
            #expect(argv.contains(name))
        }
        #expect(!argv.contains("--add-dir")); #expect(!argv.contains("--output-last-message"))
    }

    @Test
    func restrictiveClaudeArguments() {
        let argv = ClaudeAIAdapter().arguments(model: "")
        #expect(argv.contains("--bare")); #expect(argv.contains("--restricted")); #expect(argv.contains("--no-session-persistence"))
        #expect(argv[argv.firstIndex(of: "--tools")! + 1] == "")
        #expect(argv.contains("{\"mcpServers\":{}}")); #expect(!argv.contains("--model"))
    }

    @Test
    func missingRestrictionsRejectCLI() {
        #expect(throws: AIError.unsupportedCLI) { try CodexAIAdapter().validate(executable: "/fake", outputs: ["1", "--json", "shell_tool"]) }
        #expect(throws: AIError.unsupportedCLI) { try ClaudeAIAdapter().validate(executable: "/fake", outputs: ["1", "--tools"]) }
    }

    @Test
    func codexRequiresCompletedTurnAndRejectsToolItems() throws {
        let adapter = CodexAIAdapter()
        let final = Data("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Root cause\"}}\n{\"type\":\"turn.completed\"}\n".utf8)
        #expect(try adapter.response(stdout: final) == "Root cause")
        #expect(throws: AIError.processFailed) { try adapter.response(stdout: Data("{\"type\":\"thread.started\"}\n".utf8)) }
        #expect(throws: AIError.unexpectedTool) { try adapter.response(stdout: Data("{\"type\":\"item.started\",\"item\":{\"type\":\"command_execution\"}}\n".utf8)) }
        #expect(throws: AIError.invalidJSON) { try adapter.response(stdout: Data("invalid".utf8)) }
    }

    @Test
    func claudeResultAndProviderFailures() throws {
        let adapter = ClaudeAIAdapter()
        #expect(try adapter.response(stdout: Data("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"Reason\"}".utf8)) == "Reason")
        #expect(throws: AIError.rateLimit) { try adapter.response(stdout: Data("{\"type\":\"result\",\"subtype\":\"error\",\"is_error\":true,\"result\":\"rate_limit\"}".utf8)) }
        #expect(throws: AIError.emptyResponse) { try adapter.response(stdout: Data("{\"type\":\"result\",\"subtype\":\"success\",\"result\":\" \"}".utf8)) }
        #expect(AIError.classify("not logged in") == .authentication)
    }

    @Test
    func environmentExcludesUnrelatedCredentials() {
        let env = AIProviderAdapters.environment(base: ["GITLAB_TOKEN": "synthetic-value", "CI": "1", "ANTHROPIC_API_KEY": "synthetic-value", "HTTPS_PROXY": "http://proxy.test"], home: "/fake-home")
        #expect(env["GITLAB_TOKEN"] == nil); #expect(env["ANTHROPIC_API_KEY"] == nil); #expect(env["CI"] == nil)
        #expect(env["HTTPS_PROXY"] == "http://proxy.test")
    }
}

extension AIProviderTests {
    @Test
    func enabledRestrictionIsRejectedEvenIfFlagIsAccepted() {
        let help = "--json --ephemeral --ignore-user-config --ignore-rules --strict-config --sandbox read-only --disable --enable --skip-git-repo-check"
        let features = CodexAIAdapter.disabledFeatures.map { $0 + " stable " + ($0 == "unified_exec" ? "true" : "false") } + ["skip_host_skill_discovery experimental true"]
        #expect(throws: AIError.unsupportedCLI) {
            try CodexAIAdapter().validate(executable: "/fake", outputs: ["fixture", help, features.joined(separator: "\n")])
        }
        #expect(throws: AIError.emptyResponse) { try CodexAIAdapter().response(stdout: Data("{\"type\":\"turn.completed\"}\n".utf8)) }
    }
}

extension AIDiagnosticsTests {
    @Test @MainActor
    func preservesTruncationOfAlreadyBoundedBootstrapReplay() {
        let memory = DiagnosticMemory()
        var record = TaskRecord(action: .bootstrap, project: ProjectContext(path: "/fixture")); record.status = .failed
        memory.capture(record: record, output: Data("last error".utf8), wasTruncated: true)
        #expect(memory.fragment(id: record.id) == "last error"); #expect(memory.isTruncated(id: record.id))
        let snapshot = DiagnosticSnapshot(record: record, output: "last error", wasTruncated: memory.isTruncated(id: record.id))
        #expect(snapshot.truncated)
    }
}
