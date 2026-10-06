//
//  MimicSetupRules.swift
//  MimicCore
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation

/// Edits only marked Mimic blocks in the user's instructions, never repository conventions.
public enum MimicSetupRules {
    public enum RuleError: Error { case malformedBlock, invalidPath }
    public static func codexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    private static func key(_ path: String) -> String { path.utf8.map { String(format: "%02x", $0) }.joined() }
    private static func markers(_ path: String) -> (String, String) {
        let id = key(path)
        return ("<!-- mimic-setup:\(id):start -->", "<!-- mimic-setup:\(id):end -->")
    }
    public static func contains(project: String, home: URL) throws -> Bool {
        let file = home.appendingPathComponent("AGENTS.md")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return try String(contentsOf: file, encoding: .utf8).contains(markers(project).0)
    }
    /// Backs up before atomic replacement. A malformed owned block fails closed.
    @discardableResult public static func update(project: String, enabled: Bool, home: URL) throws -> URL? {
        guard project.hasPrefix("/"), !project.contains("\n"), !project.contains("\r"), !project.contains("`") else { throw RuleError.invalidPath }
        let file = home.appendingPathComponent("AGENTS.md")
        let old = FileManager.default.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : ""
        let (start, end) = markers(project)
        guard old.components(separatedBy: start).count <= 2 else { throw RuleError.malformedBlock }
        var updated = old
        while let a = updated.range(of: start) {
            guard let b = updated.range(of: end, range: a.upperBound..<updated.endIndex), !updated[a.upperBound..<b.lowerBound].contains(start) else { throw RuleError.malformedBlock }
            updated.removeSubrange(a.lowerBound..<b.upperBound)
        }
        guard !updated.contains(end) else { throw RuleError.malformedBlock }
        // The manually installed pilot rule is also ours; migrate only its exact project.
        if project == "/private/tmp/MimicExample", let a = updated.range(of: "<!-- mimic-auto-open:ios3:start -->") {
            guard let b = updated.range(of: "<!-- mimic-auto-open:ios3:end -->", range: a.upperBound..<updated.endIndex) else { throw RuleError.malformedBlock }
            updated.removeSubrange(a.lowerBound..<b.upperBound)
        }
        if enabled {
            let block = """
            \(start)
            ## Mimic for `\(project)`
            Only when the working directory is `\(project)` or a descendant: on the first response in a new chat, call the available Mimic MCP tool `open_panel` to open its task panel in this same chat. Discover the tool using tool search if needed. Do this once per chat; do not reopen a panel the user closed. Explicit user instructions take priority. Open only the panel: never launch tasks, bootstrap, cleanup or Jenkins, and never create another chat to open or test it. If unavailable, continue the user's task, briefly report that Mimic could not open, and do not retry repeatedly or run its helper directly through a terminal.
            \(end)
            """
            // Replacing in place avoids blank-line growth on repeated setup.
            if let a = old.range(of: start), let b = old.range(of: end, range: a.upperBound..<old.endIndex), old[a.upperBound..<b.lowerBound].contains(start) == false {
                updated = old.replacingCharacters(in: a.lowerBound..<b.upperBound, with: block)
            } else {
                updated += (updated.isEmpty || updated.hasSuffix("\n\n") ? "" : updated.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
            }
        }
        guard updated != old else { return nil }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backup: URL?
        if FileManager.default.fileExists(atPath: file.path) {
            let target = home.appendingPathComponent("AGENTS.md.mimic-backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: file, to: target); backup = target
        }
        try updated.write(to: file, atomically: true, encoding: .utf8)
        return backup
    }
}
