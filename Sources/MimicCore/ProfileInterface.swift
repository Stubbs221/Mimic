//
//  ProfileInterface.swift
//  MimicCore
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation

/// Stable UI semantics. Action IDs, parameter names and scripts belong to the imported profile.
public enum ProfileToolRole: String, Codable, CaseIterable, Sendable {
    case bootstrap, localization, protocols, format, generateUI, generateModule, generateFeature
    case fullCleanup, derivedDataCleanup, uiTests, qualityGates, beta
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer(), value = try container.decode(String.self)
        let aliases = (decoder.userInfo[ProfileCompatibility.codingKey] as? ProfileCompatibility)?.roles ?? [:]
        guard let role = Self(rawValue: aliases[value] ?? ProfileCompatibility.legacyRoles[value] ?? value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown profile role")
        }
        self = role
    }
    public var localAction: MimicAction? {
        switch self {
        case .bootstrap: .bootstrap
        case .localization: .localization
        case .protocols: .proto
        case .format: .format
        case .generateUI, .generateModule, .generateFeature: .generation
        case .fullCleanup: .fullCleanup
        case .derivedDataCleanup: .derivedDataCleanup
        case .uiTests, .qualityGates, .beta: nil
        }
    }
    public var generator: GeneratorKind? {
        switch self { case .generateUI: .ui; case .generateModule: .module; case .generateFeature: .feature; default: nil }
    }
    public var fields: [ProfileFormField: ParameterKind] {
        switch self {
        case .bootstrap: [.platform: .platform, .device: .boolean, .match: .boolean, .full: .boolean, .dependencies: .boolean, .uiDependencies: .boolean, .setup: .boolean]
        case .generateUI, .generateModule, .generateFeature: [.name: .text]
        case .uiTests: [.branch: .branch, .plan: .choice]
        case .qualityGates: [.branch: .branch, .locales: .boolean, .unitIOS: .boolean, .unitTVOS: .boolean, .snapshotIOS: .boolean, .snapshotTVOS: .boolean, .buildIOS: .boolean, .buildTVOS: .boolean, .performance: .boolean]
        case .beta: [.branch: .branch, .target: .choice, .rebase: .text, .upload: .choice]
        default: [:]
        }
    }
}

public enum ProfileFormField: String, Codable, Sendable {
    case platform, device, match, full, dependencies, uiDependencies, setup, name, branch, plan
    case locales, unitIOS, unitTVOS, snapshotIOS, snapshotTVOS, buildIOS, buildTVOS, performance
    case target, rebase, upload
}

/// Only these safe references are exported to MCP. No commands or service configuration are exposed.
public struct ProfileToolBinding: Codable, Equatable, Sendable {
    public let role: ProfileToolRole
    public let actionID: String
    public let fields: [String: String]
    public func parameter(_ field: ProfileFormField) -> String? { self.fields[field.rawValue] }
    public init(role: ProfileToolRole, actionID: String, fields: [String: String]) {
        self.role = role; self.actionID = actionID; self.fields = fields
    }
}

