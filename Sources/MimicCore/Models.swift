//
//  Models.swift
//  MimicCore
//
//  Created by Василий Маслов on 01.10.2026.
import Foundation

/// A checkout identity captured when the user requests a task; revalidated before execution.
public struct ProjectContext: Codable, Equatable, Sendable, Identifiable {
    public var id: String { self.path }
    public let path: String
    public var branch: String
    public var commit: String
    public var developerDirectory: String?
    public var appleTarget: AppleTarget?
    public init(path: String, branch: String = "", commit: String = "", developerDirectory: String? = nil, appleTarget: AppleTarget? = nil) {
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.branch = branch; self.commit = commit; self.developerDirectory = developerDirectory; self.appleTarget = appleTarget
    }

    public var workspace: String { self.appleTarget.map { self.path + "/" + $0.path } ?? "" }
}

/// The allowlisted local actions. Secret-capable bootstrap never writes its terminal output to disk.
public enum MimicAction: String, Codable, CaseIterable, Sendable {
    case bootstrap
    case localization
    case proto
    case format
    case generation
    case simulatorBoot
    case simulatorShutdown
    case fullCleanup
    case derivedDataCleanup
    /// Legacy values remain decodable; restored history is preserved by HistoryStore.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer(), value = try container.decode(String.self)
        if value == "celestial" { self = .generation }
        else if value == "babylon" { self = .localization }
        else if let action = Self(rawValue: value) { self = action }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown action") }
    }
    public var isSensitive: Bool { self == .bootstrap || self == .fullCleanup }
    public var requiresXcodeQuit: Bool { self == .bootstrap || self == .fullCleanup || self == .derivedDataCleanup }
    public var isCleanup: Bool { self == .fullCleanup || self == .derivedDataCleanup }
    public var titleKey: String { "action." + rawValue }
}

/// The platform is captured with every Bootstrap request; old history defaults to iOS.
public enum BootstrapPlatform: String, Codable, CaseIterable, Sendable { case ios, tvos }

/// Selected partial phases are translated into the existing bootstrap CLI contract.
public struct BootstrapOptions: Codable, Equatable, Sendable {
    public var platform = BootstrapPlatform.ios
    public var device = false
    public var match = true
    public var full = true
    public var dependencies = true
    public var uiDependencies = false
    public var setup = true
    public init() { }
    /// Matches `./bootstrap.sh ios` / `tvos`: all phases, Device and match enabled.
    /// Keep partial options and their Codable keys for exact repeats of older tasks.
    public static func standard(platform: BootstrapPlatform = .ios) -> Self {
        var options = Self()
        options.platform = platform; options.device = true
        return options
    }

    private enum CodingKeys: String, CodingKey { case platform, device, match, full, dependencies, uiDependencies, setup }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.platform = try values.decodeIfPresent(BootstrapPlatform.self, forKey: .platform) ?? .ios
        self.device = try values.decode(Bool.self, forKey: .device)
        self.match = try values.decode(Bool.self, forKey: .match)
        self.full = try values.decode(Bool.self, forKey: .full)
        self.dependencies = try values.decode(Bool.self, forKey: .dependencies)
        self.uiDependencies = try values.decode(Bool.self, forKey: .uiDependencies)
        self.setup = try values.decode(Bool.self, forKey: .setup)
    }

    /// Retained for decoding pre-profile history; execution is exclusively profile-defined.
    public var arguments: [String] { [self.platform.rawValue] }

    public var isValid: Bool { self.full || self.dependencies || self.uiDependencies || self.setup }
}

/// No shell expansion occurs: executable, arguments, cwd and environment are independent values.
public struct CommandSpec: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let directory: String
    public let environment: [String: String]
    public init(executable: String, arguments: [String], directory: String, environment: [String: String]) {
        self.executable = executable; self.arguments = arguments; self.directory = directory; self.environment = environment
    }

    public static func make(action: MimicAction, project: ProjectContext, options: BootstrapOptions, environment: [String: String], generation: GenerationRequest? = nil, simulator: SimulatorDevice? = nil, adapter: String? = nil, cleanupHome: String = NSHomeDirectory()) throws -> CommandSpec {
        if action.isCleanup {
            return try CacheCleanup.command(action: action, project: project, environment: environment, home: cleanupHome)
        }
        if action == .simulatorBoot || action == .simulatorShutdown {
            guard let simulator else { throw MimicError.invalidSimulator }
            return CommandSpec(executable: "/usr/bin/xcrun", arguments: ["simctl", action == .simulatorBoot ? "boot" : "shutdown", simulator.id.uuidString], directory: project.path, environment: environment)
        }
        throw MimicError.invalidProject
    }

    public var display: String { ([self.executable] + self.arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") }
}

public enum MimicError: Error, Equatable { case invalidBootstrap, invalidProject, changedCheckout, missingTools([String]), invalidGenerator, invalidSimulator, invalidCleanup }

/// Exit status is stored independently from an execution error or terminating signal.
public enum TaskStatus: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled, interrupted }
public struct TaskRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let action: MimicAction
    /// Refreshed during admission, then pinned while the task waits in the queue.
    public var project: ProjectContext
    public let options: BootstrapOptions
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var status: TaskStatus
    public var exitCode: Int?
    public var signal: Int?
    public var error: String?
    public var logPath: String?
    public var truncated = false
    public let generation: GenerationRequest?
    public let simulator: SimulatorDevice?
    public var profileExecution: ProfileExecution?
    /// Conservative retention barrier once a user types into the PTY, including terminal echo.
    public var hasPrivateInput: Bool?
    public var selectedDeveloperDirectory: String?
    /// The execution environment pins the effective Xcode even when the project follows the system default.
    public var executionProject: ProjectContext {
        var value = project; value.developerDirectory = selectedDeveloperDirectory ?? project.developerDirectory; return value
    }
    public var requiresXcodeQuit: Bool { self.profileExecution?.action?.requiresXcodeQuit ?? self.action.requiresXcodeQuit }
    public var metadataOnly: Bool { self.hasPrivateInput == true || (self.profileExecution.map { $0.action?.logPolicy != .boundedSanitized } ?? self.action.isSensitive) }
    public var displayTitle: String? { self.profileExecution?.binding == nil ? self.profileExecution?.action?.title : nil }
    public init(id: UUID = UUID(), action: MimicAction, project: ProjectContext, options: BootstrapOptions = BootstrapOptions(), generation: GenerationRequest? = nil, simulator: SimulatorDevice? = nil) {
        self.id = id; self.action = action; self.project = project; self.options = options
        self.createdAt = Date(); self.status = .queued
        self.generation = generation; self.simulator = simulator
    }

    public var duration: TimeInterval? { self.startedAt.map { (self.finishedAt ?? Date()).timeIntervalSince($0) } }
}
