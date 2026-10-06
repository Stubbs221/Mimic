//
//  XcodeApplications.swift
//  Mimic
//
//  Created by Василий Маслов on 02.10.2026.
import AppKit
import MimicCore

/// Observes actual application exit, not `terminate()`'s return value. Only ordinary quit is requested.
@MainActor
final class SystemXcodeApplications: XcodeApplicationService {
    private var applications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").filter { !$0.isTerminated }
    }

    var hasRunningXcode: Bool { !self.applications.isEmpty }
    private var attempt: UUID?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observer: NSObjectProtocol?
    private var deadline: Task<Void, Never>?

    func closeXcode(timeout: Duration) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let old = attempt { self.complete(old, closed: false) }
        let running = self.applications
        guard !running.isEmpty else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.attempt = id; self.continuation = continuation
                // Register before requesting quit: a fast exit must not be missed.
                self.observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, !self.hasRunningXcode else { return }
                        self.complete(id, closed: true)
                    }
                }
                self.deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self else { return }
                    self.complete(id, closed: !self.hasRunningXcode)
                }
                var accepted = true
                for application in running where !application.isTerminated {
                    if !application.terminate() { accepted = false }
                }
                if !self.hasRunningXcode { self.complete(id, closed: true) }
                else if !accepted { self.complete(id, closed: false) }
                if Task.isCancelled { self.complete(id, closed: false) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id, closed: false) }
        }
    }

    func activateXcode() { self.applications.first?.activate(options: []) }
    private func complete(_ id: UUID, closed: Bool) {
        guard self.attempt == id else { return }
        self.attempt = nil; self.deadline?.cancel(); self.deadline = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        let pending = self.continuation; self.continuation = nil; pending?.resume(returning: closed)
    }
}
