//
//  MimicPluginExporter.swift
//  MimicCore
//
//  Created by Василий Маслов on 04.10.2026.
import CryptoKit
import Foundation

/// A local marketplace containing a native stdio server; no shell or external runtime is needed.
public enum MimicPluginExporter {
    /// Detects helper/resource changes even when a local deployment retains the release build number.
    public static func installationRevision(app: URL) throws -> String {
        var digest = SHA256()
        for relative in ["Contents/Helpers/MimicMCP", "Contents/Resources/Mimic_MimicMCP.bundle/panel.html", "Contents/Resources/MimicPluginIcon.png"] {
            let file = app.appendingPathComponent(relative)
            digest.update(data: Data((relative + "\0").utf8))
            if relative.hasSuffix(".png"), !FileManager.default.fileExists(atPath: file.path) { continue }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            digest.update(data: Data((String(data.count) + "\0").utf8))
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the independent transparent plugin mark supplied by the signed app bundle.
    public static func export(app: URL, directory: URL? = nil, readme: String = "", description: String = "Mimic", shortDescription: String = "Mimic") throws -> URL {
        let helper = app.appendingPathComponent("Contents/Helpers/MimicMCP")
        guard app.pathExtension == "app", FileManager.default.isExecutableFile(atPath: helper.path) else { throw MimicBridgeError.unavailable }
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mimic/CodexPlugin")
        let plugin = root.appendingPathComponent("plugins/mimic")
        let manifest = plugin.appendingPathComponent(".codex-plugin")
        let market = root.appendingPathComponent(".agents/plugins")
        for directory in [root, plugin, manifest, market] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        func save(_ json: [String: Any], to url: URL) throws {
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
        var interface: [String: Any] = ["displayName": "Mimic", "shortDescription": shortDescription, "developerName": "Василий Маслов", "category": "Developer Tools", "capabilities": ["Interactive", "Read", "Write"]]
        let icon = app.appendingPathComponent("Contents/Resources/MimicPluginIcon.png")
        if FileManager.default.fileExists(atPath: icon.path) {
            let assets = plugin.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(contentsOf: icon).write(to: assets.appendingPathComponent("icon.png"), options: .atomic)
            interface["composerIcon"] = "./assets/icon.png"
            interface["logo"] = "./assets/icon.png"
        }
        try save(["name": "mimic", "version": MimicVersion.version, "description": description, "author": ["name": "Василий Маслов"], "mcpServers": "./.mcp.json", "interface": interface], to: manifest.appendingPathComponent("plugin.json"))
        try save(["mcpServers": ["mimic": ["command": helper.path, "args": [], "tool_timeout_sec": 120]]], to: plugin.appendingPathComponent(".mcp.json"))
        try save(["name": "mimic-desktop", "interface": ["displayName": "Mimic Desktop"], "plugins": [["name": "mimic", "source": ["source": "local", "path": "./plugins/mimic"], "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"], "category": "Developer Tools"]]], to: market.appendingPathComponent("marketplace.json"))
        try readme.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return root
    }
}
