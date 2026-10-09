//
//  PreparationReceipt.swift
//  MimicCore
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation

/// Profiles opt into blocking preparation. Required parameters select the actual completed steps.
public struct PreparationRequirement: Codable, Equatable, Sendable {
    public let actionID: String
    public let platforms: [BootstrapPlatform]
    public let parameters: [String: String]
    public let inputs: [String]
    public let required: Bool
    public var stages: [Int]?
    public init(actionID: String, platforms: [BootstrapPlatform], parameters: [String: String], inputs: [String], required: Bool, stages: [Int]? = nil) {
        self.actionID = actionID; self.platforms = platforms; self.parameters = parameters; self.inputs = inputs; self.required = required; self.stages = stages
    }
    /// Hash only declared configuration inputs; changing normal application source does not invalidate preparation.
    public func inputDigest(path: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var values: [SourceEntry] = []
        for input in inputs.sorted() {
            let url = try ProfileValidation.checkoutPath(input, root: path)
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: url)); defer { try? handle.close() }
            guard let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1), data.count <= 16 * 1024 * 1024 else { throw BuildError.sourceUnavailable }
            values.append(.init(path: input, kind: "input", mode: 0, digest: SourceRevisionReader.hash(data)))
        }
        return SourceRevisionReader.hash(try encoder.encode(values))
    }
}

public struct PreparationReceipt: Codable, Equatable, Sendable {
    public let activityID: UUID
    public let checkout: String
    public let platform: BootstrapPlatform
    public let profileID: String
    public let profileRevision: String
    public let developer: String
    public var completedStages: [Int]?
    public var toolchainIdentity: String?
    public let parameters: [String: String]
    public let inputDigest: String
    public let completedAt: Date
    public init(activityID: UUID, checkout: String, platform: BootstrapPlatform, profileID: String, profileRevision: String, developer: String, parameters: [String: String], inputDigest: String, completedAt: Date) {
        self.activityID = activityID; self.checkout = checkout; self.platform = platform; self.profileID = profileID; self.profileRevision = profileRevision; self.developer = developer; self.parameters = parameters; self.inputDigest = inputDigest; self.completedAt = completedAt
    }
}

/// Scenario configuration belongs to the trusted profile; it cannot introduce arbitrary MCP commands.
public struct SimulatorScenario: Codable, Equatable, Sendable {
    public let id: String
    public let actionID: String
    public let parameters: [String: String]
    public let deeplinkSchemes: [String]
}

/// The developer path alone does not identify an Xcode installation replaced in place.
public enum PreparationToolchain {
    public static func identify(developer: String) -> String? {
        let result = EnvironmentInspector.boundedCapture("/usr/bin/xcrun", ["xcodebuild", "-version"], environment: ["DEVELOPER_DIR": developer, "PATH": "/usr/bin:/bin"], timeout: 15, maximumBytes: 4096)
        guard result.0 == 0, !result.1.isEmpty else { return nil }
        return SourceRevisionReader.hash(Data((developer + "\n" + result.1).utf8))
    }
}
