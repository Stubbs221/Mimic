//
//  BuildInputFingerprint.swift
//  MimicCore
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation

/// Opt-in assertion that every otherwise ignored/generated input and Git-dependent script input is declared.
public struct CatalogueReusePolicy: Codable, Equatable, Sendable {
    public let complete: Bool
    public let inputPaths: [String]
    public let gitDependencies: [String]
    public init(complete: Bool, inputPaths: [String] = [], gitDependencies: [String] = []) {
        self.complete = complete; self.inputPaths = inputPaths; self.gitDependencies = gitDependencies
    }
    public func validate() throws {
        guard inputPaths.count <= 100, inputPaths.allSatisfy(ProfileValidation.relativePath), Set(gitDependencies).isSubset(of: ["HEAD", "branch"]) else { throw ProfileError.parameter }
    }
}

/// Catalogue validity is separate from source provenance and never proves that tests executed at a new SHA.
public struct BuildInputFingerprint: Codable, Equatable, Sendable {
    public let version: Int
    public let digest: String
    public let capturedAt: Date
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version && lhs.digest == rhs.digest }

    public static func capture(project: ProjectContext, parameters: BuildParameters, profile: ProfileSnapshot?, policy: CatalogueReusePolicy, settings: String, toolchain: String, runtime: String) throws -> Self {
        try policy.validate()
        guard policy.complete, !toolchain.isEmpty, !runtime.isEmpty, let developer = project.developerDirectory, let target = project.appleTarget else { throw BuildError.sourceUnavailable }
        let entries = try SourceRevisionReader.entries(path: project.path)
        let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath()
        for entry in entries where entry.kind == "symlink" {
            guard root.appendingPathComponent(entry.path).resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw BuildError.sourceUnavailable }
        }
        var extra: [String: String] = [:], count = 0, total = 0
        func add(_ file: URL) throws {
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw BuildError.sourceUnavailable }
            let properties = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true, let size = properties.fileSize, size <= 32 * 1024 * 1024 else { throw BuildError.sourceUnavailable }
            count += 1; total += size; guard count <= 10_000, total <= 256 * 1024 * 1024 else { throw BuildError.capacity }
            extra[String(file.path.dropFirst(root.path.count + 1))] = SourceRevisionReader.hash(try Data(contentsOf: file))
        }
        for path in policy.inputPaths {
            let file = URL(fileURLWithPath: try ProfileValidation.checkoutPath(path, root: root.path))
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory) else { throw BuildError.sourceUnavailable }
            if directory.boolValue {
                guard let enumerator = FileManager.default.enumerator(at: file, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw BuildError.sourceUnavailable }
                for case let child as URL in enumerator {
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw BuildError.sourceUnavailable }
                    if values.isDirectory != true { try add(child) }
                }
            } else { try add(file) }
        }
        var git: [String: String] = [:]
        if policy.gitDependencies.contains("HEAD") { git["HEAD"] = project.commit }
        if policy.gitDependencies.contains("branch") { git["branch"] = project.branch }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = [root.path, target.path, target.configurationProject ?? "", developer, parameters.scheme, parameters.configuration, parameters.testPlan, parameters.destinationID, parameters.platform?.rawValue ?? "ios", profile?.id ?? "", profile?.revision ?? "", settings, toolchain, runtime]
        let data = try encoder.encode(entries) + encoder.encode(extra) + encoder.encode(git) + encoder.encode(identity) + encoder.encode(policy)
        return .init(version: 1, digest: SourceRevisionReader.hash(data), capturedAt: Date())
    }

    /// This read never compiles or resolves dependencies. An unsupported input yields a cache miss.
    public static func inspect(project: ProjectContext, parameters: BuildParameters, profile: ProfileSnapshot?, policy: CatalogueReusePolicy) throws -> Self {
        var base = BuildParameters(scheme: parameters.scheme, configuration: parameters.configuration, destinationID: parameters.destinationID, platform: parameters.platform)
        base.operation = .build
        let command = try base.command(project: project)
        let settings = ReadOnlyProcess.capture(command.executable, Array(command.arguments.dropLast()) + ["-showBuildSettings", "-json"], directory: project.path, environment: command.environment, timeout: 30, maximumBytes: 8 * 1024 * 1024)
        let version = ReadOnlyProcess.capture("/usr/bin/xcrun", ["xcodebuild", "-version"], environment: command.environment)
        let sdk = ReadOnlyProcess.capture("/usr/bin/xcrun", ["--sdk", parameters.platform == .tvos ? "appletvsimulator" : "iphonesimulator", "--show-sdk-version"], environment: command.environment)
        let devices = ReadOnlyProcess.capture("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], environment: command.environment)
        guard settings.0 == 0, version.0 == 0, sdk.0 == 0, devices.0 == 0,
              let rows = try JSONSerialization.jsonObject(with: Data(settings.1.utf8)) as? [[String: Any]] else { throw BuildError.sourceUnavailable }
        let allowed = ["SWIFT_ACTIVE_COMPILATION_CONDITIONS", "OTHER_SWIFT_FLAGS", "OTHER_CFLAGS", "SDKROOT", "SWIFT_VERSION", "ARCHS", "SUPPORTED_PLATFORMS", "IPHONEOS_DEPLOYMENT_TARGET", "CONFIGURATION", "TEST_TARGET_NAME", "PRODUCT_MODULE_NAME"]
        var effective: [[String: String]] = []
        for row in rows {
            guard let values = row["buildSettings"] as? [String: String] else { throw BuildError.sourceUnavailable }
            for key in ["PROJECT_DIR", "SRCROOT"] {
                if let path = values[key], !(URL(fileURLWithPath: path).resolvingSymlinksInPath().path == project.path || URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(project.path + "/")) { throw BuildError.sourceUnavailable }
            }
            var selected = values.filter { allowed.contains($0.key) }; selected["target"] = row["target"] as? String
            effective.append(selected)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let runtime = try BuildCatalogueSignature.destinationDigest(json: Data(devices.1.utf8))
        return try capture(project: project, parameters: parameters, profile: profile, policy: policy, settings: SourceRevisionReader.hash(encoder.encode(effective)), toolchain: version.1 + sdk.1, runtime: runtime)
    }
}
