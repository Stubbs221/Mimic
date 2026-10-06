//
//  BuildActivity.swift
//  MimicCore
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation

public enum BuildOperation: String, Codable, Sendable, CaseIterable { case build, test }
public enum BuildBackend: String, Codable, Sendable, CaseIterable { case cli, xcodeMCP }
public enum BuildTracking: String, Codable, Sendable { case live, unavailable, lost }
public enum BuildStatus: String, Codable, Sendable {
    case queued, preparing, running, succeeded, failed, cancelled, interrupted, unknown
    public var isPending: Bool { self == .queued || self == .preparing || self == .running }
}

/// Only these parameters can reach a compiler. No caller-supplied executable, flags or environment.
public struct BuildParameters: Codable, Equatable, Sendable {
    public var operation: BuildOperation
    public var backend: BuildBackend
    public var scheme: String
    public var configuration: String
    public var platform: BootstrapPlatform?
    public var destinationID: String
    public var testPlan: String
    public var testIdentifiers: [String]
    public var workspaceTab: String
    public init(operation: BuildOperation = .build, backend: BuildBackend = .cli, scheme: String = "", configuration: String = "Debug", destinationID: String = "", platform: BootstrapPlatform? = nil, testPlan: String = "", testIdentifiers: [String] = [], workspaceTab: String = "") {
        self.operation = operation; self.backend = backend; self.scheme = scheme; self.configuration = configuration
        self.destinationID = destinationID; self.platform = platform; self.testPlan = testPlan; self.testIdentifiers = testIdentifiers; self.workspaceTab = workspaceTab
    }
    public func validate() throws {
        let fields = [scheme, configuration, destinationID, testPlan, workspaceTab] + testIdentifiers
        guard fields.allSatisfy({ $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }), testIdentifiers.count <= 100 else { throw BuildError.arguments }
        if backend == .cli {
            guard !scheme.isEmpty, !configuration.isEmpty, UUID(uuidString: destinationID) != nil, workspaceTab.isEmpty else { throw BuildError.arguments }
        } else {
            guard !workspaceTab.isEmpty, scheme.isEmpty, configuration.isEmpty, destinationID.isEmpty, testPlan.isEmpty else { throw BuildError.arguments }
        }
        if operation == .test {
            guard !testIdentifiers.isEmpty, testIdentifiers.allSatisfy({ value in
                let parts = value.split(separator: "/", omittingEmptySubsequences: false)
                return (2...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && !$0.contains("*") && !$0.hasPrefix("-") }
            }) else { throw BuildError.testsRequired }
        } else if !testIdentifiers.isEmpty || !testPlan.isEmpty { throw BuildError.arguments }
    }
    public func command(project: ProjectContext, resultBundlePath: String? = nil) throws -> CommandSpec {
        try validate(); guard backend == .cli else { throw BuildError.unsupported }
        let environment = EnvironmentInspector.environment(project: project)
        guard let target = project.appleTarget else { throw BuildError.configuration }
        let targetFlag = target.path.hasSuffix(".xcodeproj") ? "-project" : "-workspace"
        _ = try ProfileValidation.checkoutPath(target.path, root: project.path)
        var arguments = ["xcodebuild", targetFlag, project.workspace, "-scheme", scheme, "-configuration", configuration, "-destination", "platform=" + (platform == .tvos ? "tvOS" : "iOS") + " Simulator,id=" + destinationID, "-hideShellScriptEnvironment", "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile"]
        if !testPlan.isEmpty { arguments += ["-testPlan", testPlan] }
        if let resultBundlePath, operation == .test { arguments += ["-resultBundlePath", resultBundlePath] }
        arguments += testIdentifiers.map { "-only-testing:" + $0 }; arguments.append(operation.rawValue)
        return .init(executable: "/usr/bin/xcrun", arguments: arguments, directory: project.path, environment: environment)
    }
}

public enum BuildError: String, Error, Sendable {
    case arguments, testsRequired, context, unavailable, unsupported, catalogue, configuration, duplicate, capacity, notFound, diagnostic, stopped
}

