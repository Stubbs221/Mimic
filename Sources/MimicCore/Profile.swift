//
//  Profile.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import CryptoKit
import ZIPFoundation

// MARK: - Portable profile contract

/// Profiles contain named workflows, never credentials or machine-specific settings.
public struct MimicProfile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let title: String
    public let requiredFiles: [String]
    public let appleTarget: AppleTarget?
    public let services: ProfileServices?
    public let actions: [ActionDefinition]
    public let interface: ProfileInterface?
}

public struct AppleTarget: Codable, Equatable, Sendable {
    public let path: String
    public let configurationProject: String?
    public init(path: String, configurationProject: String? = nil) {
        self.path = path; self.configurationProject = configurationProject
    }
}

public struct ProfileServices: Codable, Equatable, Sendable {
    public let gitLabURL: String?
    public let gitLabProject: String?
    public let jenkinsURL: String?
    public let reportArtifactPath: String?
    public let reportURLTemplate: String?
    public let branchOwnerPattern: String?
}

public enum ParameterKind: String, Codable, Sendable { case text, boolean, choice, platform, branch }
public struct ParameterDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: ParameterKind
    public let defaultValue: String
    public let choices: [String]?
    public let pattern: String?
    public let required: Bool
    public let visibleWhen: [String: String]?
}

public enum ActionPresentationKind: String, Codable, Sendable { case regular, preparation, generator, ci }
public enum ProfileLogPolicy: String, Codable, Sendable { case metadataOnly, boundedSanitized }
public struct ActionDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let presentation: ActionPresentationKind
    public let parameters: [ParameterDefinition]
    /// Missing flags always deny MCP execution.
    public let logPolicy: ProfileLogPolicy?
    public let mcpAllowed: Bool?
    public let requiresXcodeQuit: Bool
    public let requiredFiles: [String]
    public let requiredTools: [String]
    public let toolRequirements: [ProfileToolRequirement]?
    public let steps: [ExecutionStep]
    public let previewSteps: [ExecutionStep]?
    public let remote: RemoteActionDefinition?
    public let progress: [ProgressMatcher]?
    public var allowsMCP: Bool { self.mcpAllowed == true }
}

public enum ProfileProgressEvent: String, Codable, Sendable { case start, complete, skip }
public struct ProgressMatcher: Codable, Equatable, Sendable {
    public let title: String
    public let contains: String
    public let step: BootstrapProgress.Step?
    public let stage: BootstrapProgress.Stage?
    public let event: ProfileProgressEvent?
}

public struct RemoteActionDefinition: Codable, Equatable, Sendable {
    public let job: String
    public let branchParameter: String
    public let tracking: RemoteTrackingStrategy
}
public enum RemoteTrackingStrategy: String, Codable, Sendable { case jenkinsOnly, gitLabPipeline }

/// Arguments are passed directly to exec; substitution cannot create shell syntax.
public struct ExecutionStep: Codable, Equatable, Sendable {
    public let cleanup: String?
    public let executable: String
    public let arguments: [String]
    public let directory: String
}

public struct ProfileSnapshot: Codable, Equatable, Sendable {
    public let profile: MimicProfile
    public let revision: String
    public let directory: String
    public var id: String { self.profile.id }
    public init(profile: MimicProfile, revision: String, directory: String) {
        self.profile = profile; self.revision = revision; self.directory = directory
    }
}

