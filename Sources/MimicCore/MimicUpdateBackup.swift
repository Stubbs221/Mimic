//
//  MimicUpdateBackup.swift
//  MimicCore
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation

/// Local rollback material. Keychain, sockets, diagnostics, terminal input and environment are excluded.
public enum MimicUpdateBackup {
    /// Copy before handing installation to Sparkle. A failed copy never produces a completed backup.
    @concurrent public static func create(app: URL, support: URL, preferences: Data, destination: URL) async throws -> URL {
        let files = FileManager.default
        guard app.pathExtension == "app", files.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path),
              !destination.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        try files.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = destination.appendingPathComponent(".staging-" + UUID().uuidString)
        let completed = destination.appendingPathComponent("backup-" + UUID().uuidString)
        try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try Task.checkCancellation()
            try files.copyItem(at: app, to: staging.appendingPathComponent("Mimic.app"))
            let data = staging.appendingPathComponent("Data")
            try files.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in ["history.json", "BuildHistory", "SimulatorActivities.json", "profile-remote-runs.json", "remote-runs.json", "Profiles", "CodexPlugin", "AIUsage"] {
                try Task.checkCancellation()
                let source = support.appendingPathComponent(name)
                if files.fileExists(atPath: source.path) {
                    let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
                    try files.copyItem(at: source, to: data.appendingPathComponent(name))
                }
            }
            try preferences.write(to: staging.appendingPathComponent("preferences.plist"), options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent("preferences.plist").path)
            try files.moveItem(at: staging, to: completed)
            return completed
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }
}
