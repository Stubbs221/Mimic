//
//  XcodeCompilationProgress.swift
//  Mimic
//
//  Created by Василий Маслов on 22.10.2026.
@preconcurrency import ApplicationServices
import AppKit
import Combine
import Foundation
import MimicCore

/// Live Accessibility grant: macOS announces changes before the trust value settles, so it is re-read shortly after.
@MainActor final class AccessibilityTrustObserver: ObservableObject {
    static let shared = AccessibilityTrustObserver()
    @Published private(set) var trusted = AXIsProcessTrusted()
    private var observers: [NSObjectProtocol] = []
    private init() {
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            Task { @MainActor in AccessibilityTrustObserver.shared.refresh(after: .milliseconds(500)) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AccessibilityTrustObserver.shared.refresh(after: .zero) }
        })
    }
    func refresh(after delay: Duration) {
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            let value = AXIsProcessTrusted()
            if value != trusted { trusted = value }
        }
    }
}

/// Reads only the pinned workspace's toolbar, never editors, console output or debug variables.
enum XcodeCompilationProgress {
    /// macOS owns the final grant; this only presents its normal Accessibility access request.
    @MainActor static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    static var hasAccess: Bool { AXIsProcessTrusted() }

    /// Enabled execution controls belong to Xcode's debugger; no console or variables are read.
    static func debuggerIsAttached(processID: pid_t, workspace: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        func label(_ element: AXUIElement) -> String { (attribute(element, kAXDescriptionAttribute) as? String) ?? (attribute(element, kAXTitleAttribute) as? String) ?? "" }
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 32 else { return false }
        let canonical = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path
        for window in windows {
            let groups = children(window).filter { attribute($0, kAXIdentifierAttribute) as? String == "Workspace window tab content" }
            for group in groups where URL(fileURLWithPath: label(group)).resolvingSymlinksInPath().path == canonical {
                var queue = [(group, 0)], count = 0
                while !queue.isEmpty, count < 128 {
                    let (element, depth) = queue.removeFirst(); count += 1
                    if label(element) == "debug bar" {
                        return children(element).contains { child in
                            attribute(child, kAXRoleAttribute) as? String == kAXButtonRole && ["pause", "continue"].contains(label(child)) && (attribute(child, kAXEnabledAttribute) as? NSNumber)?.boolValue == true
                        }
                    }
                    if depth < 4 { queue += children(element).map { ($0, depth + 1) } }
                }
            }
        }
        return false
    }
    /// The toolbar indicator's completed fraction; the caption comes from Xcode's own progress messages.
    static func read(processID: pid_t, workspace: String) -> BuildExecutionProgress? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
            return result
        }
        func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 32 else { return nil }
        let matching = windows.filter { window in
            var queue = [(window, 0)], count = 0
            while !queue.isEmpty, count < 64 {
                let (element, depth) = queue.removeFirst(); count += 1
                if attribute(element, kAXIdentifierAttribute) as? String == "Workspace window tab content",
                   let path = attribute(element, kAXDescriptionAttribute) as? String, path.hasPrefix("/"), canonical(path) == canonical(workspace) { return true }
                if depth < 3 { queue += children(element).map { ($0, depth + 1) } }
            }
            return false
        }
        guard matching.count == 1, let window = matching.first else { return nil }
        let toolbars = children(window).filter { attribute($0, kAXRoleAttribute) as? String == kAXToolbarRole }
        var values: [BuildExecutionProgress] = []
        for toolbar in toolbars {
            var queue = [toolbar], count = 0
            while !queue.isEmpty, count < 256 {
                let parent = queue.removeFirst(); count += 1
                let items = children(parent)
                for item in items where attribute(item, kAXRoleAttribute) as? String == kAXProgressIndicatorRole {
                    guard let value = attribute(item, kAXValueAttribute) as? NSNumber else { continue }
                    let minimum = (attribute(item, kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
                    let maximum = (attribute(item, kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? 1
                    guard maximum > minimum else { continue }
                    let fraction = (value.doubleValue - minimum) / (maximum - minimum)
                    guard fraction.isFinite, (0...1).contains(fraction) else { continue }
                    // Fraction only: the label beside the indicator is the project name, and alternating it with
                    // Xcode's step messages made the caption flicker on every poll.
                    values.append(.init(operation: nil, fraction: fraction))
                }
                queue += items
            }
        }
        return values.count == 1 ? values.first : nil
    }
}
