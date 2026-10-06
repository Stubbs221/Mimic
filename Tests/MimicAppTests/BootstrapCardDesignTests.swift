// Created by Василий Маслов on 03.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized)
@MainActor
struct BootstrapCardDesignTests {
    /// Only display data is injected: these fixtures cannot enter the launch queue.
    @Test
    func rendersEveryStateAndWorstCaseAtBothWidths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapCardDesign-" + UUID().uuidString)
        let suite = "BootstrapCardDesign-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        let project = ProjectContext(path: "/private/tmp/fixture", branch: "fixture", commit: "fixture")
        model.projects = [project]; model.selectedProjectPath = project.path
        model.bootstrapOptions = .standard()
        let output = ProcessInfo.processInfo.environment["MIMIC_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for state in ["ready", "success", "failed", "cancelled", "running", "queued", "blocked", "missing", "no-checkout", "long-error", "tvos"] {
            model.records = []; model.launchState = .idle; model.readiness[.bootstrap] = []; model.selectedProjectPath = project.path
            model.bootstrapOptions = .standard()
            if state == "tvos" { model.selectBootstrapPlatform(.tvos) }
            if ["success", "failed", "cancelled", "running", "queued", "blocked", "long-error"].contains(state) {
                var record = TaskRecord(action: .bootstrap, project: project, options: model.bootstrapOptions)
                record.startedAt = Date().addingTimeInterval(-7)
                record.status = state == "success" ? .succeeded : state == "running" ? .running : state == "queued" || state == "blocked" ? .queued : state == "cancelled" ? .cancelled : .failed
                if record.status != .running, record.status != .queued { record.finishedAt = Date() }
                if record.status == .failed { record.error = state == "long-error" ? String(repeating: "ОченьДлинноеНеразрывноеИмяЗависимости ", count: 20) : "Ошибка конфигурации проекта" }
                model.records = [record]
                if state == "blocked" { model.launchState = .blockedByXcode(record.id) }
            }
            if state == "missing" { model.readiness[.bootstrap] = ["ruby", "mint", "bundler"] }
            if state == "no-checkout" { model.selectedProjectPath = "" }
            for width in [CGFloat(408), 320] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                    let dark = appearance == .darkAqua || appearance == .accessibilityHighContrastDarkAqua
                    let contrast = appearance == .accessibilityHighContrastAqua || appearance == .accessibilityHighContrastDarkAqua
                    let view = NSHostingView(rootView: BootstrapCard(model: model)
                        .environment(MimicAppearancePreview(increasedContrast: contrast))
                        .environment(\.colorScheme, dark ? .dark : .light).frame(width: width))
                    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
                    window.contentView = view
                    defer { window.close() }
                    let size = view.fittingSize
                    #expect(abs(size.width - width) < 1)
                    #expect(size.height > 100 && size.height < (state == "long-error" ? 1000 : 500))
                    view.frame = NSRect(origin: .zero, size: size); view.layoutSubtreeIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide >= Int(width))
                    if let output { try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("card-\(state)-\(Int(width))-\(appearance.rawValue).png")) }
                }
            }
        }
    }
}
