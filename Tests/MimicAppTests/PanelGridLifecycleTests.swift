//
//  PanelGridLifecycleTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 08.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

private actor ColdCatalogueProbe {
    private(set) var requests = 0
    func catalogue() -> BuildCatalogue { requests += 1; return BuildCatalogue() }
}

@Suite(.serialized) @MainActor struct PanelGridLifecycleTests {
    @Test func coldCollapsedGridDoesNotQueryBuildCatalogueAndRetainsItAfterOpening() async throws {
        let suite = "ColdPanelGrid-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let probe = ColdCatalogueProbe()
        let builds = BuildCoordinator(directory: root.appendingPathComponent("Builds"), helper: root.appendingPathComponent("unused-helper"), defaults: defaults,
                                      resolveDeveloper: { _ in "/fixture/Developer" }, discover: { _, _, _, _, _ in await probe.catalogue() })
        let model = TaskCoordinator(directory: root, buildCoordinator: builds, defaults: defaults)
        model.aiUsage.stop()
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.projects = [.init(path: root.path, branch: "fixture", commit: "fixture")]
        model.selectedProjectPath = root.path
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        let host = NSHostingView(rootView: PanelGrid(model: model, layout: model.panelLayout).frame(width: 520))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 520, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let coldRequests = await probe.requests
        #expect(coldRequests == 0)
        model.panelLayout.open(.builds)
        for _ in 0..<100 {
            if await probe.requests > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let opened = await probe.requests
        #expect(opened > 0)
        model.panelLayout.open(.builds)
        try await Task.sleep(for: .milliseconds(250))
        model.panelLayout.open(.builds)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await probe.requests == opened)
    }

}
