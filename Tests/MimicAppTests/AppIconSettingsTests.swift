//
//  AppIconSettingsTests.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import SwiftUI
import Testing
@testable import Mimic

@Suite(.serialized)
@MainActor
struct AppIconSettingsTests {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "AppIconSettings-" + UUID().uuidString
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func image() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { bounds in
            NSColor.red.setFill(); bounds.fill(); return true
        }
    }

    @Test func defaultsAndUnknownValuesRestoreNativeIcon() throws {
        let (defaults, suite) = try self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var applied = 0
        let make = { AppIconSettings(defaults: defaults, loadImage: { _, _, _ in nil }, applyImage: { image in
            #expect(image == nil); applied += 1
        }) }
        let fresh = make()
        #expect(fresh.style == .emboss)
        #expect(applied == 0)
        fresh.activate(dark: false)
        #expect(applied == 1)
        defaults.set("retired-style", forKey: "app.icon.style")
        let unknown = make()
        #expect(unknown.style == .emboss)
        unknown.activate(dark: true)
        #expect(applied == 2)
    }

    @Test func selectionPersistsAndRestartsWithoutChangingPlugin() throws {
        let (defaults, suite) = try self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = self.image()
        var applied: [NSImage?] = []
        let settings = AppIconSettings(defaults: defaults, loadImage: { _, _, _ in image }, applyImage: { applied.append($0) })
        settings.activate(dark: false)
        for style in [AppIconStyle.enamel, .frostedGlass] {
            settings.select(style)
            #expect(settings.style == style)
            #expect(defaults.string(forKey: "app.icon.style") == style.rawValue)
            #expect(applied.last! === image)
        }
        let restored = AppIconSettings(defaults: defaults, loadImage: { _, _, _ in image }, applyImage: { applied.append($0) })
        restored.activate(dark: false)
        #expect(restored.style == .frostedGlass)
        #expect(applied.last! === image)
        restored.select(.emboss)
        #expect(applied.last! == nil)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("app.icon.") } == ["app.icon.style"])
    }

    @Test(arguments: [true, false]) func themeReloadUsesCorrectGeneration(modern: Bool) throws {
        let (defaults, suite) = try self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = self.image()
        defaults.set("enamel", forKey: "app.icon.style")
        var loaded: [(AppIconStyle, Bool, Bool)] = []
        let settings = AppIconSettings(defaults: defaults, modern: modern, loadImage: { style, dark, generation in
            loaded.append((style, dark, generation)); return image
        }, applyImage: { _ in })
        settings.activate(dark: false)
        settings.appearanceChanged(dark: true)
        settings.appearanceChanged(dark: true)
        #expect(loaded.count == 2)
        #expect(loaded[0].0 == .enamel && !loaded[0].1 && loaded[0].2 == modern)
        #expect(loaded[1].0 == .enamel && loaded[1].1 && loaded[1].2 == modern)
    }

    @Test func failedSelectionKeepsLastWorkingPreferenceAndImage() throws {
        let (defaults, suite) = try self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = self.image()
        var applied = 0
        let settings = AppIconSettings(defaults: defaults, loadImage: { style, _, _ in style == .enamel ? image : nil }, applyImage: { _ in applied += 1 })
        settings.activate(dark: false)
        settings.select(.enamel)
        settings.select(.frostedGlass)
        #expect(settings.style == .enamel)
        #expect(defaults.string(forKey: "app.icon.style") == "enamel")
        #expect(applied == 2)
        #expect(settings.error != nil)
        settings.select(.emboss)
        #expect(settings.error == nil)
    }

    @Test func missingStartupRenderRestoresNativeIcon() throws {
        let (defaults, suite) = try self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("frostedGlass", forKey: "app.icon.style")
        var restored = false
        let settings = AppIconSettings(defaults: defaults, loadImage: { _, _, _ in nil }, applyImage: { restored = $0 == nil })
        settings.activate(dark: true)
        #expect(restored)
        #expect(settings.style == .emboss)
        #expect(defaults.string(forKey: "app.icon.style") == "emboss")
        #expect(settings.error != nil)
    }

    /// Render only the changed settings card; no task coordinator, queue or real checkout is created.
    @Test func packagedResourcesAndCardFitAtPanelWidth() throws {
        let (defaults, suite) = try self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppIconSettings(defaults: defaults, applyImage: { _ in })
        let output = ProcessInfo.processInfo.environment["MIMIC_ICON_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for modern in [true, false] {
            for dark in [true, false] {
                for style in AppIconStyle.allCases {
                    #expect(try #require(AppIconResources.image(style: style, dark: dark, modern: modern)).isValid)
                }
            }
        }
        for dark in [true, false] {
            settings.appearanceChanged(dark: dark)
            for style in AppIconStyle.allCases {
                settings.select(style)
                let view = NSHostingView(rootView: AppIconSettingsView(settings: settings).environment(\.colorScheme, dark ? .dark : .light).frame(width: 408))
                let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view
                defer { window.close() }
                let size = view.fittingSize
                #expect(abs(size.width - 408) < 1)
                #expect(size.height > 120 && size.height < 300)
                view.frame = NSRect(origin: .zero, size: size); view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let output { try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(style.rawValue)-\(dark ? "dark" : "light").png")) }
            }
        }
    }

    @Test func missingPreviewsAndErrorFitAtNarrowWidth() throws {
        let (defaults, suite) = try self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppIconSettings(defaults: defaults, loadImage: { _, _, _ in nil }, applyImage: { _ in })
        settings.select(.frostedGlass)
        #expect(settings.style == .emboss)
        #expect(settings.error != nil)
        let output = ProcessInfo.processInfo.environment["MIMIC_ICON_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        for width in [CGFloat(320), 408] {
            for dark in [false, true] {
                let view = NSHostingView(rootView: AppIconSettingsView(settings: settings)
                    .environment(MimicAppearancePreview(increasedContrast: true))
                    .environment(\.colorScheme, dark ? .dark : .light).frame(width: width))
                let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                window.contentView = view
                defer { window.close() }
                let size = view.fittingSize
                #expect(abs(size.width - width) < 1)
                #expect(size.height < 340)
                view.frame = NSRect(origin: .zero, size: size); view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let output { try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("missing-\(Int(width))-\(dark ? "dark" : "light").png")) }
            }
        }
    }
}
