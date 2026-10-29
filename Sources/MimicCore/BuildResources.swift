//
//  BuildResources.swift
//  MimicCore
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation

/// A profile declares build inputs and the existing local action that restores them.
/// Checks are read-only; neither discovery nor a blocked build executes the action.
public struct BuildResourceRequirement: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let platform: BootstrapPlatform
    public let paths: [String]
    public let version: BuildResourceVersion?
    public let recoveryActionID: String
    public let recoveryParameters: [String: String]

    public init(id: String, title: String, platform: BootstrapPlatform, paths: [String], version: BuildResourceVersion? = nil, recoveryActionID: String, recoveryParameters: [String: String] = [:]) {
        self.id = id; self.title = title; self.platform = platform; self.paths = paths; self.version = version
        self.recoveryActionID = recoveryActionID; self.recoveryParameters = recoveryParameters
    }

    public func validate(profile: MimicProfile) throws {
        guard id.range(of: #"^[A-Za-z][A-Za-z0-9._-]{0,79}$"#, options: .regularExpression) != nil, !title.isEmpty, title.count <= 128,
              (1...32).contains(paths.count), paths.allSatisfy(ProfileValidation.relativePath),
              let action = profile.actions.first(where: { $0.id == recoveryActionID }),
              action.remote == nil, action.presentation == .regular, action.logPolicy != nil,
              profile.interface?.bindings.contains(where: { $0.actionID == action.id }) != true else { throw ProfileError.action }
        _ = try ProfileValidation.parameters(recoveryParameters, action: action)
        if let version {
            guard ProfileValidation.relativePath(version.configurationFile), ProfileValidation.relativePath(version.repository),
                  version.key.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil,
                  version.tagPrefix.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { throw ProfileError.parameter }
        }
    }
}

/// A bounded scalar in a configuration file selects a local Git tag in the resource repository.
public struct BuildResourceVersion: Codable, Equatable, Sendable {
    public let configurationFile: String
    public let key: String
    public let repository: String
    public let tagPrefix: String

    public init(configurationFile: String, key: String, repository: String, tagPrefix: String) {
        self.configurationFile = configurationFile; self.key = key; self.repository = repository; self.tagPrefix = tagPrefix
    }
}

public enum BuildResourceStatus: String, Codable, Sendable { case ready, missing, stale, modified, unknown }

/// Unknown configuration and local changes block builds without offering a destructive repair.
public struct BuildResourceCheck: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let platform: BootstrapPlatform
    public let status: BuildResourceStatus
    public let expectedVersion: String?
    public var blocking: Bool { status != .ready }
    public var canRecover: Bool { status == .missing || status == .stale }
    public init(id: String, title: String, platform: BootstrapPlatform, status: BuildResourceStatus, expectedVersion: String?) {
        self.id = id; self.title = title; self.platform = platform; self.status = status; self.expectedVersion = expectedVersion
    }
}

public struct BuildResourceState: Codable, Equatable, Sendable {
    public let checks: [BuildResourceCheck]
    public var blocking: Bool { checks.contains(where: \.blocking) }
    public var blocker: BuildResourceCheck? { checks.first(where: \.blocking) }
    public init(checks: [BuildResourceCheck] = []) { self.checks = checks }
}

public enum BuildResourceInspector {
    /// No network, checkout, bootstrap or generator is involved. Git queries are bounded and local.
    public static func inspect(_ requirements: [BuildResourceRequirement], project: ProjectContext, platform: BootstrapPlatform) -> BuildResourceState {
        .init(checks: requirements.filter { $0.platform == platform }.map { inspect($0, project: project) })
    }

    private static func inspect(_ requirement: BuildResourceRequirement, project: ProjectContext) -> BuildResourceCheck {
        var expectedVersion: String?
        func result(_ status: BuildResourceStatus) -> BuildResourceCheck {
            .init(id: requirement.id, title: requirement.title, platform: requirement.platform, status: status, expectedVersion: expectedVersion)
        }
        do {
            if let version = requirement.version {
                let configuration = try confinedPath(version.configurationFile, root: project.path)
                guard let value = try scalar(file: configuration, key: version.key) else { return result(.unknown) }
                expectedVersion = value
                let repository = try confinedPath(version.repository, root: project.path)
                if FileManager.default.fileExists(atPath: repository) {
                    let root = git(repository, ["rev-parse", "--show-toplevel"])
                    guard root.0 == 0, URL(fileURLWithPath: root.1).resolvingSymlinksInPath().path == repository else { return result(.unknown) }
                    let dirty = git(repository, ["status", "--porcelain", "--untracked-files=normal"])
                    guard dirty.0 == 0 else { return result(.unknown) }
                    guard dirty.1.isEmpty else { return result(.modified) }
                    let head = git(repository, ["rev-parse", "--verify", "HEAD^{commit}"])
                    let tag = git(repository, ["rev-parse", "--verify", "--end-of-options", "refs/tags/" + version.tagPrefix + value + "^{commit}"])
                    guard head.0 == 0 else { return result(.unknown) }
                    guard tag.0 == 0, head.1 == tag.1 else { return result(.stale) }
                } else { return result(.missing) }
            }
            for path in requirement.paths {
                let resolved = try confinedPath(path, root: project.path)
                var directory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: resolved, isDirectory: &directory) else { return result(.missing) }
                if directory.boolValue {
                    let contents = try FileManager.default.contentsOfDirectory(atPath: resolved)
                    guard !contents.isEmpty else { return result(.missing) }
                } else {
                    let attributes = try FileManager.default.attributesOfItem(atPath: resolved)
                    guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else { return result(.missing) }
                }
            }
            return result(.ready)
        } catch { return result(.unknown) }
    }

    private static func scalar(file: String, key: String) throws -> String? {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file)); defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"(?m)^"# + NSRegularExpression.escapedPattern(for: key) + #":[\t ]*["']?([A-Za-z0-9][A-Za-z0-9._-]{0,127})["']?[\t ]*(?:#[^\r\n]*)?\r?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Resolve each existing prefix: Foundation may leave a symlink unresolved when its leaf is missing.
    private static func confinedPath(_ path: String, root: String) throws -> String {
        guard ProfileValidation.relativePath(path) else { throw ProfileError.path }
        var current = URL(fileURLWithPath: root)
        for component in path.split(separator: "/") {
            current = current.appendingPathComponent(String(component)).resolvingSymlinksInPath()
            guard current.path.hasPrefix(root + "/") else { throw ProfileError.path }
        }
        return current.path
    }

    private static func git(_ directory: String, _ arguments: [String]) -> (Int32, String) {
        let result = EnvironmentInspector.boundedCapture("/usr/bin/git", ["-C", directory] + arguments, environment: ["PATH": "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"], timeout: 5, maximumBytes: 16 * 1024)
        return (result.0, result.1.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
