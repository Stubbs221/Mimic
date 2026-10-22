//
//  BuildCompilationCache.swift
//  MimicCore
//
//  Created by Василий Маслов on 22.10.2026.
import CryptoKit
import Foundation

/// Stable compiler storage is separate from immutable, per-invocation result bundles.
/// Xcode invalidates changed sources; branch names and commits must not defeat incremental builds.
public enum BuildCompilationCache {
    public static func directory(root: URL, project: ProjectContext, developer: String, parameters: BuildParameters, profileRevision: String?) throws -> URL {
        guard parameters.backend == .cli, parameters.operation == .build, parameters.intent == nil || parameters.intent == .run else { throw BuildError.arguments }
        let identity = ["v1", URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path,
                        project.appleTarget?.path ?? "", project.appleTarget?.configurationProject ?? "",
                        URL(fileURLWithPath: developer).resolvingSymlinksInPath().path,
                        parameters.scheme, parameters.configuration, parameters.platform?.rawValue ?? "ios", profileRevision ?? ""]
        let digest = SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("CompilationCache", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
    }
}