/// Execution and observation have separate states: a broken connection never proves build failure.
public struct BuildActivity: Codable, Identifiable, Sendable {
    public let id: UUID
    public let project: ProjectContext
    public let parameters: BuildParameters
    public let source: String
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var status: BuildStatus = .queued
    public var tracking: BuildTracking = .live
    public var phase = "build.phase.queued"
    public var errorCode: String?
    public var exitCode: Int?
    public var signal: Int?
    public var truncated = false
    public var warningCount: Int?
    public var errorCount: Int?
    public var selectedDeveloperDirectory: String?
    public var profileID: String?
    public var profileRevision: String?
    /// Once interactive input is accepted, echoed output remains private and transient.
    public var hasPrivateInput: Bool?
    public var needsInput: Bool?
    public var queueReleased: Bool?
    public var xcodeRequestID: String?
    public var resultBundlePath: String?
    public var resultSummaryPath: String?
    public init(id: UUID = UUID(), project: ProjectContext, parameters: BuildParameters, source: String, createdAt: Date = Date()) {
        self.id = id; self.project = project; self.parameters = parameters; self.source = source; self.createdAt = createdAt
    }
    public var canCancel: Bool { status == .queued || status == .preparing || (parameters.backend == .cli && status == .running) }
    public var duration: TimeInterval { startedAt.map { (finishedAt ?? Date()).timeIntervalSince($0) } ?? 0 }
    public var diagnosticAvailable: Bool { hasPrivateInput != true && [.failed, .interrupted, .unknown].contains(status) }
}

public struct BuildDestination: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let platform: BootstrapPlatform?
    public init(id: String, name: String, platform: BootstrapPlatform? = nil) { self.id = id; self.name = name; self.platform = platform }
}

