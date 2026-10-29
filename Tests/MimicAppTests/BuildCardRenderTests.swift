// Created by Василий Маслов on 09.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct BuildCardRenderTests {
    /// Exercise the mounted view's timer, including a later remount of the same saved result.
    @Test(arguments: [false, true], [BuildStatus.succeeded, .failed])
    func compactSuccessExpiresButFailuresRemain(full: Bool, status: BuildStatus) async throws {
        let suite = "BuildCardExpiry-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let project = ProjectContext(path: root.path, branch: "fixture", commit: "fixture")
        var record = BuildActivity(project: project, parameters: .init(scheme: "Fixture"), source: "fixture")
        record.status = status; record.phase = "build.phase." + status.rawValue
        record.startedAt = Date().addingTimeInterval(-12); record.finishedAt = Date().addingTimeInterval(-3)
        try BuildHistoryStore(directory: root).save([record])
        let builds = BuildCoordinator(directory: root, helper: root.appendingPathComponent("unused"), defaults: defaults)
        let model = TaskCoordinator(directory: root, buildCoordinator: builds, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path; model.aiUsage.stop()
        var host = NSHostingView(rootView: BuildCardView(model: model, builds: builds, full: full)
            .environment(\.colorScheme, .light).frame(width: 520, height: 200))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 520, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer {
            window.contentView = nil; window.close(); model.stopAndExit()
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        }
        func statusPixels() throws -> Int {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var count = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if status == .succeeded {
                    if color.greenComponent > 0.4, color.greenComponent > color.redComponent * 1.4, color.greenComponent > color.blueComponent * 1.2 { count += 1 }
                } else if color.redComponent > 0.7, color.greenComponent > 0.2, color.greenComponent < color.redComponent * 0.85, color.blueComponent < color.greenComponent * 0.7 { count += 1 }
            } }
            return count
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try statusPixels() > 10)
        try await Task.sleep(for: .milliseconds(2100))
        if status == .succeeded { #expect(try statusPixels() == 0) }
        else { #expect(try statusPixels() > 10) }
        #expect(builds.records.count == 1 && builds.records.first?.status == status)
        // A fresh view must not restart the success timeout from its appearance time.
        window.contentView = nil
        host = NSHostingView(rootView: BuildCardView(model: model, builds: builds, full: full)
            .environment(\.colorScheme, .light).frame(width: 520, height: 200))
        window.contentView = host
        try await Task.sleep(for: .milliseconds(50))
        if status == .succeeded { #expect(try statusPixels() == 0) }
        else { #expect(try statusPixels() > 10) }
    }

    @Test(arguments: [false, true]) func catalogueOnlyLoadsOnIntentDespiteRepeatedViewUpdates(extended: Bool) async throws {
        let suite = "BuildCardDiscovery-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let probe = BuildCardDiscoveryProbe()
        let project = ProjectContext(path: root.path, branch: "fixture", commit: "one", developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
        let builds = BuildCoordinator(directory: root, helper: root.appendingPathComponent("unused"), defaults: defaults,
                                      resolveDeveloper: { _ in "/fixture/Developer" }, discover: { _, _, _, _, _ in try await probe.catalogue() })
        let model = TaskCoordinator(directory: root, buildCoordinator: builds, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path; model.aiUsage.stop()
        let host = NSHostingView(rootView: BuildCardView(model: model, builds: builds, extended: extended).frame(width: 520))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 520, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer {
            window.contentView = nil; window.close(); model.stopAndExit()
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        }
        // Published loading/message changes must not replace the task which is awaiting discovery.
        for index in 0..<30 {
            builds.message = "fixture \(index)"
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await probe.requests == 0)
        await builds.refreshCatalogue(project: project)
        let requests = await probe.requests
        #expect(requests == 1)
        #expect(!builds.loading)
        #expect(builds.catalogue.schemes == ["Fixture"])
        var changed = project; changed.commit = "two"; model.projects = [changed]
        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.requests == 1)
        await builds.refreshCatalogue(project: changed)
        for _ in 0..<100 {
            if await probe.requests == 2, !builds.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let refreshed = await probe.requests
        #expect(refreshed == 2)
        #expect(!builds.loading)
        #expect(builds.catalogue.schemes == ["Fixture"])
    }

    /// Measure the production grid beside another tile; isolated content can hide a broken height contract.
    @Test(arguments: ["empty", "running", "succeeded", "failed", "loading", "refreshing", "resources", "verified"])
    func compactCardsKeepNeighbourHeightAndVisibleControls(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildCardRender-" + UUID().uuidString)
        let suite = "BuildCardRender-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let scheme = "InfrastructureDependencyRegistryConfigurationSelectedTests"
        let destination = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let project = ProjectContext(path: root.path, branch: "feature/very-long-branch-layout", commit: "fixture", developerDirectory: "/fixture/Developer")
        var parameters = BuildParameters(scheme: scheme, destinationID: destination); parameters.intent = .run
        if state == "succeeded" || state == "failed" || state == "refreshing" || state == "verified" {
            var recordParameters = parameters
            if state == "verified" {
                recordParameters.operation = .test; recordParameters.intent = nil
                recordParameters.testIdentifiers = (0..<10_000).map { "Tests/Suite/test\($0)()" }
            }
            var record = BuildActivity(project: project, parameters: recordParameters, source: "Codex")
            record.status = state == "succeeded" ? .succeeded : .failed; record.phase = "build.phase." + state
            record.startedAt = Date().addingTimeInterval(-268); record.finishedAt = Date(); record.completedStages = state == "succeeded" ? 3 : 1
            if state == "verified" {
                record.status = .succeeded; record.phase = "build.phase.succeeded"
                var verification = TestVerification(); verification.verdict = "passed"; verification.methodCount = 10_000; verification.caseCoverage = "unknown"
                record.verificationSummary = BuildVerificationSummary(verification)
            }
            if state == "failed" { record.errorCode = "stage.installation" }
            try BuildHistoryStore(directory: root).save([record])
        }
        let gate = BuildCardCatalogueGate()
        let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_HOST"]!)
        let builds = BuildCoordinator(directory: root, helper: helper, defaults: defaults, inspect: { $0 }, resolveDeveloper: { $0.developerDirectory! }, makeCommand: { _, _ in .init(executable: "/bin/bash", arguments: ["-c", "printf 'FIXTURE\\n'; sleep 30"], directory: "/private/tmp", environment: ["PATH": "/usr/bin:/bin"]) }, discover: { _, _, _, _, _ in
            if state == "loading" || state == "refreshing" { await gate.wait() }
            var catalogue = BuildCatalogue(); catalogue.schemes = [scheme]; catalogue.configurations = ["Debug"]
            catalogue.destinations = [.init(id: destination, name: "iPhone с длинным названием устройства Simulator")]; return catalogue
        })
        let model = TaskCoordinator(directory: root, buildCoordinator: builds, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path; model.aiUsage.stop()
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        if state == "resources" {
            var profile = try Profile11Fixture.snapshot(directory: root).profile
            profile.buildResources = [.init(id: "assets", title: "Nebula", platform: .ios, paths: ["Generated/asset"], recoveryActionID: "restore")]
            model.activeProfile = ProfileSnapshot(profile: profile, revision: "render-resource-fixture", directory: root.path)
            model.buildResourceStates[model.buildResourceKey(project: project, platform: .ios)] = .init(checks: [.init(id: "assets", title: "Nebula", platform: .ios, status: .missing, expectedVersion: "26.10.03")])
        }
        builds.savePanelDraft(parameters, project: project, developer: "/fixture/Developer")
        await builds.restoreDraft(project: project)
        let refresh: Task<Void, Never>?
        if state == "loading" || state == "refreshing" {
            refresh = Task { await builds.refreshCatalogue(project: project) }
            for _ in 0..<100 { if builds.catalogueProgress != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
            #expect(builds.loading && builds.catalogueProgress != nil)
        } else { refresh = nil }
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
                if state == "loading" || state == "refreshing" { #expect(builds.loading && builds.catalogueProgress != nil) }
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
        await gate.finish()
        await refresh?.value
        if let active = builds.active {
            builds.cancel(active.id)
            for _ in 0..<200 { if !builds.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
            #expect(!builds.busy)
        }
    }
}

private actor BuildCardDiscoveryProbe {
    private(set) var requests = 0
    func catalogue() async throws -> BuildCatalogue {
        requests += 1
        try await Task.sleep(for: .milliseconds(150))
        var result = BuildCatalogue(); result.schemes = ["Fixture"]; result.configurations = ["Debug"]
        return result
    }
}

private actor BuildCardCatalogueGate {
    private var ready = false
    func wait() async { while !ready { try? await Task.sleep(for: .milliseconds(10)) } }
    func finish() { ready = true }
}
