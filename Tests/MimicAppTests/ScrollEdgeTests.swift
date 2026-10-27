//
//  ScrollEdgeTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 23.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor
struct ScrollEdgeTests {
    @Test func nativeMaskReversesAndResizingKeepsTheInteriorSharp() throws {
        for direction in [MimicScrollEdge.Direction.top, .bottom] {
            let edge = NativeScrollEdge(direction: direction, color: .white)
            edge.frame = NSRect(x: 0, y: 0, width: 560, height: 24)
            edge.layoutSubtreeIfNeeded()
            let backdrop = try #require(edge.subviews.compactMap { $0 as? NSVisualEffectView }.first)
            #expect(backdrop.blendingMode == .withinWindow && backdrop.material == .headerView)
            #expect(edge.backgroundFilters.isEmpty && !edge.layerUsesCoreImageFilters)
            #expect(edge.subviews.last?.layer is CAGradientLayer)
            let mask = try #require(backdrop.maskImage)
            let top = try sample(mask, fraction: 0), bottom = try sample(mask, fraction: 1)
            #expect(direction == .top ? top > 0.98 && bottom < 0.02 : bottom > 0.98 && top < 0.02)
            #expect(edge.hitTest(NSPoint(x: 30, y: 12)) == nil && !edge.acceptsFirstResponder)
            edge.update(direction: direction, color: .black)
            edge.layoutSubtreeIfNeeded()
            #expect(backdrop.maskImage === mask)
            edge.frame.size = NSSize(width: 320, height: 48)
            edge.layoutSubtreeIfNeeded()
            let resizedMask = try #require(backdrop.maskImage)
            #expect(resizedMask !== mask && backdrop.frame == edge.bounds)
            let middle = try sample(resizedMask, fraction: 0.5)
            #expect(middle > 0.45 && middle < 0.55)
        }
    }

    /// Exercise both retained production documents with disposable settings and no project actions.
    @Test func productionEdgesRemainFixedWhileDocumentsAndAccessibilityChange() async throws {
        let suite = "ScrollEdge-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        model.aiUsage.stop()
        model.appearance.select(.tileGrid)
        model.panelVisibilityChanged(true)
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        model.motionSettings.reduceMotionOverride = true
        defer {
            model.ci.setVisible(false)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: MimicPanel(model: model).frame(width: 560, height: 420))
        window.contentView = host
        try await layout(host)
        let home = try #require(scroll(in: host, id: "page.home"))
        let before = edges(in: host).filter { !$0.isHiddenOrHasHiddenAncestor }
        #expect(before.count == 2)
        #expect(before.allSatisfy { abs($0.bounds.height - 24) < 0.5 && abs($0.bounds.width - home.bounds.width) < 1 })
        let positions = before.map { $0.convert($0.bounds, to: host) }
        home.contentView.scroll(to: NSPoint(x: 0, y: 80)); home.reflectScrolledClipView(home.contentView)
        try await layout(host)
        #expect(before.map { $0.convert($0.bounds, to: host) } == positions)
        #expect(scroll(in: host, id: "page.home") === home)
        model.openSettings(source: .keyboard)
        try await layout(host)
        let settings = try #require(scroll(in: host, id: "page.settings"))
        let settingsEdges = edges(in: host).filter { !$0.isHiddenOrHasHiddenAncestor }
        #expect(settingsEdges.count == 2)
        #expect(settingsEdges.allSatisfy { abs($0.bounds.width - settings.bounds.width) < 1 })
        for opaque in [true, false] {
            model.motionSettings.reduceTransparencyOverride = opaque
            try await layout(host)
            #expect(edges(in: host).filter { !$0.isHiddenOrHasHiddenAncestor }.count == (opaque ? 0 : 2))
            #expect(scroll(in: host, id: "page.settings") === settings)
        }
        model.motionSettings.contrastOverride = true
        try await layout(host)
        #expect(edges(in: host).filter { !$0.isHiddenOrHasHiddenAncestor }.isEmpty)
    }

    private func sample(_ image: NSImage, fraction: CGFloat) throws -> Double {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let color = try #require(bitmap.colorAt(x: 0, y: Int(CGFloat(bitmap.pixelsHigh - 1) * fraction)))
        return color.alphaComponent
    }
    private func edges(in view: NSView) -> [NativeScrollEdge] {
        (view as? NativeScrollEdge).map { [$0] } ?? view.subviews.flatMap { edges(in: $0) }
    }
    private func scroll(in view: NSView, id: String) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.identifier?.rawValue == id { return scroll }
        return view.subviews.lazy.compactMap { scroll(in: $0, id: id) }.first
    }
    private func layout(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        view.layoutSubtreeIfNeeded()
    }
}