/// Discovery never builds or enumerates tests; destinations are restricted to the chosen scheme.
public struct BuildCatalogue: Codable, Sendable {
    public var schemes: [String] = []
    public var configurations: [String] = []
    public var destinations: [BuildDestination] = []
    public var testPlans: [String] = []
    public init() { }
    public static func inspect(project: ProjectContext, scheme: String = "") throws -> Self {
        var env = EnvironmentInspector.environment(project: project)
        env["DEVELOPER_DIR"] = project.developerDirectory ?? EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
        func capture(_ args: [String]) throws -> String {
            let result = EnvironmentInspector.capture("/usr/bin/xcrun", ["xcodebuild"] + args + ["-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile"], directory: project.path, environment: env)
            guard result.0 == 0 else { throw BuildError.catalogue }; return result.1
        }
        var value = Self()
        guard let target = project.appleTarget else { throw BuildError.configuration }
        let targetFlag = target.path.hasSuffix(".xcodeproj") ? "-project" : "-workspace"
        _ = try ProfileValidation.checkoutPath(target.path, root: project.path)
        let workspace = try capture(["-list", "-json", targetFlag, project.workspace])
        let json = try JSONSerialization.jsonObject(with: Data(workspace.utf8)) as? [String: Any]
        value.schemes = ((json?[targetFlag == "-project" ? "project" : "workspace"] as? [String: Any])?["schemes"] as? [String] ?? []).sorted()
        guard !value.schemes.isEmpty else { throw BuildError.catalogue }
        guard let configurationPath = targetFlag == "-project" ? Optional(target.path) : target.configurationProject else { throw BuildError.configuration }
        let projectJSON = try capture(["-list", "-json", "-project", try ProfileValidation.checkoutPath(configurationPath, root: project.path)])
        let projectObject = try JSONSerialization.jsonObject(with: Data(projectJSON.utf8)) as? [String: Any]
        value.configurations = ((projectObject?["project"] as? [String: Any])?["configurations"] as? [String] ?? []).sorted()
        if !scheme.isEmpty {
            guard value.schemes.contains(scheme) else { throw BuildError.configuration }
            value.destinations = destinations(from: try capture(["-showdestinations", targetFlag, project.workspace, "-scheme", scheme]))
            let plans = EnvironmentInspector.capture("/usr/bin/xcrun", ["xcodebuild", "-showTestPlans", targetFlag, project.workspace, "-scheme", scheme, "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile"], directory: project.path, environment: env)
            if plans.0 == 0, let range = plans.1.range(of: "Test plans associated with the scheme") {
                value.testPlans = plans.1[range.upperBound...].components(separatedBy: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        return value
    }
    public static func destinations(from text: String) -> [BuildDestination] {
        let available = text.components(separatedBy: "Ineligible destinations").first ?? ""
        let regex = try? NSRegularExpression(pattern: #"\{[^\n}]*platform:(iOS|tvOS) Simulator,[^\n}]*id:([A-Fa-f0-9-]{36}),[^\n}]*name:([^,}\n]+)"#)
        let matches = regex?.matches(in: available, range: NSRange(available.startIndex..., in: available)) ?? []
        var seen = Set<String>()
        return matches.compactMap { m in
            guard let idRange = Range(m.range(at: 2), in: available), let nameRange = Range(m.range(at: 3), in: available) else { return nil }
            let id = String(available[idRange]); guard seen.insert(id).inserted else { return nil }
            let name = available[nameRange].trimmingCharacters(in: .whitespaces)
            let entry = String(available[Range(m.range, in: available)!])
            let osPattern = #"OS:([^,}]+)"#
            let osRegex = try! NSRegularExpression(pattern: osPattern)
            let os = osRegex.firstMatch(in: entry, range: NSRange(entry.startIndex..., in: entry)).flatMap { Range($0.range(at: 1), in: entry) }.map { entry[$0].trimmingCharacters(in: .whitespaces) }
            let platform: BootstrapPlatform = String(available[Range(m.range(at: 1), in: available)!]) == "tvOS" ? .tvos : .ios
            return BuildDestination(id: id, name: name + (os.map { " · " + (platform == .tvos ? "tvOS " : "iOS ") + $0 } ?? ""), platform: platform)
        }
    }
    public func validate(_ parameters: BuildParameters) throws {
        guard schemes.contains(parameters.scheme), configurations.contains(parameters.configuration), destinations.contains(where: { $0.id == parameters.destinationID && ($0.platform ?? .ios) == (parameters.platform ?? .ios) }), parameters.testPlan.isEmpty || testPlans.contains(parameters.testPlan), parameters.operation != .test || testPlans.count <= 1 || !parameters.testPlan.isEmpty else { throw BuildError.configuration }
    }
}

/// Separate storage preserves the legacy history format and its independent log cleanup.
public struct BuildHistoryStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory.appendingPathComponent("BuildHistory") }
    public func logURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".log") }
    public func load() throws -> [BuildActivity] {
        let path = directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        var records = try JSONDecoder().decode([BuildActivity].self, from: Data(contentsOf: path))
        for i in records.indices where records[i].status.isPending {
            records[i].status = records[i].parameters.backend == .xcodeMCP && records[i].startedAt != nil ? .unknown : .interrupted; records[i].phase = "build.phase." + records[i].status.rawValue; records[i].tracking = .lost; records[i].finishedAt = Date()
        }
        return records
    }
    public func save(_ records: [BuildActivity]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(records); let path = directory.appendingPathComponent("history.json")
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let ids = Set(records.map { $0.id.uuidString })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where ["log", "xcresult"].contains(url.pathExtension) && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil && !ids.contains(url.deletingPathExtension().lastPathComponent) { try FileManager.default.removeItem(at: url) }
    }
}

public struct BuildLogSlice: Codable, Sendable {
    public let text: String
    public let nextCursor: Int
    public let gap: Bool
    public init(text: String, nextCursor: Int, gap: Bool) { self.text = text; self.nextCursor = nextCursor; self.gap = gap }
}

