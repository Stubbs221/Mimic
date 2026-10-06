//
//  AppIconSettings.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import Combine

/// Stable preference identifiers; the plugin mark is deliberately independent.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case emboss, enamel, frostedGlass

    var id: String { self.rawValue }
    var localizationKey: String { "app.icon." + self.rawValue }
}

/// Loads checked-in Composer renders for packaged apps and SwiftPM development.
@MainActor
enum AppIconResources {
    static var usesModernRendering: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    static func image(style: AppIconStyle, dark: Bool, modern: Bool) -> NSImage? {
        let name = "app-icon-\(style.rawValue)-\(modern ? "modern" : "legacy")-\(dark ? "dark" : "light")"
        guard let url = MimicResources.bundle.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Commits preferences only after a render loads; nil restores the bundle's native icon.
@MainActor
final class AppIconSettings: ObservableObject {
    // MARK: - Presentation

    @Published private(set) var style: AppIconStyle
    @Published private(set) var error: String?
    @Published private(set) var dark = false
    let modern: Bool
    private let defaults: UserDefaults
    private let loadImage: (AppIconStyle, Bool, Bool) -> NSImage?
    private let applyImage: (NSImage?) -> Void
    private var activated = false

    init(defaults: UserDefaults = .standard, modern: Bool = AppIconResources.usesModernRendering,
         loadImage: @escaping (AppIconStyle, Bool, Bool) -> NSImage? = { AppIconResources.image(style: $0, dark: $1, modern: $2) },
         applyImage: @escaping (NSImage?) -> Void = { NSApp.applicationIconImage = $0 }) {
        self.defaults = defaults
        self.modern = modern
        self.loadImage = loadImage
        self.applyImage = applyImage
        self.style = defaults.string(forKey: "app.icon.style").flatMap(AppIconStyle.init(rawValue:)) ?? .emboss
    }

    // MARK: - Lifecycle and selection

    /// Called by the app owner, so constructing a view or fixture cannot change the real app icon.
    func activate(dark: Bool) {
        self.dark = dark
        self.activated = true
        if !self.apply(self.style) {
            self.style = .emboss
            self.defaults.set(self.style.rawValue, forKey: "app.icon.style")
            self.applyImage(nil)
            self.error = text("app.icon.startupError")
        }
    }

    func select(_ style: AppIconStyle) {
        guard self.apply(style) else { return }
        self.style = style
        self.defaults.set(style.rawValue, forKey: "app.icon.style")
    }

    func appearanceChanged(dark: Bool) {
        guard self.dark != dark else { return }
        self.dark = dark
        if self.activated { _ = self.apply(self.style) }
    }

    func preview(_ style: AppIconStyle) -> NSImage? {
        self.loadImage(style, self.dark, self.modern)
    }

    // MARK: - Application

    private func apply(_ style: AppIconStyle) -> Bool {
        if style == .emboss {
            self.applyImage(nil)
        } else {
            guard let image = self.loadImage(style, self.dark, self.modern), image.isValid else {
                self.error = text("app.icon.error")
                return false
            }
            self.applyImage(image)
        }
        self.error = nil
        return true
    }
}
