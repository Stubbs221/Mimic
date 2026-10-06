//
//  AIProviders.swift
//  MimicCore
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation

public enum AIProvider: String, Codable, CaseIterable, Sendable { case codex, claude }

/// Only user preferences are persisted; credentials and diagnostic contents are not part of settings.
public struct AISettings: Codable, Equatable, Sendable {
    public var provider: AIProvider
    public var codexPath: String
    public var claudePath: String
    public var codexModel: String
    public var claudeModel: String
    public init(provider: AIProvider = .codex, codexPath: String = "", claudePath: String = "", codexModel: String = "", claudeModel: String = "") {
        self.provider = provider; self.codexPath = codexPath; self.claudePath = claudePath
        self.codexModel = codexModel; self.claudeModel = claudeModel
    }

    public func path(for provider: AIProvider) -> String { provider == .codex ? self.codexPath : self.claudePath }
    public func model(for provider: AIProvider) -> String { provider == .codex ? self.codexModel : self.claudeModel }
}

/// Safe error categories intentionally exclude raw stderr and provider responses.
public enum AIError: Error, Equatable, Sendable {
    case missingCLI
    case unsupportedCLI
    case authentication
    case rateLimit
    case timeout
    case outputLimit
    case invalidJSON
    case emptyResponse
    case cancelled
    case unexpectedTool
    case processFailed
    case busy
    public var localizationKey: String { "ai.error." + String(describing: self) }
    public static func classify(_ input: String) -> AIError {
        let text = input.lowercased()
        if ["unexpected argument", "unknown feature", "unknown field", "unsupported", "unrecognized", "strict-config", "invalid config"].contains(where: text.contains) { return .unsupportedCLI }
        if ["unauthorized", "authentication", "not logged in", "login", "401", "invalid api key"].contains(where: text.contains) { return .authentication }
        if ["rate_limit", "rate limit", "429", "quota", "usage limit"].contains(where: text.contains) { return .rateLimit }
        return .processFailed
    }
}

public struct AICapability: Sendable {
    public let executable: String
    public let version: String
    public let provider: AIProvider
    public init(executable: String, version: String, provider: AIProvider) {
        self.executable = executable; self.version = version; self.provider = provider
    }
}

/// Provider-specific argv and decoding. Probes never start an inference request.
public protocol AIProviderAdapter: Sendable {
    var provider: AIProvider { get }
    var probes: [[String]] { get }
    func validate(executable: String, outputs: [String]) throws -> AICapability
    func arguments(model: String) -> [String]
    func response(stdout: Data) throws -> String
}

public struct CodexAIAdapter: AIProviderAdapter {
    public let provider = AIProvider.codex
    public init() { }
    // Every potentially executable integration is disabled explicitly, and supported feature names
    // are checked against the installed binary before a diagnostic can enter stdin.
    public static let disabledFeatures = ["shell_tool", "unified_exec", "shell_snapshot", "hooks", "apps", "plugins", "remote_plugin", "multi_agent", "memories", "skill_search", "skill_mcp_dependency_install", "browser_use", "computer_use", "image_generation", "view_image", "workspace_dependencies", "code_mode_host", "tool_suggest", "daemon_auto_start"]
    public var probes: [[String]] {
        var features: [String] = []
        for name in Self.disabledFeatures {
            features += ["--disable", name]
        }
        features += ["--enable", "skip_host_skill_discovery", "features", "list"]
        return [["--version"], ["exec", "--help"], features]
    }

    public func validate(executable: String, outputs: [String]) throws -> AICapability {
        guard outputs.count == 3,
              ["--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config", "--sandbox", "read-only", "--disable", "--enable", "--skip-git-repo-check"].allSatisfy(outputs[1].contains) else { throw AIError.unsupportedCLI }
        var features: [String: String] = [:]
        for line in outputs[2].split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            if let name = columns.first, let enabled = columns.last { features[String(name)] = String(enabled) }
        }
        guard Self.disabledFeatures.allSatisfy({ features[$0] == "false" }), features["skip_host_skill_discovery"] == "true" else { throw AIError.unsupportedCLI }
        return AICapability(executable: executable, version: DiagnosticText.bounded(outputs[0], limit: 200).text, provider: .codex)
    }

    public func arguments(model: String) -> [String] {
        var result = ["exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never", "--enable", "skip_host_skill_discovery"]
        for name in Self.disabledFeatures {
            result += ["--disable", name]
        }
        for value in ["approval_policy=\"never\"", "web_search=\"disabled\"", "tools.view_image=false", "mcp_servers={}", "project_doc_max_bytes=0", "suppress_unstable_features_warning=true", "feedback.enabled=false", "analytics.enabled=false"] { result += ["--config", value] }
        if !model.isEmpty { result += ["--model", model] }
        result.append("-")
        return result
    }

    public func response(stdout: Data) throws -> String {
        var final = "", complete = false
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { throw AIError.invalidJSON }
            if type == "error" || type == "turn.failed" { throw AIError.classify(String(describing: event)) }
            if type == "turn.completed" { complete = true }
            if let item = event["item"] as? [String: Any], let kind = item["type"] as? String {
                guard ["agent_message", "reasoning", "plan"].contains(kind) else { throw AIError.unexpectedTool }
                if type == "item.completed", kind == "agent_message" { final = item["text"] as? String ?? "" }
            }
        }
        guard complete else { throw AIError.processFailed }
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
        return DiagnosticText.bounded(final).text
    }
}

public struct ClaudeAIAdapter: AIProviderAdapter {
    public let provider = AIProvider.claude
    public init() { }
    public var probes: [[String]] { [["--version"], ["--help"]] }
    public func validate(executable: String, outputs: [String]) throws -> AICapability {
        guard outputs.count == 2,
              ["--bare", "--restricted", "--tools", "--disallowedTools", "--no-session-persistence", "--output-format", "--permission-mode", "--strict-mcp-config", "--mcp-config"].allSatisfy(outputs[1].contains) else { throw AIError.unsupportedCLI }
        return AICapability(executable: executable, version: DiagnosticText.bounded(outputs[0], limit: 200).text, provider: .claude)
    }

    public func arguments(model: String) -> [String] {
        var result = ["-p", "--bare", "--restricted", "--tools", "", "--disallowedTools", "*", "--no-session-persistence", "--output-format", "json", "--permission-mode", "dontAsk", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
        if !model.isEmpty { result += ["--model", model] }
        return result
    }

    public func response(stdout: Data) throws -> String {
        guard let event = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any], event["type"] as? String == "result" else { throw AIError.invalidJSON }
        if event["is_error"] as? Bool == true || event["subtype"] as? String != "success" { throw AIError.classify(String(describing: event)) }
        guard let result = event["result"] as? String, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
        return DiagnosticText.bounded(result).text
    }
}

public enum AIProviderAdapters {
    public static func make(_ provider: AIProvider) -> any AIProviderAdapter {
        switch provider { case .codex: CodexAIAdapter(); case .claude: ClaudeAIAdapter() }
    }

    public static func resolve(provider: AIProvider, configuredPath: String, home: String = NSHomeDirectory()) -> String? {
        if !configuredPath.isEmpty {
            return FileManager.default.isExecutableFile(atPath: configuredPath) ? configuredPath : nil
        }
        return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"].map { $0 + "/" + provider.rawValue }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// An allowlist avoids leaking CI/GitLab credentials through inherited process environments.
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> [String: String] {
        var result = ["HOME": home, "PATH": "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        for key in ["TMPDIR", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            if let value = base[key] { result[key] = value }
        }
        return result
    }
}
