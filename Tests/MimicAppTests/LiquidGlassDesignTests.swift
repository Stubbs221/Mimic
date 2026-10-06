//
//  LiquidGlassDesignTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 03.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized)
@MainActor
struct LiquidGlassDesignTests {
    /// Accessibility variations exercise the actual hosted UI, including the opaque branch.
    /// The data boundary supplies all fixtures; no checkout command can execute.
    @Test
    func panelAndPinnedCardFitWithAccessibilityAndWorstCaseData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicGlass-" + UUID().uuidString)
        let suite = "MimicGlass-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let output = ProcessInfo.processInfo.environment["MIMIC_GLASS_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for dataset in ["demo", "worst", "empty", "one", "large"] {
            model.installBootstrapPreview()
            let pinned = model.quickBootstrapActivity?.request
            let project = ProjectContext(path: "/private/tmp/Mimic-fixture/MobilePlatformInfrastructureCheckout", branch: dataset == "worst" ? "feature/infrastructure/dependency-registry-bootstrap-diagnostics" : "fixture", commit: "fixture")
            model.projects = [project]; model.selectedProjectPath = dataset == "empty" ? "" : project.path
            model.records = []; model.simulators = []
            model.readiness = [.bootstrap: [], .generation: [], .localization: [], .proto: [], .format: [], .simulatorBoot: ["fixture"]]
            let count = dataset == "empty" ? 0 : dataset == "large" ? 100 : 1
            for index in 0..<count {
                var record = index == 0 ? try #require(pinned) : TaskRecord(action: .bootstrap, project: project, options: .standard(platform: .tvos))
                record.status = .failed; record.exitCode = 1
                record.error = dataset == "worst" ? "/Fastlane/fastfiles/project_dependency_registry_configuration:223: invalid multibyte char (US-ASCII). Не удалось подготовить зависимости рабочего проекта." : "Fixture error"
                model.records.append(record)
            }
            model.selectedTaskID = model.records.first?.id
            if dataset == "worst" { model.openSettings(group: .aiIntegrations) } else { model.revealSection(.tasks) }
            for mode in ["normal", "opaque", "contrast", "motion", "combined"] {
                for dark in [false, true] {
                    let opaque = mode == "opaque" || mode == "combined"
                    let contrast = mode == "contrast" || mode == "combined"
                    let motion = mode == "motion" || mode == "combined"
                    let panel = MimicPanel(model: model)
                        .environment(MimicAppearancePreview(reduceTransparency: opaque, reduceMotion: motion, increasedContrast: contrast))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .frame(width: 440, height: 420)
                    let name = "\(dataset)-\(mode)-\(dark ? "dark" : "light")"
                    try await self.render(panel, width: 440, height: 420, name: name, output: output)
                    if dataset != "empty" {
                        let card = QuickBootstrapView(model: model, showMimic: {})
                            .environment(MimicAppearancePreview(reduceTransparency: opaque, reduceMotion: motion, increasedContrast: contrast))
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let host = NSHostingView(rootView: card)
                        let size = host.fittingSize
                        #expect(abs(size.width - 320) < 1)
                        #expect(size.height < 300)
                        try await self.render(card, width: 320, height: size.height, name: "card-" + name, output: output)
                    }
                }
            }
        }
    }

    @Test
    func standaloneAndGroupedIconButtonsKeepCompactGeometry() {
        for opaque in [false, true] {
            for grouped in [false, true] {
                let view = NSHostingView(rootView: BootstrapIconButton(symbol: "terminal", label: text("terminal.show"), action: {}, inControlBar: grouped)
                    .environment(MimicAppearancePreview(reduceTransparency: opaque)))
                view.layoutSubtreeIfNeeded()
                #expect(view.fittingSize.width >= 30 && view.fittingSize.width <= 34, "Icon width: \(view.fittingSize.width), opaque=\(opaque), grouped=\(grouped)")
                #expect(view.fittingSize.height >= 30 && view.fittingSize.height <= 34, "Icon height: \(view.fittingSize.height), opaque=\(opaque), grouped=\(grouped)")
            }
        }
    }

    @Test
    func ciLaunchActionsWrapWithoutClippingTheirLabels() {
        let actions = MimicActionLayout {
            CILaunchButton(kind: .uiTests) {}
            CILaunchButton(kind: .qualityGates) {}
            CILaunchButton(kind: .beta) {}
        }
        let wide = NSHostingView(rootView: actions.frame(width: 384))
        let narrow = NSHostingView(rootView: actions.frame(width: 160))
        wide.layoutSubtreeIfNeeded(); narrow.layoutSubtreeIfNeeded()
        #expect(abs(wide.fittingSize.width - 384) < 1)
        #expect(abs(narrow.fittingSize.width - 160) < 1)
        #expect(wide.fittingSize.height == 28)
        #expect(narrow.fittingSize.height > wide.fittingSize.height)
        #expect(narrow.fittingSize.height <= 100)
    }

    private func render<V: View>(_ root: V, width: CGFloat, height: CGFloat, name: String, output: URL?) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: name.hasSuffix("-dark") ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        let view = NSHostingView(rootView: root)
        window.contentView = view; view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(2))
        #expect(view.fittingSize.width <= width + 1)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(width))
        if let output { try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png")) }
    }
}