/// Stored with a queue record. Reimporting a profile cannot alter a pending operation.
public struct ProfileExecution: Codable, Equatable, Sendable {
    public let snapshot: ProfileSnapshot
    public let actionID: String
    public let parameters: [String: String]
    public let preview: Bool
    public init(snapshot: ProfileSnapshot, actionID: String, parameters: [String: String], preview: Bool = false) {
        self.snapshot = snapshot; self.actionID = actionID; self.parameters = parameters; self.preview = preview
    }
    public var action: ActionDefinition? { self.snapshot.profile.actions.first { $0.id == self.actionID } }
    public func missingTools(project: ProjectContext, values: [String: String]? = nil) -> [String] {
        guard let action else { return [] }
        let values = values ?? (try? ProfileValidation.parameters(parameters, action: action)) ?? [:]
        let tools = action.requiredTools + (action.toolRequirements ?? []).filter { $0.applies(values) }.map(\.tool)
        return tools.filter { EnvironmentInspector.executable($0, environment: EnvironmentInspector.environment(project: project)) == nil }
    }
    public func commands(project: ProjectContext) throws -> [CommandSpec] {
        guard let action, action.remote == nil else { throw ProfileError.action }
        let values = try ProfileValidation.parameters(self.parameters, action: action)
        let environment = EnvironmentInspector.environment(project: project)
        for path in snapshot.profile.requiredFiles + action.requiredFiles {
            guard FileManager.default.fileExists(atPath: try ProfileValidation.checkoutPath(path, root: project.path)) else { throw ProfileError.requirements }
        }
        let missing = self.missingTools(project: project, values: values)
        guard missing.isEmpty else { throw MimicError.missingTools(missing) }
        var substitutions = values
        substitutions["checkout"] = project.path; substitutions["profile"] = snapshot.directory
        if substitutions["branch"] == nil { substitutions["branch"] = project.branch }
        func expand(_ value: String) throws -> String {
            var result = value
            let regex = try NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value), let keyRange = Range(match.range(at: 1), in: value), let replacement = substitutions[String(value[keyRange])] else { throw ProfileError.substitution }
                result.replaceSubrange(range, with: replacement)
            }
            return result
        }
        let steps = self.preview ? action.previewSteps ?? [] : action.steps
        guard !steps.isEmpty else { throw ProfileError.action }
        return try steps.map { step in
            if let cleanup = step.cleanup {
                guard ["full", "derivedData"].contains(cleanup), action.requiresXcodeQuit else { throw ProfileError.action }
                return try CacheCleanup.command(action: cleanup == "full" ? .fullCleanup : .derivedDataCleanup, project: project, environment: environment, home: NSHomeDirectory())
            }
            let executable = try expand(step.executable), directory = try expand(step.directory)
            guard executable.hasPrefix("/"), directory.hasPrefix("/") else { throw ProfileError.path }
            let resolvedDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
            guard resolvedDirectory == project.path || resolvedDirectory.hasPrefix(project.path + "/") else { throw ProfileError.path }
            return CommandSpec(executable: executable, arguments: try step.arguments.map(expand), directory: resolvedDirectory, environment: environment)
        }
    }
}

public enum ProfileError: String, Error, Sendable { case archive, size, path, schema, identifier, action, parameter, substitution, requirements, revision, generator, interface }

// MARK: - Validation before activation

