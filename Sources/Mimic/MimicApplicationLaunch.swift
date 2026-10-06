//
//  MimicApplicationLaunch.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import MimicCore

/// Repeated launches request navigation from the owner without constructing a second task queue.
enum MimicApplicationLaunch: String {
    case panel, tasks, setup, uninstall, background

    static let notification = Notification.Name("local.vmaslov.Mimic.launch")

    init(arguments: [String]) {
        if arguments.contains("--uninstall-integration") { self = .uninstall }
        else if arguments.contains("--setup") { self = .setup }
        else if arguments.contains("--show-tasks") { self = .tasks }
        else if arguments.contains("--mcp-background") { self = .background }
        else { self = .panel }
    }

    /// Wait for the owner's bridge: a concurrent cold launch may still be installing its observers.
    @MainActor func forward() async throws {
        guard self != .background else { return }
        for _ in 0..<50 {
            if (try? await MimicSocket.call(.init(method: "get_state"))) != nil {
                DistributedNotificationCenter.default().postNotificationName(Self.notification, object: self.rawValue, userInfo: nil, deliverImmediately: true)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MimicBridgeError.unavailable
    }
}
