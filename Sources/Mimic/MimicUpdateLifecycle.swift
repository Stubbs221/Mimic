//
//  MimicUpdateLifecycle.swift
//  Mimic
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation
import MimicCore

/// Owns backup and recovery metadata for both development deployment and Sparkle.
@MainActor
final class MimicUpdateLifecycle {
    private let model: TaskCoordinator
    private let defaults: UserDefaults
    private let app: URL
    private(set) var backup: URL?
    init(model: TaskCoordinator, defaults: UserDefaults = .standard, app: URL = Bundle.main.bundleURL) {
        self.model = model; self.defaults = defaults; self.app = app
    }
    func prepareBackup() async throws {
        let preferences = self.defaults.persistentDomain(forName: self.appBundleID) ?? [:]
        let data = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        self.backup = try await MimicUpdateBackup.create(app: self.app, support: self.model.supportDirectory, preferences: data,
            destination: self.model.supportDirectory.appendingPathComponent("UpdateBackups"))
    }
    private var appBundleID: String { Bundle(url: self.app)?.bundleIdentifier ?? "local.vmaslov.Mimic" }
}