public struct ProfileInterface: Codable, Equatable, Sendable {
    public let version: Int
    public let bindings: [ProfileToolBinding]
    /// Team-specific names are optional profile data; the application supplies neutral fallbacks.
    public var toolTitles: [String: String]? = nil
    public var generatorTitles: [String: String]? = nil
    public var toolDescriptions: [String: String]? = nil
    public var toolEffects: [String: String]? = nil
    public var generatorDescriptions: [String: String]? = nil
    public func binding(_ role: ProfileToolRole) -> ProfileToolBinding? { self.bindings.first { $0.role == role } }
    public init(version: Int = 1, bindings: [ProfileToolBinding], toolTitles: [String: String]? = nil, generatorTitles: [String: String]? = nil, toolDescriptions: [String: String]? = nil, toolEffects: [String: String]? = nil, generatorDescriptions: [String: String]? = nil) {
        self.version = version; self.bindings = bindings; self.toolTitles = toolTitles; self.generatorTitles = generatorTitles
        self.toolDescriptions = toolDescriptions; self.toolEffects = toolEffects; self.generatorDescriptions = generatorDescriptions
    }
    public func validate(profile: MimicProfile) throws {
        for (titles, keys) in [(toolTitles, Set(ProjectTool.allCases.map(\.rawValue))), (generatorTitles, Set(GeneratorKind.allCases.map(\.rawValue)))] {
            guard (titles ?? [:]).allSatisfy({ keys.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.count <= 80 && !$0.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw ProfileError.interface }
        }
        for (descriptions, keys) in [(toolDescriptions, Set(ProjectTool.allCases.map(\.rawValue))), (toolEffects, Set(ProjectTool.allCases.map(\.rawValue))), (generatorDescriptions, Set(GeneratorKind.allCases.map(\.rawValue)))] {
            guard (descriptions ?? [:]).allSatisfy({ keys.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.count <= 1024 && !$0.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw ProfileError.interface }
        }
        guard version == 1, Set(bindings.map(\.role)) == Set(ProfileToolRole.allCases), bindings.count == ProfileToolRole.allCases.count,
              Set(bindings.map(\.actionID)).count == bindings.count else { throw ProfileError.interface }
        for binding in bindings {
            guard let action = profile.actions.first(where: { $0.id == binding.actionID }),
                  Set(binding.fields.keys) == Set(binding.role.fields.keys.map(\.rawValue)),
                  Set(binding.fields.values).count == binding.fields.count,
                  (action.remote == nil) == (binding.role.localAction != nil) else { throw ProfileError.interface }
            for (field, kind) in binding.role.fields {
                guard let id = binding.parameter(field), let parameter = action.parameters.first(where: { $0.id == id }), parameter.kind == kind else { throw ProfileError.interface }
            }
            let expected: ActionPresentationKind = binding.role.generator != nil ? .generator : binding.role.localAction == nil ? .ci : binding.role == .bootstrap ? .preparation : .regular
            guard action.presentation == expected else { throw ProfileError.interface }
            if binding.role == .bootstrap || binding.role == .fullCleanup {
                guard action.logPolicy == .metadataOnly, action.requiresXcodeQuit else { throw ProfileError.interface }
            }
            if binding.role == .derivedDataCleanup { guard action.requiresXcodeQuit else { throw ProfileError.interface } }
            if binding.role.generator != nil || [.localization, .protocols, .format].contains(binding.role) {
                guard action.logPolicy == .boundedSanitized else { throw ProfileError.interface }
            }
            // Specialized forms must account for every field; hidden unreviewed inputs cannot be submitted.
            guard Set(action.parameters.map(\.id)) == Set(binding.fields.values) else { throw ProfileError.interface }
        }
    }
}

// MARK: - Profile-owned compatibility

/// Profile aliases extend the built-in compatibility for previously shipped identifiers.
public struct ProfileCompatibility: Codable, Equatable, Sendable {
    public var actions: [String: String]? = nil
    public var generators: [String: String]? = nil
    public var roles: [String: String]? = nil
    public init(actions: [String: String]? = nil, generators: [String: String]? = nil, roles: [String: String]? = nil) {
        self.actions = actions; self.generators = generators; self.roles = roles
    }
    static let codingKey = CodingUserInfoKey(rawValue: "profileCompatibility")!
    // These identifiers were accepted by released versions and can occur in stored data.
    static let legacyRoles = ["generateSicilia": "generateModule", "generateGalera": "generateFeature"]
    static let legacyGenerators = ["sicilia": "module", "galera": "feature"]
    static let legacyActions = ["celestial": "generation", "babylon": "localization"]
    public static func decoder(_ compatibility: Self? = nil) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[codingKey] = compatibility
        return decoder
    }
    public func validate() throws {
        for (aliases, keys) in [(actions, Set(MimicAction.allCases.map(\.rawValue))), (generators, Set(GeneratorKind.allCases.map(\.rawValue))), (roles, Set(ProfileToolRole.allCases.map(\.rawValue)))] {
            guard (aliases?.count ?? 0) <= 64, (aliases ?? [:]).allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 100 && !keys.contains($0.key) && keys.contains($0.value) }) else { throw ProfileError.interface }
        }
    }
}

