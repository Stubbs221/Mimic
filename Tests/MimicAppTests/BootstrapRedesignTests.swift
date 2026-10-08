// Created by Василий Маслов on 06.10.2026.
import AppKit
import CryptoKit
import Combine
import Foundation
import Testing
import SwiftUI
import MimicCore
@testable import Mimic

@Suite(.serialized) @MainActor struct BootstrapRedesignTests {
    @Test(arguments: BootstrapPlatform.allCases)
    func platformLaunchCapturesDefaultsOnceWithoutNavigation(_ platform: BootstrapPlatform) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapRedesign-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try #require(UserDefaults(suiteName: suite))
        _ = try Profile11Fixture.install(directory: root)
        let project = ProjectContext(path: root.path, branch: "fixture", commit: "fixture-sha")
        let model = TaskCoordinator(directory: root, defaults: defaults, inspectBootstrapAdmission: { current, _ in .ready(current) })
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        model.projects = [project]; model.selectedProjectPath = project.path
        var barrier = TaskRecord(action: .format, project: project); barrier.status = .running; model.records = [barrier]
        model.selectedTaskID = barrier.id
        model.panelLayout.expanded = .builds; model.expandedSection = .builds
        model.bootstrapOptions = BootstrapPreset.simulator.options
        model.requestQuickBootstrap(platform: platform)
        let id = try #require(model.quickBootstrapActivity?.request.id)
        model.requestQuickBootstrap(platform: platform == .ios ? .tvos : .ios)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.requestingBootstrap && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.requestingBootstrap)
        let record = try #require(model.records.first { $0.id == id })
        #expect(record.options == .standard(platform: platform))
        #expect(model.records.filter { $0.action == .bootstrap }.count == 1)
        #expect(model.panelLayout.expanded == .builds); #expect(model.expandedSection == .builds)
        #expect(model.selectedTaskID == barrier.id)
        #expect(!model.canRequestQuickBootstrap)
    }

    @Test func terminalSubscribersRetainFinalOutputAndOriginalTaskIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapTerminal-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var record = TaskRecord(action: .bootstrap, project: ProjectContext(path: root.path)); record.status = .running
        model.records = [record]
        let terminal = model.bootstrapTerminal(for: record), originalView = terminal.view()
        #expect(!terminal.hasOutput)
        var outputTransitions: [Bool] = []
        let observation = terminal.$hasOutput.sink { outputTransitions.append($0) }
        defer { observation.cancel() }
        #expect(!String(decoding: originalView.getTerminal().getBufferAsData(), as: UTF8.self).contains("mimic bootstrap"))
        let channel = try PanelTerminalChannel(taskID: record.id, threadID: "fixture-chat", clientKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        let subscription = PanelTerminalSubscription(channel, model: model)
        defer { subscription.stop() }
        let historyOwner = UUID(); var historyOutput = Data()
        model.attachTerminal(owner: historyOwner) { id, bytes in if id == record.id { historyOutput.append(bytes) } }
        model.terminalOutput?(record.id, Data("first line\r\n".utf8))
        model.detachTerminal(owner: historyOwner)
        model.terminalOutput?(UUID(), Data("another task\r\n".utf8))
        model.terminalOutput?(record.id, Data("final line\r\n".utf8))
        model.terminalOutput?(record.id, Data())
        #expect(outputTransitions == [false, true], "First output publishes immediately; empty chunks cannot restore the placeholder")
        model.records[0].status = .failed
        #expect(model.replay(id: record.id).isEmpty)
        #expect(String(decoding: terminal.snapshot, as: UTF8.self) == "first line\r\nfinal line\r\n")
        #expect(subscription.snapshot == terminal.snapshot)
        #expect(String(decoding: historyOutput, as: UTF8.self) == "first line\r\n")
        let snapshot = terminal.snapshot
        terminal.configure(fontSize: 10, dark: false, increasedContrast: false)
        #expect(originalView.font.pointSize == 10)
        #expect(originalView.nativeBackgroundColor == BootstrapTerminalTheme.color(0xF0F3F7))
        terminal.configure(fontSize: 12, dark: true, increasedContrast: false)
        #expect(originalView.font.pointSize == 12)
        #expect(originalView.nativeForegroundColor == BootstrapTerminalTheme.color(0xDCE3ED))
        #expect(terminal.snapshot == snapshot)
        #expect(model.bootstrapTerminal(for: model.records[0]).view() === originalView)
        model.terminalOutput?(record.id, Data(repeating: 65, count: 150 * 1024))
        #expect(terminal.snapshot.count == 128 * 1024); #expect(subscription.snapshot.count == 128 * 1024)
        model.records[0].hasPrivateInput = true
        model.terminalOutput?(record.id, Data("echo from private fixture input".utf8))
        #expect(terminal.snapshot.isEmpty); #expect(terminal.hasOutput)
        #expect(model.bootstrapTerminal(for: model.records[0]).view() === originalView)
        var hidden = TaskRecord(action: .bootstrap, project: record.project); hidden.status = .running; hidden.hasPrivateInput = true
        model.records.append(hidden)
        let unopened = model.bootstrapTerminal(for: hidden)
        model.terminalOutput?(hidden.id, Data("private output without a mounted screen".utf8))
        #expect(unopened.snapshot.isEmpty); #expect(!unopened.hasOutput)
        let restarted = TaskCoordinator(directory: root, defaults: defaults)
        #expect(restarted.terminalSnapshot(id: record.id).isEmpty)
        restarted.stopAndExit()
    }

    @Test func bridgeStagesFollowObservedProgressAndSuccessfulExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapStages-" + UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        var record = TaskRecord(action: .bootstrap, project: ProjectContext(path: root.path), options: .standard())
        record.status = .running; model.records = [record]
        let integration = MimicIntegration(model: model, defaults: defaults)
        let running = integration.task(record)["bootstrap"]
        #expect(running["stages"] == .array([.string("dependencies"), .string("uiTests"), .string("setup")]))
        #expect(running["completedStages"] == .array([]))
        #expect(running["currentStage"] == .null)
        record.status = .failed
        #expect(integration.task(record)["bootstrap"]["completedStages"] == .array([]))
        record.status = .succeeded
        #expect(integration.task(record)["bootstrap"]["completedStages"] == running["stages"])
    }

    @Test func inlineDiagnosticDoesNotNavigateOrSubmitAndKeepsEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapDiagnostic-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var record = TaskRecord(action: .bootstrap, project: ProjectContext(path: root.path)); record.status = .failed
        record.error = "Fixture failure"; model.records = [record]
        model.panelLayout.expanded = nil; model.expandedSection = .builds
        model.prepareAnalysis(record, inline: true)
        model.analysis.edit(id: record.id, fragment: "Edited fixture fragment", comment: "User note")
        model.prepareAnalysis(record, inline: true)
        #expect(model.panelLayout.expanded == nil); #expect(model.expandedSection == .builds)
        #expect(!model.analysis.isActive)
        let session = try #require(model.analysis.sessions[record.id])
        #expect(session.snapshot.taskID == record.id); #expect(session.prompt.contains("Edited fixture fragment")); #expect(session.prompt.contains("User note"))
        let metadata = MimicIntegration(model: model, defaults: defaults).task(record)
        #expect(metadata["bootstrap"]["platform"].string == "ios")
        #expect(!String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self).contains("Edited fixture fragment"))
    }
    @Test func fastFixtureProcessKeepsFinalBytesAfterReplayCleanup() async throws {
        let (root, storage) = try self.makePTYFixture(executable: "/usr/bin/printf", arguments: ["FIRST FIXTURE LINE\nFINAL FIXTURE LINE\n"])
        let suite = root.lastPathComponent, defaults = try #require(UserDefaults(suiteName: suite))
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TaskHost")
        let model = TaskCoordinator(directory: storage, helperURL: helper, xcodeApplications: BootstrapFixtureXcode(), defaults: defaults, inspectBootstrapAdmission: { current, _ in .ready(current) })
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = try EnvironmentInspector.project(path: root.path); model.projects = [project]; model.selectedProjectPath = project.path
        let id = UUID(), channel = try PanelTerminalChannel(taskID: id, threadID: "fixture", clientKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        let subscription = PanelTerminalSubscription(channel, model: model); defer { subscription.stop() }
        model.request(.bootstrap, options: .standard(), recordID: id, navigate: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (model.requestingBootstrap || model.records.first(where: { $0.id == id }).map { $0.status == .queued || $0.status == .running } ?? true) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let result = try #require(model.records.first { $0.id == id })
        #expect(result.status == .succeeded); #expect(result.logPath == nil)
        #expect(model.replay(id: id).isEmpty)
        let output = String(decoding: model.terminalSnapshot(id: id), as: UTF8.self)
        #expect(output.contains("FIRST FIXTURE LINE")); #expect(output.contains("FINAL FIXTURE LINE"))
        #expect(String(decoding: subscription.snapshot, as: UTF8.self).contains("FINAL FIXTURE LINE"))
    }

    @Test(arguments: [false, true]) func fixtureInputAndCancellationKeepTheMountedScreen(_ cancel: Bool) async throws {
        let command = "printf 'READY\\n'; IFS= read -r value; printf 'RECEIVED:%s\\n' \"$value\"; " + (cancel ? "sleep 10" : "printf 'FINAL\\n'")
        let (root, storage) = try self.makePTYFixture(executable: "/bin/sh", arguments: [], script: command)
        let suite = root.lastPathComponent, defaults = try #require(UserDefaults(suiteName: suite))
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TaskHost")
        let model = TaskCoordinator(directory: storage, helperURL: helper, xcodeApplications: BootstrapFixtureXcode(), defaults: defaults, inspectBootstrapAdmission: { current, _ in .ready(current) })
        defer { model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = try EnvironmentInspector.project(path: root.path); model.projects = [project]; model.selectedProjectPath = project.path
        let id = UUID(), owner = UUID(); var streamed = Data()
        model.attachTerminal(owner: owner) { task, bytes in if task == id { streamed.append(bytes) } }
        defer { model.detachTerminal(owner: owner) }
        model.request(.bootstrap, options: .standard(), recordID: id, navigate: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !String(decoding: streamed, as: UTF8.self).contains("READY") && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let running = try #require(model.records.first { $0.id == id }); #expect(running.status == .running)
        let presentation = model.bootstrapTerminal(for: running), screen = presentation.view()
        model.input(id: id, data: Data("disposable-fixture\n".utf8))
        while !String(decoding: streamed, as: UTF8.self).contains("RECEIVED:disposable-fixture") && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(String(decoding: streamed, as: UTF8.self).contains("RECEIVED:disposable-fixture"))
        if cancel { model.cancel(id: id) }
        while model.records.first(where: { $0.id == id })?.status == .running && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let completed = try #require(model.records.first { $0.id == id })
        #expect(completed.status == (cancel ? .cancelled : .succeeded)); #expect(completed.hasPrivateInput == true)
        #expect(completed.logPath == nil); #expect(model.replay(id: id).isEmpty); #expect(presentation.snapshot.isEmpty)
        #expect(model.bootstrapTerminal(for: completed).view() === screen); #expect(presentation.hasOutput)
        #expect(String(decoding: screen.getTerminal().getBufferAsData(), as: UTF8.self).contains("RECEIVED:disposable-fixture"))
        if !cancel { #expect(String(decoding: streamed, as: UTF8.self).contains("FINAL")) }
    }

    /// Uses a validated interface and disposable shell commands; no live Bootstrap or Xcode access.
    private func makePTYFixture(executable: String, arguments: [String], script: String? = nil) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapPTY-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for gitArguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Disposable fixture"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", gitArguments, directory: root.path).0 == 0)
        }
        var manifest = try #require(JSONSerialization.jsonObject(with: Profile11Fixture.data()) as? [String: Any])
        var actions = try #require(manifest["actions"] as? [[String: Any]])
        let profile = try JSONDecoder().decode(MimicProfile.self, from: Profile11Fixture.data())
        let binding = try #require(profile.interface?.bindings.first { $0.role == .bootstrap })
        let index = try #require(actions.firstIndex { $0["id"] as? String == binding.actionID })
        actions[index]["requiredFiles"] = []; actions[index]["requiredTools"] = []; actions[index]["toolRequirements"] = []
        var fixtureArguments = arguments
        if let script {
            let path = root.appendingPathComponent("interactive-fixture.sh")
            try ("# Created by Василий Маслов on 06.10.2026.\n" + script + "\n").write(to: path, atomically: true, encoding: .utf8)
            fixtureArguments = [path.path]
        }
        actions[index]["steps"] = [["executable": executable, "arguments": fixtureArguments, "directory": "${checkout}"]]
        manifest["actions"] = actions; manifest["requiredFiles"] = []
        let storage = root.appendingPathComponent("Storage")
        _ = try Profile11Fixture.install(directory: storage, data: JSONSerialization.data(withJSONObject: manifest))
        return (root, storage)
    }

    @Test func nativeBootstrapThreeModesRenderAtAcceptedWidths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapRender-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try #require(UserDefaults(suiteName: suite))
        _ = try Profile11Fixture.install(directory: root)
        let model = TaskCoordinator(directory: root, defaults: defaults)
        defer { model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path); model.projects = [project]; model.selectedProjectPath = project.path
        var record = TaskRecord(action: .bootstrap, project: project); record.status = .failed
        record.startedAt = Date().addingTimeInterval(-41); record.finishedAt = Date(); record.error = "Не удалось загрузить InfrastructureDependencyRegistryConfiguration из registry.example.invalid"
        model.records = [record]; model.motionSettings.reduceMotionOverride = true
        _ = model.bootstrapTerminal(for: record)
        model.terminalOutput?(record.id, Data("Bootstrap fixture output\r\nDependency registry unavailable\r\n".utf8))
        let output = URL(fileURLWithPath: "/private/tmp/Mimic-bootstrap-native-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width in [360.0, 440.0, 480.0, 520.0] {
            for mode in [BootstrapCardMode.mini, .full, .expanded] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                    let dark = appearance == .darkAqua || appearance == .accessibilityHighContrastDarkAqua
                    let contrast = appearance == .accessibilityHighContrastAqua || appearance == .accessibilityHighContrastDarkAqua
                    let host = NSHostingView(rootView: BootstrapCard(model: model, mode: mode).padding(16).frame(width: width)
                        .modifier(PanelCardBackground(block: .bootstrap)).environment(\.mimicInsideSurface, true)
                        .environment(MimicAppearancePreview(increasedContrast: contrast)).environment(\.colorScheme, dark ? .dark : .light))
                    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = host
                    let size = host.fittingSize; #expect(abs(size.width - width) < 1); #expect(size.height < 800)
                    host.frame = NSRect(origin: .zero, size: size); window.setContentSize(size); window.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("bootstrap-\(mode)-\(Int(width))-\(appearance.rawValue).png"))
                    window.close()
                }
            }
        }
    }

    @Test func encryptedFinalPacketSurvivesCompletionAndContextChangesOnlyAllowClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapChannel-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try #require(UserDefaults(suiteName: suite))
        let model = TaskCoordinator(directory: root, defaults: defaults)
        let integration = MimicIntegration(model: model, defaults: defaults)
        defer { integration.stop(); model.records = []; model.stopAndExit(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path), other = ProjectContext(path: root.appendingPathComponent("other").path)
        model.projects = [project, other]; model.selectedProjectPath = project.path
        var workspace = PanelWorkspace(); workspace.checkout = project.path
        try integration.workspaceStore.save(workspace, for: "fixture-chat")
        var record = TaskRecord(action: .bootstrap, project: project); record.status = .running; model.records = [record]
        let client = P256.KeyAgreement.PrivateKey()
        let opened = try await integration.panelRequest(MimicBridgeRequest(method: "panel_terminal_open", parameters: ["taskID": .string(record.id.uuidString), "publicKey": .string(client.publicKey.x963Representation.base64EncodedString())], threadID: "fixture-chat"))
        let channelID = try #require(opened["channelID"].string)
        let encodedPublicKey = try #require(opened["publicKey"].string)
        let publicKeyBytes = try #require(Data(base64Encoded: encodedPublicKey))
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: publicKeyBytes)
        let key = try client.sharedSecretFromKeyAgreement(with: publicKey).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(channelID.utf8), sharedInfo: Data("mimic-panel-terminal-v1".utf8), outputByteCount: 32)
        model.records[0].hasPrivateInput = true
        model.terminalOutput?(record.id, Data("FINAL PRIVATE FIXTURE OUTPUT\r\n".utf8)); model.records[0].status = .succeeded
        let packetValue = try await integration.panelRequest(MimicBridgeRequest(method: "panel_terminal_poll", parameters: ["channelID": .string(channelID)], threadID: "fixture-chat"))
        let packet = try JSONDecoder().decode(PanelCiphertext.self, from: JSONEncoder().encode(packetValue))
        let box = try AES.GCM.SealedBox(combined: try #require(Data(base64Encoded: packet.data)))
        let plaintext = try AES.GCM.open(box, using: key, authenticating: Data("\(channelID)|\(record.id.uuidString)|fixture-chat|output|\(packet.sequence)".utf8))
        let payload = try JSONDecoder().decode(BridgeValue.self, from: plaintext)
        #expect(payload["finished"] == .bool(true)); #expect(payload["canInput"] == .bool(false))
        #expect(payload["outputAvailable"] == .bool(true))
        let encodedOutput = try #require(payload["bytes"].string)
        let outputBytes = try #require(Data(base64Encoded: encodedOutput))
        #expect(String(decoding: outputBytes, as: UTF8.self).contains("FINAL PRIVATE FIXTURE OUTPUT"))
        #expect(!String(decoding: try JSONEncoder().encode(packetValue), as: UTF8.self).contains("FINAL PRIVATE FIXTURE OUTPUT"))
        #expect(integration.terminalChannels.values.first?.snapshot.isEmpty == true)
        workspace.checkout = other.path; try integration.workspaceStore.save(workspace, for: "fixture-chat")
        await #expect(throws: (any Error).self) { try await integration.panelRequest(MimicBridgeRequest(method: "panel_terminal_poll", parameters: ["channelID": .string(channelID)], threadID: "fixture-chat")) }
        let closed = try await integration.panelRequest(MimicBridgeRequest(method: "panel_terminal_close", parameters: ["channelID": .string(channelID)], threadID: "fixture-chat"))
        #expect(closed["closed"] == .bool(true)); #expect(integration.terminalChannels.isEmpty)
    }

}

/// The PTY fixture never queries or closes the user's actual Xcode applications.
@MainActor private final class BootstrapFixtureXcode: XcodeApplicationService {
    var hasRunningXcode: Bool { false }
    func closeXcode(timeout: Duration) async -> Bool { true }
    func activateXcode() {}
}
