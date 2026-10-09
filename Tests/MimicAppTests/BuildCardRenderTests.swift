// Created by Василий Маслов on 09.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct BuildCardRenderTests {
    /// Measure the production grid beside another tile; isolated content can hide a broken height contract.
    @Test(arguments: ["empty", "running", "succeeded", "failed"])
    func compactCardsKeepNeighbourHeightAndVisibleControls(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildCardRender-" + UUID().uuidString)
        let suite = "BuildCardRender-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let scheme = "InfrastructureDependencyRegistryConfigurationSelectedTests"
        let destination = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let project = ProjectContext(path: root.path, branch: "feature/very-long-branch-layout", commit: "fixture", developerDirectory: "/fixture/Developer")
        var parameters = BuildParameters(scheme: scheme, destinationID: destination); parameters.intent = .run
        if state == "succeeded" || state == "failed" {
            var record = BuildActivity(project: project, parameters: parameters, source: "Codex")
            record.status = state == "succeeded" ? .succeeded : .failed; record.phase = "build.phase." + state
            record.startedAt = Date().addingTimeInterval(-268); record.finishedAt = Date(); record.completedStages = state == "succeeded" ? 3 : 1
            if state == "failed" { record.errorCode = "stage.installation" }
            try BuildHistoryStore(directory: root).save([record])
        }
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"]!)
        let builds = BuildCoordinator(directory: root, helper: helper, defaults: defaults, inspect: { $0 }, resolveDeveloper: { $0.developerDirectory! }, makeCommand: { _, _ in .init(executable: "/bin/bash", arguments: ["-c", "printf 'FIXTURE\\n'; sleep 30"], directory: "/private/tmp", environment: ["PATH": "/usr/bin:/bin"]) }, discover: { _, _, _, _, _ in
            var catalogue = BuildCatalogue(); catalogue.schemes = [scheme]; catalogue.configurations = ["Debug"]
            catalogue.destinations = [.init(id: destination, name: "iPhone с длинным названием устройства Simulator")]; return catalogue
        })
        let model = TaskCoordinator(directory: root, buildCoordinator: builds, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path; model.aiUsage.stop()
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        builds.savePanelDraft(parameters, project: project, developer: "/fixture/Developer")
        if state == "running" {
            let record = try await builds.submit(id: UUID(), project: project, parameters: parameters, source: "Codex")
            builds.start(record)
            for _ in 0..<100 { if builds.active?.status == .running { break }; try await Task.sleep(for: .milliseconds(10)) }
        }
        let output = URL(fileURLWithPath: "/private/tmp/Mimic-equal-height-native-20261009")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for full in [false, true] {
            model.panelLayout.begin()
            model.panelLayout.edit { $0.rows = full ? [.init(slots: [.builds]), .init(slots: [.bootstrap, .derivedDataCleanup])] : [.init(slots: [.builds, .derivedDataCleanup]), .init(slots: [.bootstrap])] }
            model.panelLayout.finish()
            for (width, scale) in [(CGFloat(360), CGFloat(1)), (560, 1), (560, 1.5)] { for dark in [false, true] {
                let frames = PanelFrameStore()
                let view = NSHostingView(rootView: PanelGrid(model: model, layout: model.panelLayout, frameStore: frames).frame(width: width)
                    .environment(\.mimicPanelAppearance, .tileGrid).environment(\.mimicTextScale, scale).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua); window.contentView = view
                view.frame = .init(origin: .zero, size: .init(width: width, height: view.fittingSize.height)); view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                let frame = try #require(frames.logical["builds"]), neighbour = try #require(frames.logical["derivedDataCleanup"]), bootstrap = try #require(frames.logical["bootstrap"])
                #expect(abs(frame.height - 160 * scale) < 1)
                #expect(abs(frame.height - neighbour.height) < 1)
                #expect(abs(frame.height - bootstrap.height) < 1)
                // SwiftPM does not expose AX children. Check intrinsic content fit and inspect the production-grid renders.
                let controls = NSHostingView(rootView: BuildCardView(model: model, builds: builds, full: full)
                    .environment(\.mimicPanelAppearance, .tileGrid).environment(\.mimicTextScale, scale).frame(width: frame.width - 24))
                #expect(controls.fittingSize.height <= frame.height - 22 - max(20, 16 * scale) - 6 + 1)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(state)-\(full ? "full" : "mini")-\(Int(width))-\(scale)-\(dark ? "dark" : "light").png")); window.contentView = nil; window.close()
            } }
        }
        if let active = builds.active {
            builds.cancel(active.id)
            for _ in 0..<200 { if !builds.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
            #expect(!builds.busy)
        }
    }
}
