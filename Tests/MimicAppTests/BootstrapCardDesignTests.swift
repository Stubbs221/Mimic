// Created by Василий Маслов on 03.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized)
@MainActor
struct BootstrapCardDesignTests {
    /// The real grid leaves Bootstrap's text and lower surface clickable, while marked controls remain protected.
    @Test func compactGridOpensBelowPlatformControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapSurface-" + UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        model.aiUsage.stop()
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        var record = TaskRecord(action: .bootstrap, project: ProjectContext(path: root.path)); record.status = .succeeded
        model.records = [record]
        for width in [CGFloat(320), 560] {
            let host = NSHostingView(rootView: PanelGrid(model: model, layout: model.panelLayout).card(.bootstrap, row: UUID())
                .frame(width: width).environment(\.mimicPanelAppearance, .tileGrid))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
            var clicks = 0
            let bridge = PanelDragBridge.TrackingView(callbacks: PanelDragBridge(cancellationID: 0, enabled: true, candidate: { _ in .init(block: .bootstrap) }, click: { _ in clicks += 1 }, lift: { _, _, _, _ in }, move: { _, _, _, _ in }, end: { _, _, _ in }, cancel: {}))
            bridge.frame = host.bounds; host.addSubview(bridge)
            defer { bridge.stop(); window.close() }
            func markers(_ view: NSView) -> [PanelControlRegion.MarkerView] {
                (view as? PanelControlRegion.MarkerView).map { [$0] } ?? view.subviews.flatMap(markers)
            }
            let buttons = markers(host).filter { $0.bounds.height > 0 && $0.bounds.height <= 32 }
            #expect(buttons.count == 2)
            for button in buttons {
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                #expect(bridge.receive(event) === event)
            }
            let rectangles = buttons.map { host.convert($0.bounds, from: $0) }
            let point = host.convert(CGPoint(x: rectangles[0].midX, y: rectangles.map(\.maxY).max()! + 8), to: nil)
            #expect(!PanelControlRegion.MarkerView.contains(point, in: host))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                #expect(bridge.receive(event) == nil)
            }
            #expect(clicks == 1)
        }
    }

    /// Mount the production Full card at its shared grid height; Mini intentionally hides the terminal.
    @Test func terminalInsetsRemainEqualWithAdaptiveCardHeight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapInsets-" + UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path); model.projects = [project]; model.selectedProjectPath = project.path
        var record = TaskRecord(action: .bootstrap, project: project); record.status = .succeeded
        model.records = [record]
        let session = model.bootstrapTerminal(for: record)
        model.terminalOutput?(record.id, Data("| Dependency | Version |\r\n| Fixture | 1.0 |\r\n".utf8))
        for width in [CGFloat(320), 360, 440, 560] {
            for scale in [CGFloat(1), 1.5] {
                for dark in [false, true] {
                    let host = NSHostingView(rootView: BootstrapCard(model: model, mode: .full)
                        .padding(12).frame(width: width, height: MimicMetrics.collapsedCardHeight * scale)
                        .environment(\.mimicPanelAppearance, .tileGrid)
                        .environment(\.mimicTextScale, scale).environment(\.colorScheme, dark ? .dark : .light))
                    let size = host.fittingSize
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host; host.frame = CGRect(origin: .zero, size: size)
                    window.orderFront(nil); host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
                    let terminal = host.convert(session.view().bounds, from: session.view())
                    #expect(abs(terminal.minY - 12) < 1)
                    #expect(abs(host.bounds.maxY - terminal.maxY - 12) < 1)
                    #expect(size.height >= 160 * scale && size.height < 420)
                    window.close()
                }
            }
        }
    }

    /// Exercise the available terminal area, including the space reserved for the error action.
    @Test func placeholderFitsFullAndExpandedWithEnlargedText() throws {
        let output = ProcessInfo.processInfo.environment["MIMIC_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for state in [BootstrapTerminalPlaceholderState.idle, .queued, .running, .unavailable] {
            for width in [CGFloat(320), 440, 560] {
                for expanded in [false, true] {
                    for scale in [CGFloat(1), 1.5] {
                        for dark in [false, true] {
                            let terminalWidth = expanded ? width - 24 : (width - 36) * 0.6
                            let height: CGFloat = (expanded ? 240 : 128) - (state == .unavailable ? 44 : 0)
                            let view = NSHostingView(rootView: BootstrapTerminalPlaceholder(state: state, platform: .tvos)
                                .environment(\.mimicPanelAppearance, .tileGrid).environment(\.mimicTextScale, scale)
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .frame(width: terminalWidth, height: height))
                            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                            window.contentView = view
                            defer { window.close() }
                            view.frame = NSRect(x: 0, y: 0, width: terminalWidth, height: height)
                            window.setContentSize(view.frame.size); view.layoutSubtreeIfNeeded()
                            #expect(abs(view.fittingSize.height - height) < 1)
                            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            if let output {
                                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("placeholder-\(state)-\(Int(width))-\(expanded)-\(scale)-\(dark).png"))
                            }
                        }
                    }
                }
            }
        }
    }

    /// The same realistic task data must fit the actual collapsed grid, without a live executor.
    @Test func collapsedStatesFitTheirCardHeight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapCompact-" + UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: directory.lastPathComponent))
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: directory.lastPathComponent); try? FileManager.default.removeItem(at: directory) }
        let project = ProjectContext(path: directory.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        let output = ProcessInfo.processInfo.environment["MIMIC_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for state in ["ready", "running", "queued", "blocked", "closing", "success", "failed", "cancelled"] {
            model.records = []; model.launchState = .idle
            if state != "ready" {
                var record = TaskRecord(action: .bootstrap, project: project, options: .standard())
                record.startedAt = Date().addingTimeInterval(-134)
                record.status = state == "running" ? .running : ["queued", "blocked", "closing"].contains(state) ? .queued : state == "success" ? .succeeded : state == "cancelled" ? .cancelled : .failed
                if record.status != .running && record.status != .queued { record.finishedAt = Date() }
                model.records = [record]
                if state == "blocked" { model.launchState = .blockedByXcode(record.id) }
                if state == "closing" { model.launchState = .closingXcode(record.id) }
            }
            for (mode, width) in [(BootstrapCardMode.mini, CGFloat(214)), (.full, 464)] {
                for dark in [false, true] {
                    let view = NSHostingView(rootView: BootstrapCard(model: model, mode: mode).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light).frame(width: width))
                    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = view
                    defer { window.close() }
                    let size = view.fittingSize
                    #expect(size.height <= 176, "\(state) \(mode): \(size.height)")
                    view.frame = NSRect(origin: .zero, size: size); window.setContentSize(size); window.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(50)); view.layoutSubtreeIfNeeded()
                    if let output {
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("compact-\(state)-\(mode)-\(dark).png"))
                    }
                }
            }
        }
    }

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
                    #expect(size.height > 100 && size.height < (state == "long-error" ? 1000 : 550), "\(state) \(size.height)")
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
