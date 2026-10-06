//
//  TaskHistoryWindowTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 06.10.2026.
import AppKit
import ApplicationServices
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

/// Histories and preferences are disposable; no fixture starts a job or touches a user checkout.
@MainActor private struct HistoryPanelFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-history-window-" + UUID().uuidString)
    let suite = "Mimic-history-window-" + UUID().uuidString
    let defaults: UserDefaults
    let model: TaskCoordinator
    let project: ProjectContext
    let orderedIDs: [UUID]

    init(count: Int = 8, blocked: Bool = false) throws {
        self.defaults = try #require(UserDefaults(suiteName: self.suite))
        self.project = ProjectContext(path: self.root.appendingPathComponent("checkout").path, branch: "fixture", commit: "fixture-sha")
        var local: [TaskRecord] = [], builds: [BuildActivity] = [], ids: [UUID] = []
        let newest = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for index in 0..<count {
            var context = self.project; context.branch = "history-entry-\(index)"
            let date = newest.addingTimeInterval(-Double(index))
            if index.isMultiple(of: 2) {
                var record = BuildActivity(project: context, parameters: .init(scheme: "Fixture"), source: "fixture", createdAt: date)
                record.status = blocked ? .unknown : index == 6 ? .failed : .succeeded
                builds.append(record); ids.append(record.id)
            } else {
                var record = TaskRecord(action: .format, project: context)
                record.status = index == 5 ? .failed : .succeeded
                // The production initializer timestamps admission; fixture dates define interleaving deterministically.
                var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
                json["createdAt"] = date.timeIntervalSinceReferenceDate
                record = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: json))
                local.append(record); ids.append(record.id)
            }
        }
        self.orderedIDs = ids
        try BuildHistoryStore(directory: self.root).save(Array(builds.reversed()))
        self.model = TaskCoordinator(directory: self.root, defaults: self.defaults)
        self.model.projects = [self.project]; self.model.selectedProjectPath = self.project.path
        self.model.records = Array(local.reversed())
        self.model.motionSettings.reduceMotionOverride = true
    }

    func cleanUp() {
        self.model.builds.stop(); self.model.profileRemote.stop(); self.model.remoteTests.stop(); self.model.ci.setVisible(false)
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.root)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct TaskHistoryWindowTests {
    // MARK: - Shared pagination and navigation

    @Test(arguments: [0, 1, 2, 3, 5, 8])
    func combinedHistoryStartsWithTwoAndAddsThree(count: Int) throws {
        let f = try HistoryPanelFixture(count: count); defer { f.cleanUp() }
        let m = f.model
        m.toggleHistory(source: .keyboard)
        #expect(m.taskHistory.map(\.id) == f.orderedIDs)
        #expect(m.visibleTaskHistory.map(\.id) == Array(f.orderedIDs.prefix(2)))
        var expectedLimit = 2
        while m.hasMoreTaskHistory {
            m.showMoreTaskHistory(); expectedLimit += 3
            #expect(m.taskHistoryLimit == expectedLimit)
            #expect(m.visibleTaskHistory.map(\.id) == Array(f.orderedIDs.prefix(expectedLimit)))
        }
        m.showMoreTaskHistory()
        #expect(m.taskHistoryLimit == expectedLimit && m.visibleTaskHistory.count == count)
    }

    @Test func reopeningResetsButSettingsAndStatusUpdatesRetainWindow() throws {
        let f = try HistoryPanelFixture(); defer { f.cleanUp() }
        let m = f.model
        m.toggleHistory(); m.showMoreTaskHistory(); m.showMoreTaskHistory()
        #expect(m.visibleTaskHistory.count == 8)
        m.openSettings(group: .environment); m.returnHome()
        #expect(m.taskHistoryLimit == 8)
        m.records[0].status = .cancelled
        #expect(m.taskHistoryLimit == 8)
        m.toggleTask(try #require(f.orderedIDs.last))
        m.toggleHistory(); m.toggleHistory()
        #expect(m.taskHistoryLimit == 2)
        #expect(m.selectedTaskID != f.orderedIDs.last)
        m.showMoreTaskHistory(); m.revealSection(.builds); m.revealSection(.tasks)
        #expect(m.taskHistoryLimit == 2)
    }

    @Test func searchAndFiltersApplyBeforeLimitAndResetIt() throws {
        let f = try HistoryPanelFixture(); defer { f.cleanUp() }
        let m = f.model
        m.toggleHistory(); m.showMoreTaskHistory()
        m.taskSearch = "history-entry-7"
        #expect(m.taskHistoryLimit == 2 && m.visibleTaskHistory.map(\.id) == [f.orderedIDs[7]])
        m.taskSearch = "history-entry-6"
        #expect(m.visibleTaskHistory.map(\.id) == [f.orderedIDs[6]])
        m.taskSearch = ""; m.showMoreTaskHistory(); m.taskFilter = .failed
        #expect(m.taskHistoryLimit == 2 && m.visibleTaskHistory.map(\.id) == Array(f.orderedIDs[5...6]))
        m.taskFilter = .active
        #expect(m.visibleTaskHistory.isEmpty && !m.hasMoreTaskHistory)
    }

    @Test func explicitOldTaskAndBuildRevealWholePagesBeforeScrolling() throws {
        let f = try HistoryPanelFixture(count: 11); defer { f.cleanUp() }
        let m = f.model
        m.taskSearch = "hidden"; m.taskFilter = .active
        m.showHistory(id: f.orderedIDs[7], focusTerminal: true, source: .keyboard)
        #expect(m.taskSearch.isEmpty && m.taskFilter == .all && m.taskHistoryLimit == 8)
        #expect(m.selectedTaskID == f.orderedIDs[7] && m.terminalFocusTaskID == f.orderedIDs[7])
        #expect(m.panelScrollTarget == "terminal." + f.orderedIDs[7].uuidString)
        #expect(m.scrollSource == .keyboard && m.navigationSource == .keyboard)
        m.toggleHistory(); m.taskSearch = "hidden"; m.taskFilter = .active
        m.showBuildResult(f.orderedIDs[8])
        #expect(m.taskSearch.isEmpty && m.taskFilter == .all && m.taskHistoryLimit == 11)
        #expect(m.builds.selectedID == f.orderedIDs[8] && m.selectedTaskID == nil)
        #expect(m.panelScrollTarget == "build." + f.orderedIDs[8].uuidString)
        #expect(m.visibleTaskHistory.contains { $0.id == f.orderedIDs[8] })
        m.toggleHistory(); m.toggleHistory()
        #expect(m.taskHistoryLimit == 2 && m.builds.selectedID == nil)
    }

    // MARK: - Environment settings

    @Test func selectingSavedProjectResetsWindowAndPersistsChoice() throws {
        let f = try HistoryPanelFixture(); defer { f.cleanUp() }
        let m = f.model
        let second = ProjectContext(path: f.root.appendingPathComponent("other/checkout").path, branch: "second", commit: "other-sha")
        m.projects.append(second); m.toggleHistory(); m.showMoreTaskHistory()
        m.openSettings(group: .environment); m.selectProject(second)
        #expect(m.selectedProjectPath == second.path && m.taskHistoryLimit == 2)
        #expect(f.defaults.string(forKey: "selectedProject") == second.path)
        #expect(m.panelPage == .settings && m.settingsGroup == .environment)
    }

    @Test func projectSelectionKeepsExistingBuildGate() throws {
        let f = try HistoryPanelFixture(count: 1, blocked: true); defer { f.cleanUp() }
        let m = f.model
        let second = ProjectContext(path: f.root.appendingPathComponent("other/checkout").path, branch: "second", commit: "other-sha")
        m.projects.append(second)
        #expect(!m.canSelectProject)
        m.selectProject(second)
        #expect(m.selectedProjectPath == f.project.path)
        m.projects = []; m.selectedProjectPath = ""
        #expect(m.project == nil && m.visibleTaskHistory.count == 1)
    }

    @Test(.enabled(if: AXIsProcessTrusted(), "Requires Accessibility permission for the native test runner."))
    func accessibleHistoryButtonRevealsPagesAndHeaderHasOnlyBranchAndSettings() async throws {
        let f = try HistoryPanelFixture(); defer { f.cleanUp() }
        let m = f.model
        m.revealSection(.tasks, source: .keyboard)
        #expect(m.scrollSource == .keyboard && m.navigationSource == .keyboard)
        _ = NSApplication.shared
        let activation = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(activation) }
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let host = NSHostingView(rootView: VStack {
            ProjectBar(model: m)
            ScrollView { TaskHistoryContent(model: m) }
        }.padding(16).frame(width: 520, height: 600))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        let app = AXUIElementCreateApplication(getpid())
        #expect(self.findAX(app, id: "branch.toggle") != nil)
        #expect(self.findAX(app, id: "settings.toggle") != nil)
        #expect(self.findAX(app, id: "settings.project.select") == nil)
        for expectedCount in [5, 8] {
            let more = self.findAX(app, id: "tasks.more")
            let button = try #require(more)
            let label = self.axValue(button, kAXTitleAttribute) as? String ?? self.axValue(button, kAXDescriptionAttribute) as? String
            #expect(label == text("tasks.more"))
            #expect(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80))
            #expect(m.visibleTaskHistory.count == expectedCount)
        }
        #expect(self.findAX(app, id: "tasks.more") == nil)
    }

    /// Render the changed surfaces only, including empty state and duplicate checkout names.
    @Test func changedNativeSurfacesFitBothThemesWithWorstCaseData() async throws {
        let f = try HistoryPanelFixture(); defer { f.cleanUp() }
        let m = f.model
        let output = URL(fileURLWithPath: "/private/tmp/MimicPanelHistory-20261006")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var project = ProjectContext(path: f.root.appendingPathComponent(String(repeating: "MobilePlatformInfrastructure", count: 5) + "/ios3").path)
        project.branch = "feature/" + String(repeating: "navigation-subscription-profile-", count: 6)
        project.commit = String(repeating: "abcdef0123", count: 4)
        project.developerDirectory = "/Applications/Developer Tools/Xcode-27.app/Contents/Developer"
        let second = ProjectContext(path: f.root.appendingPathComponent("another/ios3").path, branch: project.branch, commit: project.commit)
        m.projects = [project, second]; m.selectedProjectPath = project.path
        m.revealSection(.tasks, source: .keyboard)
        for dark in [false, true] {
            for width in [408.0, 488.0] {
                try await self.render(ProjectBar(model: m).padding(16), width: width, dark: dark, name: "header", output: output)
                try await self.render(ProjectSelectionSettingsView(model: m).padding(16), width: width, dark: dark, name: "project", output: output)
                try await self.render(TaskHistoryContent(model: m).padding(16), width: width, dark: dark, name: "history-two", output: output)
            }
        }
        m.showMoreTaskHistory()
        for dark in [false, true] {
            try await self.render(TaskHistoryContent(model: m).padding(16), width: 488, dark: dark, name: "history-five", output: output)
        }
        m.projects = []; m.selectedProjectPath = ""; m.records = []; m.taskSearch = "no-match"
        for dark in [false, true] {
            try await self.render(ProjectSelectionSettingsView(model: m).padding(16), width: 408, dark: dark, name: "project-empty", output: output)
            try await self.render(TaskHistoryContent(model: m).padding(16), width: 488, dark: dark, name: "history-empty", output: output)
        }
        #expect(m.taskHistoryLimit == 2 && m.visibleTaskHistory.isEmpty)
    }

    private func render<V: View>(_ view: V, width: Double, dark: Bool, name: String, output: URL) async throws {
        _ = NSApplication.shared
        let content = view.frame(width: width).font(MimicMetrics.body).controlSize(.small)
            .tint(.indigo).buttonStyle(MimicButtonStyle())
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.mimicMotionSettings, MimicMotionSettings())
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        #expect(size.width <= width + 1 && size.height > 0)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
    }

    private func axValue(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func findAX(_ node: AXUIElement, id: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 25 else { return nil }
        if self.axValue(node, "AXIdentifier") as? String == id { return node }
        let children = self.axValue(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let windows = depth == 0 ? self.axValue(node, kAXWindowsAttribute) as? [AXUIElement] ?? [] : []
        for child in children + windows {
            if let found = self.findAX(child, id: id, depth: depth + 1) { return found }
        }
        return nil
    }
}
