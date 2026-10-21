//
//  ProfilePanelLogicTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 21.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

/// Runs only disposable printf/sleep/false adapters; no installed app or simulator is touched.
@MainActor private final class PanelLogicFixture {
    let suite = "ProfilePanelLogic-" + UUID().uuidString
    let root: URL
    let defaults: UserDefaults
    let model: TaskCoordinator
    let snapshot: ProfileSnapshot
    let panel: ProfilePanel
    let project: ProjectContext
    let form: ProfilePanelForm

    init(fails: Bool = false) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Fixture"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", arguments, directory: root.path).0 == 0)
        }
        try Data().write(to: root.appendingPathComponent("marker"))
        var manifest = try #require(JSONSerialization.jsonObject(with: Profile11Fixture.data()) as? [String: Any])
        manifest["panels"] = [["id": "settings", "title": "Settings", "actionID": "settings", "requiredFiles": ["marker"],
                               "applications": [["id": "demo", "title": "Demo"]], "fields": [["id": "first", "title": "First"]]]]
        var actions = try #require(manifest["actions"] as? [[String: Any]])
        let parameters = ProfilePanel.parameterIDs.sorted().map { ["id": $0, "title": $0, "kind": "text", "defaultValue": "", "required": false] as [String: Any] }
        var steps: [[String: Any]] = [["executable": "/bin/cat", "arguments": ["${checkout}/result.txt"], "directory": "${checkout}"],
                                     ["executable": "/bin/sleep", "arguments": ["0.3"], "directory": "${checkout}"]]
        if fails { steps.append(["executable": "/usr/bin/false", "arguments": [], "directory": "${checkout}"]) }
        actions.append(["id": "settings", "title": "Settings", "presentation": "regular", "logPolicy": "metadataOnly", "mcpAllowed": true,
                        "requiresXcodeQuit": false, "requiredFiles": [], "requiredTools": [], "parameters": parameters, "steps": steps])
        manifest["actions"] = actions
        let storage = root.appendingPathComponent("Storage")
        snapshot = try Profile11Fixture.install(directory: storage, data: JSONSerialization.data(withJSONObject: manifest))
        panel = try #require(snapshot.profile.panels?.first)
        model = TaskCoordinator(directory: storage, helperURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TaskHost"), defaults: defaults)
        project = try EnvironmentInspector.project(path: root.path)
        model.projects = [project]; model.selectedProjectPath = project.path; model.activeProfile = snapshot
        form = ProfilePanelForm(model: model, panel: panel, project: project, snapshot: snapshot, defaults: defaults)
        form.device = UUID().uuidString
        try output()
    }

    func output(status: String = "ready", revision: String = "r0") throws {
        let data = try JSONSerialization.data(withJSONObject: ["status": status, "values": ["first": "123"], "revision": revision, "devices": [], "developerMode": true])
        try (Data("MIMIC_PANEL_RESULT ".utf8) + data + Data("\n".utf8)).write(to: root.appendingPathComponent("result.txt"))
    }

    func finish() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.records.contains(where: { [.queued, .running].contains($0.status) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.records.contains(where: { [.queued, .running].contains($0.status) }))
    }

    func close() {
        model.stopAndExit()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Suite(.serialized) struct ProfilePanelLogicTests {
    @Test func cancelledViewWaiterKeepsObservingTheOriginalTask() async throws {
        let fixture = try PanelLogicFixture(); defer { fixture.close() }
        let waiter = Task { await fixture.form.run("read") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while fixture.model.records.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        waiter.cancel()
        await waiter.value
        try await fixture.finish()
        #expect(fixture.form.result?.values["first"] == "123")
        #expect(!fixture.form.busy)
        #expect(fixture.model.records.count == 1)
    }

    @Test func failedProcessCannotConfirmSettingsFromEarlierOutput() async throws {
        let fixture = try PanelLogicFixture(fails: true); defer { fixture.close() }
        try fixture.output(status: "saved")
        await fixture.form.run("read")
        #expect(fixture.model.records.last?.status == .failed)
        #expect(fixture.model.records.last?.panelResult == nil)
        #expect(fixture.form.result == nil)
        #expect(fixture.form.message == text("customPanel.failed"))
    }

    @Test func failedReloadPreservesDraftUntilAConfirmedRead() async throws {
        let fixture = try PanelLogicFixture(); defer { fixture.close() }
        await fixture.form.run("read")
        fixture.form.values["first"] = "999"; fixture.form.saveDraft()
        try fixture.output(status: "unavailable")
        await fixture.form.reload()
        #expect(fixture.form.values["first"] == "999")
        try fixture.output(revision: "r1")
        await fixture.form.run("read")
        #expect(fixture.form.conflict)
        #expect(fixture.form.values["first"] == "999")
        await fixture.form.reload()
        #expect(!fixture.form.conflict)
        #expect(fixture.form.values["first"] == "123")
    }

    @Test func failedOrUnavailableSettingsInvalidateOldServiceRouting() throws {
        let fixture = try PanelLogicFixture(); defer { fixture.close() }
        let tool = try JSONDecoder().decode(ServiceTool.self, from: Data(#"{"id":"service","title":"Service","requiredFiles":["marker"],"baseURLTemplate":"https://api.{namespace}.example.test","source":{"panelID":"settings","namespaceField":"target","appVersionField":"first"},"mcpAllowed":true,"actions":[]}"#.utf8))
        var saved = TaskRecord(action: .format, project: fixture.project)
        saved.profileExecution = ProfileExecution(snapshot: fixture.snapshot, actionID: "settings", parameters: ["device": fixture.form.device, "application": "demo"])
        saved.status = .succeeded
        saved.panelResult = try JSONDecoder().decode(ProfilePanelResult.self, from: Data(#"{"status":"saved","values":{"target":"testing.ing","first":"123"},"revision":"r0","devices":[],"developerMode":true}"#.utf8))
        fixture.model.records = [saved]
        let selection = [fixture.form.device, "demo"]
        #expect(fixture.model.serviceContext(tool: tool, project: fixture.project, snapshot: fixture.snapshot, selection: selection).namespace == "testing")
        var unavailable = TaskRecord(action: .format, project: fixture.project)
        unavailable.profileExecution = saved.profileExecution; unavailable.status = .failed
        fixture.model.records.append(unavailable)
        #expect(fixture.model.serviceContext(tool: tool, project: fixture.project, snapshot: fixture.snapshot, selection: selection).namespace.isEmpty)
        unavailable.status = .succeeded
        unavailable.panelResult = try JSONDecoder().decode(ProfilePanelResult.self, from: Data(#"{"status":"notInstalled","values":{},"revision":"","devices":[],"developerMode":false}"#.utf8))
        fixture.model.records[1] = unavailable
        #expect(fixture.model.serviceContext(tool: tool, project: fixture.project, snapshot: fixture.snapshot, selection: selection).namespace.isEmpty)
    }
}
