//
//  PersonalCIAppTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

private actor PersonalAppClient: GitLabService {
    func project(baseURL _: URL, path: String, token _: String) async throws -> CIProject { throw CIError.invalidConfiguration }
    func currentUser(connection _: GitLabConnection, token _: String) async throws -> CIUser { CIUser(id: 1, username: "vmaslov", name: "Василий Маслов") }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] { [] }
    func pipelines(connection _: GitLabConnection, branch _: String, token _: String) async throws -> [CIPipeline] { throw CIError.invalidResponse }
    func pipeline(connection _: GitLabConnection, id _: Int, token _: String) async throws -> CIPipeline { throw CIError.notFound }
    func details(connection _: GitLabConnection, pipelineID _: Int, token _: String) async throws -> CIPipelineDetails { CIPipelineDetails(jobs: [], bridges: []) }
    func pipelinePage(connection _: GitLabConnection, username: String?, page _: Int, perPage _: Int, token _: String) async throws -> CIPipelinePage {
        guard let username else { return CIPipelinePage(pipelines: []) }
        let id = username == "vmaslov" ? 10 : 100
        let body: [String: Any] = ["id": id, "sha": "remote-sha", "status": "success", "ref": "feature/\(username)/APP-00001-synthetic-navigation-and-interface-layout-fixturexxxxx", "web_url": "https://gitlab.example.invalid/pipelines/\(id)"]
        let pipeline = try JSONDecoder().decode(CIPipeline.self, from: JSONSerialization.data(withJSONObject: body))
        return CIPipelinePage(pipelines: [pipeline])
    }
}

@MainActor private struct PersonalAppCredentials: CICredentialStore {
    func token(for _: UUID, interaction: CICredentialInteraction = .silent) throws -> String { "fixture" }
    func save(_: String, for _: UUID) throws { }
    func remove(_: UUID) throws { }
}

@MainActor struct PersonalCIAppTests {
    @Test func trackedColleagueDoesNotChangeFooterAndLongContentFitsPanel() async throws {
        let suite = "PersonalCIApp-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = GitLabConnection(baseURL: URL(string: "https://gitlab.example.invalid")!, projectID: 272, projectPath: "team/mobile")
        let store = DefaultsCIConfigurationStore(defaults: defaults)
        var configuration = CIConfiguration(); configuration.connections = [connection]; configuration.checkouts["/fixture"] = connection.id; store.save(configuration)
        let client = PersonalAppClient(), settings = CISettingsModel(credentials: PersonalAppCredentials(), store: store, client: client)
        settings.selectCheckout("/fixture")
        let state = CIState(client: client, trackingStore: DefaultsCITrackingStore(defaults: defaults)) { _ in "fixture" }
        state.select(CIContext(project: ProjectContext(path: "/fixture", branch: "develop", commit: "local"), connection: connection))
        state.setVisible(true); defer { state.setVisible(false) }
        try await self.wait { !state.loading }
        let button = FooterCIButton(state: state, settings: settings, expanded: true, action: {})
        #expect(button.presentation.pipeline?.id == 10 && !button.presentation.otherCommit)
        state.track(CIUser(id: 2, username: "colleague-with-a-long-username", name: "Константин Александрович Вишневский-Ковальчук"))
        try await self.wait { !state.loading }
        #expect(state.trackedUsers.first?.pipelines.first?.id == 100)
        #expect(button.presentation.pipeline?.id == 10 && button.presentation.color == .green)
        let output = URL(fileURLWithPath: "/private/tmp/MimicPersonalCI-20261005")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width: CGFloat in [320, 408] {
            for dark in [false, true] {
                let view = Surface { CISection(state: state, settings: settings, expanded: .constant(true)) }
                    .font(MimicMetrics.body).tint(.indigo).environment(\.colorScheme, dark ? .dark : .light).frame(width: width)
                let host = NSHostingView(rootView: view), size = host.fittingSize
                #expect(abs(size.width - width) < 1 && size.height < 1000)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host; host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("ci-\(Int(width))-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() { return }; try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
