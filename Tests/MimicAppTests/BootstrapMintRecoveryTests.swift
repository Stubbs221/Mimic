//
//  BootstrapMintRecoveryTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 27.10.2026.
import AppKit
import Foundation
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor private final class MintFixtureXcode: XcodeApplicationService {
    var hasRunningXcode = true
    var closeCount = 0
    func closeXcode(timeout: Duration) async -> Bool { closeCount += 1; hasRunningXcode = false; return true }
    func activateXcode() { }
}

/// Fake brew and Bootstrap run exclusively in a disposable checkout; no real package is installed.
@MainActor private struct MintFixture {
    let root: URL
    let defaults: UserDefaults
    let model: TaskCoordinator
    let xcode = MintFixtureXcode()
    let project: ProjectContext

    init(mode: String = "success") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MintRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tools"), withIntermediateDirectories: true)
        try Data("# Fixture only.\n".utf8).write(to: root.appendingPathComponent("README"))
        for arguments in [["init", "-b", "main"], ["add", "README"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"]] {
            try #require(EnvironmentInspector.capture("/usr/bin/git", ["-C", root.path] + arguments).0 == 0)
        }
        project = try EnvironmentInspector.project(path: root.path)
        let brew = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$PWD/install.arguments"
        case "$FIXTURE_MINT_MODE" in
          fail) exit 7 ;;
          noMint) exit 0 ;;
          changed) /usr/bin/git switch -c changed ;;
        esac
        printf '#!/bin/sh\\nexit 0\\n' > "$PWD/tools/mint"
        /bin/chmod +x "$PWD/tools/mint"
        """
        try Data(brew.utf8).write(to: root.appendingPathComponent("tools/brew"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("tools/brew").path)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$PWD/bootstrap.arguments\"\n".utf8).write(to: root.appendingPathComponent("bootstrap.sh"))
        var json = try #require(JSONSerialization.jsonObject(with: Profile11Fixture.data()) as? [String: Any])
        var actions = try #require(json["actions"] as? [[String: Any]])
        let index = try #require(actions.firstIndex { $0["presentation"] as? String == "preparation" })
        actions[index]["requiredTools"] = ["mint"]
        actions[index]["steps"] = [["executable": "/bin/sh", "arguments": ["${checkout}/bootstrap.sh", "${input_bootstrap_device}", "${input_bootstrap_match}"], "directory": "${checkout}"]]
        json["actions"] = actions
        let storage = root.appendingPathComponent("state")
        _ = try Profile11Fixture.install(directory: storage, data: JSONSerialization.data(withJSONObject: json))
        defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TaskHost")
        model = TaskCoordinator(directory: storage, helperURL: helper, xcodeApplications: xcode, defaults: defaults)
        model.projects = [project]; model.selectedProjectPath = project.path
        let path = root.appendingPathComponent("tools").path
        model.bootstrapEnvironment = { current in
            var env = EnvironmentInspector.environment(project: current)
            env["PATH"] = path + ":/usr/bin:/bin"
            env["FIXTURE_MINT_MODE"] = mode
            return env
        }
    }

    func cleanUp() {
        model.stopAndExit()
        defaults.removePersistentDomain(forName: root.lastPathComponent)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct BootstrapMintRecoveryTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func explicitInstallContinuesOnceWithCapturedOptionsAndNormalXcodePreparation() async throws {
        let fixture = try MintFixture(); defer { fixture.cleanUp() }
        var options = BootstrapPreset.simulator.options
        options.match = false
        fixture.model.request(.bootstrap, options: options)
        try await waitUntil { fixture.model.mintRecoveryRequest != nil && !fixture.model.requestingBootstrap }
        let original = try #require(fixture.model.mintRecoveryRecord)
        #expect(fixture.model.records.isEmpty)
        #expect(fixture.xcode.closeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("install.arguments").path))
        fixture.model.bootstrapOptions = .standard()
        fixture.model.installMintAndContinue(); fixture.model.installMintAndContinue()
        try await waitUntil { fixture.model.records.first?.status == .succeeded }
        let result = try #require(fixture.model.records.first)
        #expect(fixture.model.records.count == 1)
        #expect(result.id == original.id); #expect(result.options == options)
        #expect(result.profileExecution == original.profileExecution)
        #expect(result.installingMint == false); #expect(result.completedProfileSteps == 1)
        #expect(fixture.xcode.closeCount == 1)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("install.arguments"), encoding: .utf8) == "install mint\n")
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("bootstrap.arguments"), encoding: .utf8) == "false false\n")
        #expect(fixture.model.mintRecoveryRecord == nil)
    }

    @Test(arguments: ["fail", "noMint", "changed"])
    func installationFailureOrChangedCheckoutNeverLaunchesBootstrap(_ mode: String) async throws {
        let fixture = try MintFixture(mode: mode); defer { fixture.cleanUp() }
        fixture.model.requestQuickBootstrap(platform: .ios)
        try await waitUntil { fixture.model.canInstallMint }
        fixture.model.installMintAndContinue()
        try await waitUntil { fixture.model.records.first?.status == .failed }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("bootstrap.arguments").path))
        #expect(fixture.model.records.first?.completedProfileSteps == nil)
        #expect(fixture.xcode.closeCount == 0)
        if mode != "changed" {
            #expect(fixture.model.canInstallMint)
            #expect(fixture.model.mintRecoveryRecord?.installingMint == true)
        }
    }

    @Test func approvedInstallWaitsBehindExistingLocalWorkAndHistoryDoesNotResumeAfterRestart() async throws {
        let fixture = try MintFixture(); defer { fixture.cleanUp() }
        var barrier = TaskRecord(action: .format, project: fixture.project); barrier.status = .running
        fixture.model.records = [barrier]
        fixture.model.requestQuickBootstrap(platform: .ios)
        try await waitUntil { fixture.model.canInstallMint }
        fixture.model.installMintAndContinue()
        try await waitUntil { fixture.model.records.count == 2 && !fixture.model.requestingBootstrap }
        let queued = try #require(fixture.model.records.last)
        #expect(queued.status == .queued); #expect(queued.installingMint == true)
        #expect(!queued.requiresXcodeQuit)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("install.arguments").path))
        let history = HistoryStore(directory: fixture.root.appendingPathComponent("reload"))
        try history.save([queued])
        let recovered = try #require(try history.load().first)
        #expect(recovered.status == .interrupted); #expect(recovered.installingMint == true)
        fixture.model.records = []
    }

    @Test func nativeRecoveryCardsKeepOneForwardControlWithinBounds() async throws {
        let fixture = try MintFixture(); defer { fixture.cleanUp() }
        fixture.model.requestQuickBootstrap(platform: .ios)
        try await waitUntil { fixture.model.canInstallMint }
        let output = URL(fileURLWithPath: "/private/tmp/mimic-mint-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func controls(_ node: NSView) -> [PanelControlRegion.MarkerView] {
            if let marker = node as? PanelControlRegion.MarkerView { return [marker] }
            return node.subviews.flatMap(controls)
        }
        for (name, content, width) in [
            ("floating", AnyView(QuickBootstrapView(model: fixture.model, showMimic: {})), CGFloat(320)),
            ("mini", AnyView(BootstrapCard(model: fixture.model, mode: .mini).padding(12).modifier(MimicCardBackground())), CGFloat(250)),
            ("full", AnyView(BootstrapCard(model: fixture.model, mode: .full).padding(12).modifier(MimicCardBackground())), CGFloat(560))
        ] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: content.frame(width: width)
                    .environment(\.mimicPanelAppearance, .tileGrid).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .titled, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                window.makeKeyAndOrderFront(nil); host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
                let buttons = controls(host).filter { $0.bounds.height > 0 && $0.bounds.height <= 32 }
                #expect(buttons.count == 1)
                for button in buttons {
                    let bounds = host.convert(button.bounds, from: button)
                    #expect(bounds.height >= 28)
                    #expect(host.bounds.contains(bounds))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
                window.close()
            }
        }
    }
}
