//
//  Environment.swift
//  MimicCore
//
//  Created by Василий Маслов on 01.10.2026.
import Foundation

/// Read-only process queries are bounded and isolated from the GUI's main actor.
public enum EnvironmentInspector {
    public static func capture(_ executable: String, _ arguments: [String], directory: String? = nil, environment: [String: String]? = nil, trim: Bool = true) -> (Int32, String) {
        let result = ReadOnlyProcess.capture(executable, arguments, directory: directory, environment: environment)
        return (result.0, trim ? result.1.trimmingCharacters(in: .whitespacesAndNewlines) : result.1)
    }

    public static func project(path: String, developerDirectory: String? = nil, appleTarget: AppleTarget? = nil) throws -> ProjectContext {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let branch = self.capture("/usr/bin/git", ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"])
        let commit = self.capture("/usr/bin/git", ["-C", root, "rev-parse", "HEAD"])
        guard branch.0 == 0, commit.0 == 0 else { throw MimicError.invalidProject }
        return ProjectContext(path: root, branch: branch.1, commit: commit.1, developerDirectory: developerDirectory, appleTarget: appleTarget)
    }

    /// Explicit PATH avoids executing user shell startup files while preserving tool managers.
    /// Child tools always receive en_US.UTF-8, including overriding inherited locale
    /// categories: Ruby/Fastlane must not read UTF-8 source as US-ASCII in GUI launches.
    public static func environment(project: ProjectContext, base: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> [String: String] {
        var result = base
        let paths = [project.path + "/.gem/bin", home + "/.rbenv/shims", home + "/.rbenv/bin", home + "/.mint/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        result["PATH"] = paths.joined(separator: ":")
        result["PWD"] = project.path; result["TERM"] = "xterm-256color"
        result["LANG"] = "en_US.UTF-8"
        result["LC_ALL"] = "en_US.UTF-8"
        result["LC_CTYPE"] = "en_US.UTF-8"
        result["MINT_PATH"] = home + "/.mint"; result["MINT_LINK_PATH"] = home + "/.mint/bin"
        if let ruby = try? String(contentsOfFile: project.path + "/.ruby-version", encoding: .utf8) {
            result["RBENV_VERSION"] = ruby.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let directory = project.developerDirectory { result["DEVELOPER_DIR"] = directory }
        // A desktop task must not inherit CI-only credential paths/behavior.
        result.removeValue(forKey: "CI")
        return result
    }

    public static func executable(_ name: String, environment: [String: String]) -> String? {
        for path in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(path) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func missing(action: MimicAction, options: BootstrapOptions, project _: ProjectContext, environment: [String: String]) -> [String] {
        if action.isCleanup { return [] }
        if action == .simulatorBoot || action == .simulatorShutdown {
            return self.executable("xcrun", environment: environment) == nil ? ["xcrun"] : []
        }
        return ["profile"]
    }

    public static func diagnostic(project: ProjectContext) -> [String] {
        let env = self.environment(project: project)
        var lines = [project.path, project.branch + " · " + String(project.commit.prefix(8))]
        lines.append(self.capture("/usr/bin/xcrun", ["swift", "--version"], environment: env).1)
        for name in ["brew", "mint", "ruby", "bundle", "protoc"] { lines.append(name + ": " + (self.executable(name, environment: env) ?? "—")) }
        return lines
    }
}
