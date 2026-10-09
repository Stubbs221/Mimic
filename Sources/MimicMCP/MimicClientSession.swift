//
//  MimicClientSession.swift
//  MimicMCP
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation

/// One identity per stdio connection. Client names label history, never grant permissions.
actor MimicClientSession {
    nonisolated let id = UUID().uuidString
    private(set) var name = "MCP"

    func initialize(name: String) {
        let value = name.lowercased()
        if value.contains("claude") { self.name = "Claude Code" }
        else if value.contains("codex") { self.name = "Codex" }
        else { self.name = "MCP" }
    }
}