// MARK: - Form conversion and task presentation

extension ProfileSnapshot {
    public func execution(role: ProfileToolRole, values: [ProfileFormField: String] = [:], preview: Bool = false) throws -> ProfileExecution {
        guard let binding = profile.interface?.binding(role) else { throw ProfileError.interface }
        var parameters: [String: String] = [:]
        for (field, value) in values {
            guard let key = binding.parameter(field) else { throw ProfileError.interface }; parameters[key] = value
        }
        let execution = ProfileExecution(snapshot: self, actionID: binding.actionID, parameters: parameters, preview: preview)
        guard let action = execution.action else { throw ProfileError.action }
        _ = try ProfileValidation.parameters(parameters, action: action)
        return execution
    }
}

extension ProfileExecution {
    public var binding: ProfileToolBinding? { snapshot.profile.interface?.bindings.first { $0.actionID == actionID } }
    public var bootstrapOptions: BootstrapOptions {
        var options = BootstrapOptions.standard()
        guard let binding, binding.role == .bootstrap, let action, let values = try? ProfileValidation.parameters(parameters, action: action) else { return options }
        func bool(_ field: ProfileFormField) -> Bool { binding.parameter(field).flatMap { values[$0] } == "true" }
        options.platform = binding.parameter(.platform).flatMap { values[$0] }.flatMap(BootstrapPlatform.init(rawValue:)) ?? .ios
        options.device = bool(.device); options.match = bool(.match); options.full = bool(.full)
        options.dependencies = bool(.dependencies); options.uiDependencies = bool(.uiDependencies); options.setup = bool(.setup)
        return options
    }
    public func record(id: UUID, project: ProjectContext) -> TaskRecord {
        let generation = binding?.role.generator.map { GenerationRequest(kind: $0, name: binding?.parameter(.name).flatMap { parameters[$0] } ?? "", digest: parameters["expectedDigest"] ?? "") }
        var record = TaskRecord(id: id, action: binding?.role.localAction ?? .format, project: project, options: bootstrapOptions, generation: generation)
        record.profileExecution = self; return record
    }
}

extension BootstrapOptions {
    public var profileValues: [ProfileFormField: String] {
        [.platform: platform.rawValue, .device: String(device), .match: String(match), .full: String(full), .dependencies: String(dependencies), .uiDependencies: String(uiDependencies), .setup: String(setup)]
    }
}

/// Requirement predicates use validated action parameters. Alternatives are OR; each clause is AND.
public struct ProfileToolRequirement: Codable, Equatable, Sendable {
    public let tool: String
    public let whenAny: [[String: String]]
    public func applies(_ values: [String: String]) -> Bool { whenAny.isEmpty || whenAny.contains { clause in clause.allSatisfy { values[$0.key] == $0.value } } }
}

// MARK: - CI form semantics

extension RemoteCIKind {
    public var profileRole: ProfileToolRole { switch self { case .uiTests: .uiTests; case .qualityGates: .qualityGates; case .beta: .beta } }
}
extension QualityGate {
    public var profileField: ProfileFormField {
        switch self { case .locales: .locales; case .unitIOS: .unitIOS; case .unitTVOS: .unitTVOS; case .snapshotIOS: .snapshotIOS; case .snapshotTVOS: .snapshotTVOS; case .buildIOS: .buildIOS; case .buildTVOS: .buildTVOS; case .performance: .performance }
    }
}
