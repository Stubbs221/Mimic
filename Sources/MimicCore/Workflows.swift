//
//  Workflows.swift
//  MimicCore
//
//  Created by Василий Маслов on 01.10.2026.
import Foundation

// MARK: - Generation

/// The three existing Generation templates supported by the graphical form.
public enum GeneratorKind: String, Codable, CaseIterable, Sendable {
    case ui
    case module
    case feature
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer(), value = try container.decode(String.self)
        if value == "sicilia" { self = .module }
        else if value == "galera" { self = .feature }
        else if let kind = Self(rawValue: value) { self = kind }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown generator") }
    }
    public var titleKey: String { "generator." + rawValue }
}

/// A reviewed file plan is tied to the input name, kind and template/config digest.
public struct GenerationRequest: Codable, Equatable, Sendable {
    public let kind: GeneratorKind
    public let name: String
    public let digest: String
    public init(kind: GeneratorKind, name: String, digest: String) {
        self.kind = kind; self.name = name; self.digest = digest
    }

    public static func validName(_ name: String) -> Bool {
        name.range(of: "^[A-Z][A-Za-z]{0,49}$", options: .regularExpression) != nil
    }
}

public struct GeneratedFile: Codable, Identifiable, Sendable {
    public var id: String { self.path }
    public let path: String
    public let exists: Bool
}

/// Read-only adapter output. Any existing destination blocks the whole generation.
public struct GenerationPlan: Codable, Sendable {
    public let files: [GeneratedFile]
    public let digest: String
    public var canGenerate: Bool { !self.files.isEmpty && self.files.allSatisfy { !$0.exists } }
}

// MARK: - Simulators

/// A concrete iOS device; commands always use its UUID, never the ambiguous `booted` selector.
public struct SimulatorDevice: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let runtime: String
    public let state: String
    public var isBooted: Bool { self.state == "Booted" }
    public init(id: UUID, name: String, runtime: String, state: String) {
        self.id = id; self.name = name; self.runtime = runtime; self.state = state
    }
}

public enum SimulatorCatalog {
    private struct Device: Decodable { let udid: UUID; let name: String; let state: String; let isAvailable: Bool }
    private struct Envelope: Decodable { let devices: [String: [Device]] }
    /// Excludes tvOS, watchOS and unavailable runtimes; the list operation changes no device state.
    public static func parse(_ data: Data) throws -> [SimulatorDevice] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.devices.flatMap { runtime, devices -> [SimulatorDevice] in
            let platform = runtime.contains(".tvOS-") ? "tvOS" : "iOS"
            guard let range = runtime.range(of: "." + platform + "-") else { return [] }
            let version = platform + " " + runtime[range.upperBound...].replacingOccurrences(of: "-", with: ".")
            return devices.filter { $0.isAvailable }.map {
                SimulatorDevice(id: $0.udid, name: $0.name, runtime: version, state: $0.state)
            }
        }.sorted { first, second in
            if first.isBooted != second.isBooted { return first.isBooted }
            return (first.runtime + first.name).localizedStandardCompare(second.runtime + second.name) == .orderedAscending
        }
    }
}

// MARK: - Bootstrap presets and summary

public enum BootstrapPreset: String, CaseIterable, Sendable {
    case dependencies
    case simulator
    case full
    case custom
    /// Recognizes the selected phases independently of platform, device and match.
    public static func matching(_ options: BootstrapOptions) -> Self {
        if options.full { return .full }
        if options.dependencies && !options.uiDependencies { return options.setup ? .simulator : .dependencies }
        return .custom
    }

    public var options: BootstrapOptions {
        var options = BootstrapOptions()
        switch self {
        case .dependencies: options.full = false; options.setup = false
        case .simulator: options.full = false
        case .full,
             .custom: break
        }
        return options
    }
}

/// Counts only this checkout's completed runs; a running task is never treated as a success.
public struct ActivitySummary {
    public let succeeded: Int
    public let failed: Int
    public let last: TaskRecord?
    public init(records: [TaskRecord], path: String?) {
        let matching = records.filter { $0.project.path == path }
        self.succeeded = matching.filter { $0.status == .succeeded }.count
        self.failed = matching.filter { $0.status == .failed }.count
        self.last = matching.filter { $0.finishedAt != nil }.max { $0.createdAt < $1.createdAt }
    }
}

/// Porcelain -z preserves filename boundaries; renames have a second path that is not a change.
public struct GitSummary: Sendable {
    public let changed: Int
    public let untracked: Int
    public init(porcelain: String) {
        let entries = porcelain.split(separator: "\0")
        var changed = 0, untracked = 0, index = 0
        while index < entries.count {
            let code = entries[index].prefix(2)
            if code == "??" { untracked += 1 }
            else { changed += 1 }
            index += code.contains("R") || code.contains("C") ? 2 : 1
        }
        self.changed = changed; self.untracked = untracked
    }
}
