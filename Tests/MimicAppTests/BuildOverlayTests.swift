// Created by Василий Маслов on 04.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct BuildOverlayTests {
    @Test func longNamesAndLogsFitLightDarkAndHighContrast() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/MimicBuildOverlayRenders"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "BuildOverlay-" + UUID().uuidString; let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectContext(path: "/private/tmp/MimicFixture/Платформа-и-инфраструктура/demo-client-feature-synthetic-navigationxx", branch: "feature/ios-subscription-profile-memory-diagnostics", commit: "fixture-sha", developerDirectory: "/fixture/Xcode.app/Contents/Developer")
        var record = BuildActivity(project: project, parameters: .init(operation: .test, scheme: "DemoInterfaceLayoutRegressionSelectedTestsXXXXX", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", testIdentifiers: ["FixtureTests/FixtureTests/testValue"]), source: "Terminal")
        record.status = .failed; record.phase = "build.phase.failed"; record.startedAt = Date().addingTimeInterval(-130); record.finishedAt = Date(); record.tracking = .live
        let store = BuildHistoryStore(directory: root); try store.save([record]); try Data("Compile /fixture/Frameworks/ProfileWebView/SubscriptionNavigationController.swift\nerror: намеренная ошибка приёмки 🙂\nTarget/Class/testMethod\nСохранён ограниченный журнал\nПоследняя строка\n".utf8).write(to: store.logURL(record.id))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        for dark in [false, true] {
            let view = NSHostingView(rootView: BuildOverlayView(builds: model.builds, hide: {}).environment(\.colorScheme, dark ? .dark : .light).frame(width: 360))
            let height = view.fittingSize.height
            #expect(height > 180 && height < 302)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: height), styleMask: [.borderless], backing: .buffered, defer: false); window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .aqua); window.contentView = view; view.frame = window.contentView!.bounds
            view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
            #expect(view.fittingSize.width <= 361)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(dark ? "dark-contrast.png" : "light.png")); window.close()
        }
        #expect(!BuildFloatingPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false).canBecomeKey)
    }
}
