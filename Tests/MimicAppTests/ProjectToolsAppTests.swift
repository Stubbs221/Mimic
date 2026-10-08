// Created by Василий Маслов on 07.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct ProjectToolsAppTests {
    @Test func catalogNavigationFavoritesAndPrivateBridgeRemainIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolsApp-" + UUID().uuidString)
        let name = "ToolsApp-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let model = TaskCoordinator(directory: root, defaults: defaults)
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        let a = ProjectContext(path: root.appendingPathComponent("a").path), b = ProjectContext(path: root.appendingPathComponent("b").path)
        model.projects = [a, b]; model.selectedProjectPath = a.path
        model.generatorName = "Header"; model.openProjectTool(.format, source: .keyboard)
        #expect(model.panelLayout.expanded == .utils && model.selectedProjectTool == .format)
        #expect(model.expandedSection == .tool(.generation) && model.generatorName == "Header")
        model.selectedProjectTool = nil; #expect(model.generatorName == "Header")
        let integration = MimicIntegration(model: model, defaults: defaults)
        try integration.workspaceStore.save(PanelWorkspace(checkout: a.path, expanded: .utils, toolSelection: .format), for: "a")
        try integration.workspaceStore.save(PanelWorkspace(checkout: b.path, expanded: .utils, toolSelection: .generation), for: "b")
        let result = try await integration.handle(.init(method: "panel_save_tools_preferences", parameters: ["favorites": .array([.string("format"), .string("proto")]), "expectedRevision": .number(0)], threadID: "a"))
        #expect(result["revision"].integer == 1)
        #expect(model.toolsPreferences.value.favorites == [.format, .proto])
        #expect(integration.workspaceStore.load("a").toolSelection == .format)
        #expect(integration.workspaceStore.load("b").toolSelection == .generation && model.project == a)
        do { _ = try await integration.handle(.init(method: "panel_save_tools_preferences", parameters: ["favorites": .array([.string("generation")]), "expectedRevision": .number(0)], threadID: "b")); Issue.record("Stale preferences accepted") } catch { }
        let state = try await integration.handle(.init(method: "get_state", threadID: "b"))
        #expect(state["toolsPreferences"]["revision"].integer == 1)
        #expect(state["context"]["checkoutId"].string == b.path)
        model.stopAndExit()
    }
    @Test func formLaunchesKeepSelectionRejectRepeatAndShareQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolsQueue-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "ToolsQueue-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"]] {
            try #require(EnvironmentInspector.capture("/usr/bin/git", args, directory: root.path).0 == 0)
        }
        var manifest = try #require(JSONSerialization.jsonObject(with: Profile11Fixture.data()) as? [String: Any])
        var actions = try #require(manifest["actions"] as? [[String: Any]])
        let bindings = try #require((manifest["interface"] as? [String: Any])?["bindings"] as? [[String: Any]])
        for role in ["format", "protocols"] {
            let actionID = try #require(bindings.first { $0["role"] as? String == role }?["actionID"] as? String)
            let index = try #require(actions.firstIndex { $0["id"] as? String == actionID })
            actions[index]["requiredTools"] = []; actions[index]["requiredFiles"] = []
            actions[index]["steps"] = [["executable": role == "format" ? "/bin/sleep" : "/usr/bin/true", "arguments": role == "format" ? ["2"] : [], "directory": "${checkout}"]]
        }
        manifest["actions"] = actions
        let storage = root.appendingPathComponent("Storage")
        _ = try Profile11Fixture.install(directory: storage, data: JSONSerialization.data(withJSONObject: manifest))
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TaskHost")
        let model = TaskCoordinator(directory: storage, helperURL: helper, defaults: defaults)
        defer { model.stopAndExit() }
        let project = try EnvironmentInspector.project(path: root.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        model.checkReadiness(); model.openProjectTool(.format, source: .keyboard)
        model.launchTool(.format); model.launchTool(.format)
        try await wait { model.records.count == 1 }
        #expect(!model.canLaunchTool(.format))
        model.launchTool(.proto)
        try await wait { model.records.count == 2 }
        let integration = MimicIntegration(model: model, defaults: defaults)
        try integration.workspaceStore.save(PanelWorkspace(checkout: project.path), for: "chat")
        let execution = try model.profileExecution(.format)
        let parameters: [String: BridgeValue] = ["actionID": .string(execution.actionID), "parameters": .object([:]), "context": MimicIntegration.context(project, profile: model.activeProfile), "requestID": .string(UUID().uuidString)]
        do { _ = try await integration.handle(.init(method: "panel_run_tool", parameters: parameters, threadID: "chat")); Issue.record("Repeated UI launch accepted") } catch { }
        #expect(model.records.count == 2 && model.panelLayout.expanded == .utils && model.selectedProjectTool == .format)
        #expect(model.selectedTaskID == nil)
        try await wait { model.records.allSatisfy { $0.status == .succeeded } }
        #expect(model.canLaunchTool(.format))
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        let ready = condition(); try #require(ready)
    }
    // MARK: - Compact favorite geometry

    @Test(arguments: [1, 2, 3])
    func favoritesFillAvailableHeightAndExcludePaddingFromDragging(count: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolsCards-" + UUID().uuidString)
        let name = "ToolsCards-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        let project = ProjectContext(path: root.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        let favorites = Array([ProjectTool.generation, .derivedDataCleanup, .localization].prefix(count))
        _ = try model.toolsPreferences.save(favorites, expectedRevision: 0)
        let output = URL(fileURLWithPath: "/private/tmp/Mimic-tools-cards-native")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let statuses: [TaskStatus] = [.queued, .running, .succeeded, .failed, .cancelled, .interrupted]
        for full in [false, true] {
            model.panelLayout.begin()
            model.panelLayout.edit { layout in
                for block in layout.blocks where block != .utils { layout.remove(block) }
                try layout.resize(.utils, to: full ? .full : .mini)
            }
            model.panelLayout.finish()
            for dark in [false, true] {
                for scale in [1.0, 2.0] {
                    for appearance in [PanelAppearance.legacy, .tileGrid] {
                        model.records = favorites.enumerated().map { index, tool in
                            var record = TaskRecord(action: tool.action, project: project)
                            record.status = statuses[(index + (dark ? 3 : 0)) % statuses.count]
                            record.startedAt = Date().addingTimeInterval(-125)
                            if record.status != .running && record.status != .queued { record.finishedAt = Date() }
                            return record
                        }
                        let width: CGFloat = full ? 488 : 158
                        let height: CGFloat = appearance == .tileGrid ? 160 * scale : 160
                        let panelWidth = full ? width : width * 2 + 12
                        let cardWidth = appearance == .tileGrid && scale > 1.2 ? panelWidth : width
                        let view = PanelGrid(model: model, layout: model.panelLayout)
                            .frame(width: panelWidth, height: height + 100, alignment: .topLeading)
                            .environment(\.mimicPanelAppearance, appearance).environment(\.mimicTextScale, scale)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let host = NSHostingView(rootView: view)
                        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: panelWidth, height: height + 100), styleMask: .borderless, backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.contentView = host; window.orderFront(nil)
                        try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded()
                        var frames: [CGRect] = []
                        var headers: [CGRect] = []
                        func collect(_ node: NSView) {
                            if node is PanelControlRegion.MarkerView, !node.visibleRect.isEmpty { frames.append(host.convert(node.bounds, from: node)) }
                            if node is PanelDragHeaderRegion.MarkerView, !node.visibleRect.isEmpty { headers.append(host.convert(node.bounds, from: node)) }
                            node.subviews.forEach(collect)
                        }
                        collect(host); frames.sort { $0.minY < $1.minY }
                        #expect(frames.count == count)
                        let first = try #require(frames.first), last = try #require(frames.last)
                        let header = try #require(headers.first)
                        let cardBounds = CGRect(x: header.minX - 12, y: header.minY - 10, width: cardWidth, height: height)
                        #expect(abs(first.width - (cardWidth - 24)) < 0.5)
                        #expect(abs(first.minY - header.maxY - 6) < 0.5)
                        #expect(abs(last.maxY - (cardBounds.maxY - 12)) <= 1)
                        for (index, frame) in frames.enumerated() {
                            // AppKit rounds equal fractional row heights to the nearest screen pixel.
                            #expect(abs(frame.height - first.height) <= 1)
                            #expect(host.bounds.contains(frame))
                            if index > 0 { #expect(abs(frame.minY - frames[index - 1].maxY - 8) < 0.5) }
                            for x in [frame.minX + 4, frame.maxX - 4] {
                                let point = host.convert(CGPoint(x: x, y: frame.midY), to: nil)
                                #expect(PanelControlRegion.MarkerView.contains(point, in: host))
                            }
                        }
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: cardBounds))
                        host.cacheDisplay(in: cardBounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(count)-\(full ? "full" : "mini")-\(dark ? "dark" : "light")-\(scale)-\(appearance.rawValue).png"))
                        if full && !dark && scale == 1 && appearance == .tileGrid {
                            let point = host.convert(CGPoint(x: first.minX + 4, y: first.midY), to: nil)
                            let recordIDs = model.records.map(\.id)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                                window.sendEvent(event)
                            }
                            try await Task.sleep(for: .milliseconds(20))
                            #expect(model.selectedProjectTool == favorites[0])
                            #expect(model.records.map(\.id) == recordIDs)
                            #expect(model.panelLayout.dragging == nil)
                            model.selectedProjectTool = nil; model.panelLayout.expanded = nil
                        }
                        window.close()
                    }
                }
            }
        }
        model.records = []
        #expect(model.selectedProjectTool == nil)
    }

    @Test func cardsAndFormsRenderWithoutChangingExecution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolsUI-" + UUID().uuidString)
        let name = "ToolsUI-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let model = TaskCoordinator(directory: root, defaults: defaults)
        model.activeProfile = try Profile11Fixture.snapshot(directory: root)
        model.projects = [ProjectContext(path: "/private/tmp/MobilePlatformInfrastructure", branch: "feature/infrastructure/dependency-registry-bootstrap-diagnostics")]
        model.selectedProjectPath = model.projects[0].path
        model.readiness = Dictionary(uniqueKeysWithValues: MimicAction.allCases.map { ($0, []) })
        let output = URL(fileURLWithPath: "/private/tmp/Mimic-tools-native"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            for mode in ["mini", "full", "catalog", "generation", "fullCleanup"] {
                if mode == "fullCleanup" { model.selectedProjectTool = .fullCleanup }
                else if mode == "generation" { model.selectedProjectTool = .generation; model.generatorName = "InfrastructureDependencyRegistryConfiguration" }
                else { model.selectedProjectTool = nil }
                let view: AnyView
                if mode == "mini" || mode == "full" { view = AnyView(ToolsCompactView(model: model, preferences: model.toolsPreferences, full: mode == "full").padding(12).frame(width: mode == "mini" ? 238 : 488, height: 120)) }
                else { view = AnyView(ToolsDetailView(model: model).padding(12).frame(width: 488)) }
                let hosting = NSHostingView(rootView: view.frame(maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
                hosting.frame = NSRect(x: 0, y: 0, width: mode == "mini" ? 238 : 488, height: mode == "mini" || mode == "full" ? 120 : 800)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(mode + (dark ? "-dark" : "-light") + ".png"))
            }
        }
        #expect(model.records.isEmpty)
        model.stopAndExit()
    }
}