/// Filtering waits for complete lines so credentials and UTF-8 split across pipe reads cannot leak.
public struct BuildOutput: Sendable {
    public private(set) var bytes = Data()
    public private(set) var cursor = 0
    public private(set) var truncated = false
    /// Five visible, sanitized lines, updated only when a line is emitted.
    public private(set) var lastLines: [String] = []
    public private(set) var phase: String?
    private static let sgr = try! NSRegularExpression(pattern: #"\x1B\[[0-9;]*m"#)
    private var pending = Data()
    private var privateKey = false
    private var droppingLine = false
    public init() { }
    public mutating func append(_ data: Data, final: Bool = false) -> Data {
        var emitted = Data()
        for byte in data {
            if byte == 10 {
                emitted.append(emitLine(pending)); pending.removeAll(keepingCapacity: true); droppingLine = false
            } else if !droppingLine {
                pending.append(byte)
                if pending.count > 64 * 1024 { pending.removeAll(); droppingLine = true; truncated = true }
            }
        }
        if final, !pending.isEmpty || droppingLine { emitted.append(emitLine(pending)); pending.removeAll(); droppingLine = false }
        bytes.append(emitted); cursor += emitted.count
        if bytes.count > 512 * 1024 {
            var start = bytes.count - 512 * 1024
            while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
            bytes = Data(bytes.suffix(from: start)); truncated = true
        }
        return emitted
    }
    private mutating func emitLine(_ data: Data) -> Data {
        let result = cleanLine(data)
        let visible = DiagnosticText.visible(String(decoding: result, as: UTF8.self))
        for line in visible.split(separator: "\n", omittingEmptySubsequences: true) {
            let value = String(line)
            lastLines.append(value)
            if lastLines.count > 5 { lastLines.removeFirst(lastLines.count - 5) }
            if value.contains("SwiftCompile") || value.contains("CompileC") { phase = "compile" }
            else if value.hasPrefix("Ld ") { phase = "link" }
            else if value.hasPrefix("Test Suite") || value.hasPrefix("Test Case") { phase = "test" }
        }
        return result
    }
    private mutating func cleanLine(_ data: Data) -> Data {
        let line = String(decoding: data, as: UTF8.self)
        if line.contains("-----BEGIN"), line.contains("PRIVATE KEY-----") { privateKey = true }
        if privateKey {
            if line.contains("-----END"), line.contains("PRIVATE KEY-----") { privateKey = false }
            return Data("[REDACTED KEY MATERIAL]\n".utf8)
        }
        if droppingLine { return Data("[TRUNCATED OUTPUT LINE]\n".utf8) }
        let clean = DiagnosticText.clean(line)
        let visible = DiagnosticText.visible(line)
        guard clean == visible else { return Data((clean + "\n").utf8) }
        let sgr = Self.sgr
        var protected = line
        let matches = sgr.matches(in: line, range: NSRange(line.startIndex..., in: line))
        var colours: [String] = []
        for match in matches { if let range = Range(match.range, in: line) { colours.append(String(line[range])) } }
        for (index, match) in matches.enumerated().reversed() { if let range = Range(match.range, in: protected) { protected.replaceSubrange(range, with: "MIMIC_SGR_\(index)_END") } }
        protected = DiagnosticText.visible(protected)
        for (index, colour) in colours.enumerated() { protected = protected.replacingOccurrences(of: "MIMIC_SGR_\(index)_END", with: colour) }
        return Data((protected + "\n").utf8)
    }
    /// A stored log is already sanitized. Scan only its tail and strip terminal controls once.
    public static func savedTail(_ bytes: Data) -> [String] {
        var end = bytes.endIndex, start = end, lines: [String] = []
        func appendLine(_ range: Range<Data.Index>) {
            let visible = DiagnosticText.visible(String(decoding: bytes[range], as: UTF8.self))
            if !visible.isEmpty { lines.append(visible) }
        }
        while start > bytes.startIndex && lines.count < 5 {
            start -= 1
            if bytes[start] == 10 || bytes[start] == 13 {
                appendLine((start + 1)..<end); end = start
            }
        }
        if lines.count < 5 { appendLine(bytes.startIndex..<end) }
        return Array(lines.reversed())
    }
    public func read(after requested: Int, limit: Int = 64 * 1024) -> BuildLogSlice {
        Self.slice(bytes, base: cursor - bytes.count, after: requested, limit: limit)
    }
    public static func slice(_ bytes: Data, base: Int = 0, after requested: Int, limit: Int = 64 * 1024) -> BuildLogSlice {
        let array = Array(bytes)
        var start = min(array.count, max(0, requested - base))
        while start < array.count, array[start] & 0xC0 == 0x80 { start += 1 }
        var end = min(array.count, start + max(4, limit))
        while end < array.count, end > start, array[end] & 0xC0 == 0x80 { end -= 1 }
        return .init(text: String(decoding: array[start..<end], as: UTF8.self), nextCursor: base + end, gap: requested < base)
    }

}