public enum ProfileValidation {
    public static func relativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.utf8.contains(0)
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    public static func checkoutPath(_ path: String, root: String) throws -> String {
        guard relativePath(path) else { throw ProfileError.path }
        let resolved = URL(fileURLWithPath: root).appendingPathComponent(path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root + "/") else { throw ProfileError.path }; return resolved
    }
    public static func validate(_ profile: MimicProfile, files: Set<String>) throws {
        guard [1, 2].contains(profile.schemaVersion) else { throw ProfileError.schema }
        if profile.schemaVersion == 2 { guard let interface = profile.interface else { throw ProfileError.interface }; try interface.validate(profile: profile) }
        func identifier(_ id: String) -> Bool { id.range(of: #"^[A-Za-z][A-Za-z0-9._-]{0,79}$"#, options: .regularExpression) != nil }
        guard identifier(profile.id), !profile.version.isEmpty, !profile.title.isEmpty, profile.title.count <= 256, profile.actions.count <= 100,
              Set(profile.actions.map(\.id)).count == profile.actions.count else { throw ProfileError.identifier }
        if let target = profile.appleTarget {
            guard relativePath(target.path), ["xcworkspace", "xcodeproj"].contains(URL(fileURLWithPath: target.path).pathExtension), target.configurationProject.map(relativePath) ?? true else { throw ProfileError.path }
        }
        for url in [profile.services?.gitLabURL, profile.services?.jenkinsURL].compactMap({ $0 }) {
            guard let value = URLComponents(string: url), value.scheme == "https", value.host != nil, value.user == nil, value.password == nil else { throw ProfileError.parameter }
        }
        if let template = profile.services?.reportURLTemplate {
            guard template.contains("{id}"), let url = URLComponents(string: template.replacingOccurrences(of: "{id}", with: "1")), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ProfileError.parameter }
        }
        if let artifact = profile.services?.reportArtifactPath { guard relativePath(artifact) else { throw ProfileError.path } }
        if let pattern = profile.services?.branchOwnerPattern { _ = try NSRegularExpression(pattern: pattern.replacingOccurrences(of: "{username}", with: "username")) }
        guard profile.requiredFiles.allSatisfy(relativePath) else { throw ProfileError.path }
        for action in profile.actions {
            guard identifier(action.id), !action.title.isEmpty, action.title.count <= 256, action.parameters.count <= 64, Set(action.parameters.map(\.id)).count == action.parameters.count,
                  action.requiredFiles.allSatisfy(relativePath), action.requiredTools.allSatisfy({ identifier($0) }) else { throw ProfileError.action }
            for requirement in action.toolRequirements ?? [] {
                guard identifier(requirement.tool), requirement.whenAny.allSatisfy({ $0.allSatisfy { key, value in action.parameters.contains { $0.id == key && ($0.kind == .boolean ? ["true", "false"].contains(value) : $0.kind == .platform ? ["ios", "tvos"].contains(value) : $0.choices?.contains(value) ?? true) } } }) else { throw ProfileError.parameter }
            }
            for matcher in action.progress ?? [] {
                guard !matcher.contains.isEmpty, matcher.contains.utf8.count <= 2048, (matcher.step == nil && matcher.stage == nil) || matcher.event != nil, matcher.step != .process else { throw ProfileError.parameter }
            }
            for parameter in action.parameters {
                guard identifier(parameter.id), parameter.id.uppercased().range(of: #"(?:TOKEN|PASSWORD|PASSWD|SECRET|API[_-]?KEY)$"#, options: .regularExpression) == nil, parameter.title.count <= 256, (parameter.choices?.count ?? 0) <= 256, !["checkout", "profile", "branch"].contains(parameter.id) || parameter.kind == .branch else { throw ProfileError.parameter }
                if let pattern = parameter.pattern {
                    guard pattern.utf8.count <= 512 else { throw ProfileError.parameter }
                    _ = try NSRegularExpression(pattern: pattern)
                    if !parameter.defaultValue.isEmpty { guard parameter.defaultValue.range(of: pattern, options: .regularExpression)?.lowerBound == parameter.defaultValue.startIndex, parameter.defaultValue.range(of: pattern, options: .regularExpression)?.upperBound == parameter.defaultValue.endIndex else { throw ProfileError.parameter } }
                }
                if parameter.kind == .boolean { guard ["true", "false"].contains(parameter.defaultValue) else { throw ProfileError.parameter } }
                if parameter.kind == .platform { guard ["ios", "tvos"].contains(parameter.defaultValue) else { throw ProfileError.parameter } }
                if let choices = parameter.choices { guard Set(choices).count == choices.count, choices.allSatisfy({ $0.utf8.count <= 4096 }), parameter.defaultValue.isEmpty || choices.isEmpty || choices.contains(parameter.defaultValue) else { throw ProfileError.parameter } }
                if let visibility = parameter.visibleWhen { guard visibility.keys.allSatisfy({ key in action.parameters.contains { $0.id == key } && key != parameter.id }) else { throw ProfileError.parameter } }
            }
            func visit(_ id: String, ancestors: Set<String>) throws {
                guard !ancestors.contains(id) else { throw ProfileError.parameter }
                for dependency in action.parameters.first(where: { $0.id == id })?.visibleWhen?.keys ?? Dictionary<String, String>().keys { try visit(dependency, ancestors: ancestors.union([id])) }
            }
            for parameter in action.parameters { try visit(parameter.id, ancestors: []) }
            if let remote = action.remote {
                guard action.presentation == .ci, action.steps.isEmpty, !remote.branchParameter.isEmpty,
                      relativePath(remote.job), profile.services?.jenkinsURL != nil else { throw ProfileError.action }
            } else { guard !action.steps.isEmpty else { throw ProfileError.action } }
            for step in action.steps + (action.previewSteps ?? []) {
                if let cleanup = step.cleanup {
                    guard ["full", "derivedData"].contains(cleanup), action.requiresXcodeQuit, step.executable.isEmpty, step.arguments.isEmpty else { throw ProfileError.action }; continue
                }
                guard (step.executable.hasPrefix("/") && !step.executable.contains("${")) || step.executable.hasPrefix("${profile}/"),
                      step.directory.hasPrefix("${checkout}"), !step.arguments.contains("-c") else { throw ProfileError.action }
                for value in [step.executable, step.directory] + step.arguments {
                    let regex = try NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
                    for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                        let key = String(value[Range(match.range(at: 1), in: value)!])
                        guard ["checkout", "profile", "branch"].contains(key) || action.parameters.contains(where: { $0.id == key }) || key == "expectedDigest" && action.presentation == .generator else { throw ProfileError.substitution }
                    }
                    if value.hasPrefix("${profile}/") {
                        let path = String(value.dropFirst(11))
                        guard relativePath(path), files.contains(path) else { throw ProfileError.path }
                    }
                }
            }
            guard action.presentation != .generator || action.previewSteps?.isEmpty == false else { throw ProfileError.generator }
        }
    }
    public static func parameters(_ supplied: [String: String], action: ActionDefinition) throws -> [String: String] {
        let declared = Set(action.parameters.map(\.id))
        guard Set(supplied.keys).isSubset(of: declared.union(action.presentation == .generator ? ["expectedDigest"] : [])) else { throw ProfileError.parameter }
        var result: [String: String] = [:]
        for parameter in action.parameters {
            let value = supplied[parameter.id] ?? parameter.defaultValue
            guard DiagnosticText.clean(value) == value, value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ProfileError.parameter }
            let visible = parameter.visibleWhen?.allSatisfy { key, expected in (supplied[key] ?? action.parameters.first(where: { $0.id == key })?.defaultValue) == expected } ?? true
            if visible, parameter.required, value.isEmpty { throw ProfileError.parameter }
            if !value.isEmpty {
                if parameter.kind == .boolean { guard ["true", "false"].contains(value) else { throw ProfileError.parameter } }
                if parameter.kind == .platform { guard ["ios", "tvos"].contains(value) else { throw ProfileError.parameter } }
                if parameter.kind == .choice, let choices = parameter.choices, !choices.isEmpty { guard choices.contains(value) else { throw ProfileError.parameter } }
                if let pattern = parameter.pattern { guard value.range(of: pattern, options: .regularExpression)?.lowerBound == value.startIndex, value.range(of: pattern, options: .regularExpression)?.upperBound == value.endIndex else { throw ProfileError.parameter } }
            }
            result[parameter.id] = value
        }
        if let digest = supplied["expectedDigest"] { guard digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw ProfileError.generator }; result["expectedDigest"] = digest }
        return result
    }
}

