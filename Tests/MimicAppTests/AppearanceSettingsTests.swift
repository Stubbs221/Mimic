//
//  AppearanceSettingsTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 08.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct AppearanceSettingsTests {
    /// Render both themes and large text using inert fixtures, without launching any work.
    @Test func compactCardsRenderAtBothWidthsAndLargeText() async throws {
        let suite = "AppearanceCards-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: "/private/tmp/MimicAppearanceCards-20261008")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in PanelAppearance.allCases {
            model.appearance.select(appearance)
            for dark in [false, true] {
                for scale in [CGFloat(1), 2] {
                    let width = appearance.panelWidth - 64
                    let content = AppearanceSettingsContent(model: model).padding(16)
                        .modifier(MimicAppearanceRoot(store: model.appearance))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.mimicTextScale, scale).frame(width: width)
                        .background(Color(nsColor: appearance == .tileGrid ? MimicTheme.native("paper", dark: dark) : .windowBackgroundColor))
                    let host = NSHostingView(rootView: content)
                    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.close() }
                    let size = host.fittingSize
                    #expect(abs(size.width - width) < 1 && size.height > 350)
                    window.setContentSize(size); host.frame = .init(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(80))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(appearance.rawValue)-\(dark ? "dark" : "light")-\(Int(scale)).png"))
                }
            }
        }
        #expect(model.records.isEmpty)
    }

}
