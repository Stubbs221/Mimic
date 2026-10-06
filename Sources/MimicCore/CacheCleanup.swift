//
//  CacheCleanup.swift
//  MimicCore
//
//  Created by Василий Маслов on 03.10.2026.
import Foundation

/// Fixed cleanup targets; home and checkout paths are positional shell arguments, never shell source.
enum CacheCleanup {
    static func command(action: MimicAction, project: ProjectContext, environment: [String: String], home: String) throws -> CommandSpec {
        guard action.isCleanup, home.hasPrefix("/"), !home.split(separator: "/").contains(".."), URL(fileURLWithPath: home).standardizedFileURL.path != "/" else { throw MimicError.invalidCleanup }
        let script: String
        if action == .fullCleanup {
            script = """
                set -e
                /bin/rm -rf -- "$1/Library/org.swift.swiftpm/"
                /bin/rm -rf -- "$1/Library/Caches/org.swift.swiftpm/"
                /bin/rm -rf -- "$1/Library/Developer/Xcode/DerivedData/"
                /bin/rm -rf -- "$1/Library/Developer/Xcode/SourcePackages"
                """
        } else {
            script = """
                set -e
                /bin/rm -rf -- "$1/Library/Developer/Xcode/DerivedData/"
                """
        }
        return CommandSpec(executable: "/bin/bash", arguments: ["-c", script, "mimic-cleanup", home, project.path], directory: project.path, environment: environment)
    }
}