// MARK: - Atomic immutable import

public struct ProfileStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory.resolvingSymlinksInPath() }
    public func active() throws -> ProfileSnapshot? {
        let marker = directory.appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let snapshot = try JSONDecoder().decode(ProfileSnapshot.self, from: Data(contentsOf: marker))
        try verify(snapshot); return snapshot
    }
    public func verify(_ snapshot: ProfileSnapshot) throws {
        let url = directory.appendingPathComponent(snapshot.revision)
        guard snapshot.directory == url.path, try digest(url) == snapshot.revision,
              try JSONDecoder().decode(MimicProfile.self, from: Data(contentsOf: url.appendingPathComponent("profile.json"))) == snapshot.profile else { throw ProfileError.revision }
    }
    /// Importing only reads and validates bytes. Adapter execution is a later named action.
    public func importArchive(_ source: URL, requireInterface: Bool = false) throws -> ProfileSnapshot {
        guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw ProfileError.size }
        try ProfileZIPEnvelope.validate(Data(contentsOf: source))
        let archive = try Archive(url: source, accessMode: .read)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(".import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        var seen = Set<String>(), files = Set<String>(), total: UInt64 = 0, count = 0
        for entry in archive {
            count += 1
            let path = entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            guard count <= 512, ProfileValidation.relativePath(path), seen.insert(path).inserted, entry.type != .symlink,
                  path == "profile.json" || path == "adapters" || path.hasPrefix("adapters/") else { throw ProfileError.archive }
            total += entry.uncompressedSize
            guard total <= 32 * 1024 * 1024, path != "profile.json" || entry.uncompressedSize <= 1024 * 1024 else { throw ProfileError.size }
            let target = staging.appendingPathComponent(path)
            if entry.type == .directory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
            else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                var data = Data()
                let checksum = try archive.extract(entry, consumer: { bytes in
                    guard UInt64(data.count + bytes.count) <= entry.uncompressedSize else { throw ProfileError.size }; data.append(bytes)
                })
                guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize else { throw ProfileError.archive }
                try data.write(to: target, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: target.path)
                files.insert(path)
            }
        }
        guard files.contains("profile.json") else { throw ProfileError.archive }
        let profile = try JSONDecoder().decode(MimicProfile.self, from: Data(contentsOf: staging.appendingPathComponent("profile.json")))
        try ProfileValidation.validate(profile, files: files)
        if requireInterface { guard profile.schemaVersion == 2, let interface = profile.interface else { throw ProfileError.interface }; try interface.validate(profile: profile) }
        let revision = try digest(staging), destination = directory.appendingPathComponent(revision)
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: staging, to: destination) }
        let snapshot = ProfileSnapshot(profile: profile, revision: revision, directory: destination.path)
        try verify(snapshot)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("active.json"), options: .atomic)
        return snapshot
    }
    private func digest(_ root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { throw ProfileError.revision }
        var paths: [String] = []
        for case let path as String in enumerator {
            let properties = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            guard properties[.type] as? FileAttributeType != .typeSymbolicLink else { throw ProfileError.path }
            if properties[.type] as? FileAttributeType == .typeRegular { paths.append(path) }
        }
        var hash = SHA256()
        for path in paths.sorted() {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            hash.update(data: Data("\(path.utf8.count):\(path):\(data.count):".utf8)); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Generator output boundary

public enum ProfileGeneratorValidation {
    public static func validate(_ plan: GenerationPlan, project: ProjectContext) throws {
        guard !plan.files.isEmpty, plan.files.count <= 512, Set(plan.files.map(\.path)).count == plan.files.count,
              plan.digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw ProfileError.generator }
        for file in plan.files {
            let path = try ProfileValidation.checkoutPath(file.path, root: project.path)
            var cursor = URL(fileURLWithPath: project.path).appendingPathComponent(file.path)
            while cursor.path != project.path {
                if (try? FileManager.default.attributesOfItem(atPath: cursor.path)[.type]) as? FileAttributeType == .typeSymbolicLink { throw ProfileError.path }
                cursor.deleteLastPathComponent()
                guard cursor.path == project.path || cursor.path.hasPrefix(project.path + "/") else { throw ProfileError.path }
            }
            guard !FileManager.default.fileExists(atPath: path) || file.exists else { throw ProfileError.generator }
            // Resolving links must not change any component, including an existing parent directory.
            guard URL(fileURLWithPath: project.path).appendingPathComponent(file.path).standardizedFileURL.path == path else { throw ProfileError.path }
        }
    }
    public static func revalidate(_ execution: ProfileExecution, project: ProjectContext) throws {
        guard execution.action?.presentation == .generator, !execution.preview else { return }
        guard let expected = execution.parameters["expectedDigest"] else { throw ProfileError.generator }
        let preview = ProfileExecution(snapshot: execution.snapshot, actionID: execution.actionID, parameters: execution.parameters, preview: true)
        let commands = try preview.commands(project: project)
        guard commands.count == 1 else { throw ProfileError.generator }
        let command = commands[0]
        let result = ReadOnlyProcess.capture(command.executable, command.arguments, directory: command.directory, environment: command.environment)
        guard result.0 == 0 else { throw ProfileError.generator }
        let plan = try JSONDecoder().decode(GenerationPlan.self, from: Data(result.1.utf8))
        try validate(plan, project: project)
        guard plan.canGenerate, plan.digest == expected else { throw ProfileError.generator }
    }
}

/// Check central headers explicitly: ZIPFoundation omits encrypted entries from iteration.
private enum ProfileZIPEnvelope {
    static func validate(_ data: Data) throws {
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= bytes.count else { throw ProfileError.archive }
            return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 22 else { throw ProfileError.archive }
        let start = max(0, bytes.count - 65557)
        guard let end = (start...(bytes.count - 22)).reversed().first(where: { bytes[$0..<$0 + 4].elementsEqual([0x50, 0x4b, 0x05, 0x06]) }) else { throw ProfileError.archive }
        guard try number(end + 4, 2) == 0, try number(end + 6, 2) == 0,
              end + 22 + (try number(end + 20, 2)) == bytes.count else { throw ProfileError.archive }
        let count = try number(end + 10, 2)
        guard count > 0, count <= 512, try number(end + 8, 2) == count else { throw ProfileError.size }
        var position = try number(end + 16, 4)
        let centralEnd = position + (try number(end + 12, 4))
        guard centralEnd == end else { throw ProfileError.archive }
        for _ in 0..<count {
            guard try number(position, 4) == 0x02014b50, try number(position + 8, 2) & 1 == 0 else { throw ProfileError.archive }
            let length = try number(position + 28, 2), extra = try number(position + 30, 2), comment = try number(position + 32, 2)
            let local = try number(position + 42, 4)
            guard try number(local, 4) == 0x04034b50, try number(local + 6, 2) & 1 == 0 else { throw ProfileError.archive }
            position += 46 + length + extra + comment
            guard position <= centralEnd else { throw ProfileError.archive }
        }
        guard position == centralEnd else { throw ProfileError.archive }
    }
}
