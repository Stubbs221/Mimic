// Created by Василий Маслов on 04.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct BuildOverlayTests {
    @Test(arguments: ["compilation", "installation", "products", "tests", "failed", "succeeded"])
    func compactStatesFitLightDarkHighContrastAndLargeText(state: String) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/MimicBuildOverlayRenders"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "BuildOverlay-" + UUID().uuidString; let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectContext(path: "/private/tmp/MimicFixture/Платформа-и-инфраструктура/demo-client-feature-synthetic-navigationxx", branch: "feature/ios-subscription-profile-memory-diagnostics", commit: "fixture-sha", developerDirectory: "/fixture/Xcode.app/Contents/Developer")
        var parameters = BuildParameters(operation: state == "tests" ? .test : .build, scheme: "DemoInterfaceLayoutRegressionSelectedTestsXXXXX", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", testIdentifiers: state == "tests" ? ["FixtureTests/FixtureTests/testValue", "FixtureTests/FixtureTests/testOther"] : [])
        if state != "tests" { parameters.intent = .run }
        var record = BuildActivity(project: project, parameters: parameters, source: "Terminal")
        record.status = ["failed", "succeeded"].contains(state) ? (state == "failed" ? .failed : .succeeded) : .running
        record.phase = "build.phase." + (state == "compilation" ? "compile" : state == "tests" ? "test" : state)
        record.stage = state == "installation" ? .installation : state == "products" ? .products : .compilation
        record.startedAt = Date().addingTimeInterval(-130); record.tracking = .live
        record.destinationName = "QA iPhone с длинным названием · iOS 26.5"
        if state == "compilation" {
            record.executionProgress = .init(operation: "Compile SubscriptionNavigationController.swift (arm64)", completedOperations: 128)
        } else if state == "tests" {
            record.completedTestCount = 1
        } else {
            record.completedStages = state == "succeeded" ? 3 : 1
        }
        if state == "products" { record.products = [.init(name: "DemoApp", path: "/fixture/One.app", bundleIdentifier: "fixture.one"), .init(name: "Другое приложение с длинным именем", path: "/fixture/Two.app", bundleIdentifier: "fixture.two")] }
        if state == "failed" { record.errorCode = "stage.products"; record.finishedAt = Date() }
        if state == "succeeded" { record.finishedAt = Date() }
        let store = BuildHistoryStore(directory: root); try store.save([record]); try Data("Compile /fixture/Frameworks/ProfileWebView/SubscriptionNavigationController.swift\nerror: намеренная ошибка приёмки 🙂\nTarget/Class/testMethod\nСохранён ограниченный журнал\nПоследняя строка\n".utf8).write(to: store.logURL(record.id))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.stopAndExit() }
        #expect(model.builds.overlayWidth == 360)
        #expect(BuildActivityPanel.preferredWidth == 360)
        for width in [CGFloat(320), 360] { for dark in [false, true] { for scale in [CGFloat(1), 1.5] {
            model.builds.overlayWidth = width
            let view = NSHostingView(rootView: BuildOverlayContent(builds: model.builds, record: record, hide: {}).environment(\.mimicPanelAppearance, .tileGrid).environment(\.mimicTextScale, scale).environment(\.colorScheme, dark ? .dark : .light).frame(width: width))
            let height = view.fittingSize.height
            #expect(height > 120 && height < 600)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false); window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .aqua); window.contentView = view; view.frame = window.contentView!.bounds
            view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
            #expect(view.fittingSize.width <= width + 1)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(state)-\(Int(width))-\(scale)-" + (dark ? "dark-contrast.png" : "light.png"))); window.contentView = nil; window.close()
        } } }
        #expect(!BuildFloatingPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false).canBecomeKey)
    }
}
