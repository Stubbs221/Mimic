//
//  CIRedesignAppTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
import SwiftUI
import Testing
import MimicCore
@testable import Mimic

@MainActor private final class LaunchCredentials: CICredentialStore {
    private var values: [UUID: String] = [:]
    var denied = false
    func token(for id: UUID, interaction: CICredentialInteraction = .silent) throws -> String { if self.denied { throw CICredentialAccessError.accessRequired }; guard let token = self.values[id] else { throw CIError.credential }; return token }
    func save(_ token: String, for id: UUID) throws { self.values[id] = token }
    func remove(_ id: UUID) throws { self.values[id] = nil }
}

private actor LaunchHTTP: CIHTTPTransport {
    private(set) var paths: [String] = []
    private(set) var posts = 0
    private(set) var submittedBranches: [String] = []
    private var qualityDenied = false
    func denyQualityGates() { self.qualityDenied = true }
    func send(_ request: URLRequest) async throws -> CIHTTPResponse {
        let path = request.url!.path; self.paths.append(path)
        if path.hasSuffix("/whoAmI/api/json") { return CIHTTPResponse(data: Data(#"{"authenticated":true,"anonymous":false}"#.utf8), status: 200) }
        if request.httpMethod == "POST" {
            self.posts += 1
            let items = URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems
            let branch = items?.first { $0.name == "BRANCH" }?.value ?? ""
            self.submittedBranches.append(branch)
            // The production Git Parameter definition rejects the unqualified GitLab branch.
            return CIHTTPResponse(data: Data(), status: branch == "origin/develop" ? 201 : 400, location: "/queue/item/7/")
        }
        if path.contains("/queue/item/") { return CIHTTPResponse(data: Data(#"{"why":"Waiting for executor"}"#.utf8), status: 200) }
        if path.hasSuffix("/repository/branches/develop") { return CIHTTPResponse(data: Data(#"{"name":"develop"}"#.utf8), status: 200) }
        if path.hasSuffix("/repository/branches") { return CIHTTPResponse(data: Data(#"[{"name":"develop"},{"name":"feature/vmaslov/APP-00001-synthetic-navigation-and-interface-layout-fixturexxxxx"}]"#.utf8), status: 200) }
        if self.qualityDenied, path.contains("ios_launch_qualitygates") { return CIHTTPResponse(data: Data(), status: 403) }
        var definitions: [[String: Any]] = []
        if path.contains("ios_ui_tests_simulator") {
            definitions = [["name": "BRANCH", "_class": "net.uaznia.lukanus.hudson.plugins.gitparameter.GitParameterDefinition",
                            "allValueItems": ["values": [["value": "origin/develop"]], "errors": []]],
                           ["name": "TEST_PLAN", "choices": ["SMOKE", "FUNCTIONAL", "STATS", "FULL"], "defaultParameterValue": ["value": "SMOKE"]]]
        } else if path.contains("ios_beta") {
            definitions = [["name": "SELECTED_BRANCH"], ["name": "TARGET", "choices": ["movie"], "defaultParameterValue": ["value": "movie"]],
                           ["name": "REBASE_BRANCH", "defaultParameterValue": ["value": ""]],
                           ["name": "UPLOAD_TO_APP_DISTRIBUTION", "choices": ["FALSE", "TRUE"], "defaultParameterValue": ["value": "FALSE"]]]
        } else if path.contains("ios_launch_qualitygates") {
            definitions = [["name": "SELECTED_BRANCH"]] + QualityGate.allCases.map { ["name": $0.rawValue, "_class": "hudson.model.BooleanParameterDefinition", "defaultParameterValue": ["value": $0 != .performance]] }
        }
        let data = try JSONSerialization.data(withJSONObject: ["property": [["parameterDefinitions": definitions]]])
        return CIHTTPResponse(data: data, status: 200)
    }
}

private actor CIAppClient: GitLabService {
    let values: [CIPipeline]
    let jobs: [CIJob]
    let failedJobs: [CIJob]
    let finishedJobs: [CIJob]
    let mode: String
    init(mode: String = "") throws {
        self.mode = mode
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let now = (mode == "old" ? Date(timeIntervalSince1970: 1704067200) : Date().addingTimeInterval(-120)).ISO8601Format()
        let values = (1 ... 5).map { id in
            ["id": id, "project_id": 272, "status": id == 5 ? (["pending", "manual", "waiting_for_resource"].contains(mode) ? mode : mode == "optional" || mode == "missing" || mode == "old" ? "success" : "running") : id == 4 ? "failed" : "success",
             "sha": "769459e0original-commit", "ref": "feature/vmaslov/APP-00001-synthetic-navigation-and-interface-layout-fixturexxxxx",
             "name": id == 5 ? "UI-тесты" : id == 4 ? "Quality Gates" : "Beta", "created_at": now, "started_at": now,
             "duration": mode == "old" ? 3661 : 120, "web_url": "https://gitlab.example.invalid/team/mobile/-/pipelines/\(id)"] as [String: Any]
        }
        let metadata = values.map { original -> [String: Any] in
            var value = original
            if mode == "missing" || mode == "pending" { value.removeValue(forKey: "started_at"); value.removeValue(forKey: "duration") }
            return value
        }
        self.values = try decoder.decode([CIPipeline].self, from: JSONSerialization.data(withJSONObject: metadata))
        let jobs: [[String: Any]] = (1 ... 4).map { id in
            ["id": id, "name": id < 3 ? "ui-tests-functional-ios-iPad-Pro-13-inch-M5" : "check-\(id)", "stage": "test", "status": id < 3 ? "running" : id == 3 ? "success" : "manual", "allow_failure": id == 4, "started_at": now,
             "web_url": "https://gitlab.example.invalid/team/mobile/-/jobs/\(id)", "commit": ["id": "769459e0original-commit", "title": "APP-00001: Проверить синтетический сценарий навигации в демонстрационном приложении!!!!!!!!!!!"]]
        }
        let active = jobs.map { original -> [String: Any] in
            var job = original
            if mode == "single", job["id"] as? Int == 2 { job["status"] = "success" }
            if mode == "manual", job["id"] as? Int == 1 { job["status"] = "manual" }
            if mode == "optional" { job["status"] = "success"; if job["id"] as? Int == 1 { job["status"] = "failed"; job["allow_failure"] = true } }
            return job
        }
        self.jobs = try decoder.decode([CIJob].self, from: JSONSerialization.data(withJSONObject: active))
        self.failedJobs = try decoder.decode([CIJob].self, from: JSONSerialization.data(withJSONObject: jobs.map { value in
            var value = value; value["status"] = value["id"] as? Int == 1 ? "failed" : "success"; return value
        }))
        self.finishedJobs = try decoder.decode([CIJob].self, from: JSONSerialization.data(withJSONObject: jobs.map { value in
            var value = value; value["status"] = "success"; return value
        }))
    }
    func project(baseURL _: URL, path: String, token _: String) async throws -> CIProject { throw CIError.invalidResponse }
    func currentUser(connection _: GitLabConnection, token _: String) async throws -> CIUser { CIUser(id: 1, username: "vmaslov-extremely-long-colleague-username", name: "Василий Маслов") }
    func users(connection _: GitLabConnection, search _: String, token _: String) async throws -> [CIUser] { [] }
    func pipelines(connection _: GitLabConnection, branch _: String, token _: String) async throws -> [CIPipeline] { self.values }
    func pipelinePage(connection _: GitLabConnection, username: String?, page _: Int, perPage _: Int, token _: String) async throws -> CIPipelinePage { CIPipelinePage(pipelines: username == nil ? [] : self.values) }
    func pipeline(connection _: GitLabConnection, id: Int, token _: String) async throws -> CIPipeline { self.values.first { $0.id == id }! }
    func commit(connection _: GitLabConnection, sha: String, token _: String) async throws -> CICommit { if self.mode == "missing" { throw CIError.notFound }; return CICommit(id: sha, title: self.jobs.first!.commit!.title) }
    func details(connection _: GitLabConnection, pipelineID: Int, token _: String) async throws -> CIPipelineDetails { CIPipelineDetails(jobs: pipelineID == 5 ? self.jobs : pipelineID == 4 ? self.failedJobs : self.finishedJobs, bridges: [], bridgeError: self.mode == "partial" ? .network : nil) }
}

@MainActor struct CIRedesignAppTests {
    private func wait(_ label: String = "fixture state", until condition: () -> Bool) async throws {
        for _ in 0 ..< 500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "Timed out waiting for \(label)")
    }

    @Test func optionalCapabilitiesAndFormsDoNotFilterOrSubmitUntilExplicitAction() async throws {
        let suite = "CILaunchApp-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL(fileURLWithPath: "/private/tmp/CILaunchApp-" + UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let connection = GitLabConnection(baseURL: URL(string: "https://gitlab.example.invalid")!, projectID: 272, projectPath: "team/mobile")
        let store = DefaultsCIConfigurationStore(defaults: defaults)
        var config = CIConfiguration(); config.connections = [connection]; config.checkouts["/fixture"] = connection.id; store.save(config)
        let credentials = LaunchCredentials(); try credentials.save("fixture", for: connection.id)
        let settings = CISettingsModel(credentials: credentials, store: store); settings.selectCheckout("/fixture")
        let http = LaunchHTTP(), client = JenkinsClient(transport: http)
        let jenkins = JenkinsSettings(defaults: defaults, credentials: credentials, client: client)
        jenkins.address = "https://jenkins.example.invalid"; jenkins.username = "me"; jenkins.enteredToken = "fixture"; jenkins.check()
        try await self.wait { !jenkins.checking }; #expect(jenkins.verified); jenkins.save()
        let owner = ProfileRemoteCoordinator(directory: directory, jenkins: client, gitlab: GitLabClient(transport: http), jenkinsToken: { try jenkins.token(for: $0) }, gitlabToken: { try settings.token(for: $0) })
        defer { owner.stop() }
        let preferences = CILaunchPreferences(defaults: defaults), project = ProjectContext(path: "/fixture", branch: "develop")
        let launch = CILaunchModel(preferences: preferences, settings: jenkins, gitlabSettings: settings, coordinator: owner, snapshot: { try? Profile11Fixture.snapshot(directory: directory, legacyCI: true) },
            submitProfile: { snapshot, action, values, id, contract, project in
                try await owner.submit(id: id, checkout: project, execution: ProfileExecution(snapshot: snapshot, actionID: action.id, parameters: values), jenkins: jenkins.connection!, gitlab: settings.connection, reviewed: contract, validate: {})
            }, client: client, gitlab: GitLabClient(transport: http), project: { project }, validate: { _ in })
        launch.setVisible(true); defer { launch.setVisible(false) }
        try await self.wait { launch.checking.isEmpty }
        #expect(launch.contracts.keys.sorted { $0.rawValue < $1.rawValue } == [.uiTests])
        #expect(await http.paths.allSatisfy { !$0.contains("ios_beta") && !$0.contains("ios_launch_qualitygates") })
        preferences.beta = true; preferences.qualityGates = true
        try await self.wait { launch.contracts.count == 3 && launch.checking.isEmpty }
        launch.open(.beta); try await self.wait { launch.branch == "develop" }
        #expect(launch.betaValue(.upload) == "FALSE")
        preferences.beta = false; #expect(launch.selected == nil)
        #expect(await http.posts == 0)
        await http.denyQualityGates(); launch.refreshCapabilities()
        try await self.wait { launch.checking.isEmpty }
        #expect(launch.contracts[.uiTests] != nil && launch.contracts[.qualityGates] == nil && launch.capabilityErrors[.qualityGates] != nil)
        launch.open(.uiTests); try await self.wait { launch.branch == "develop" }
        let reviewed = launch.reviewedContract
        launch.plan = .functional
        launch.setVisible(false, preserveDraft: true)
        #expect(launch.selected == .uiTests && launch.branch == "develop" && launch.plan == .functional)
        #expect(launch.reviewedContract == reviewed && launch.checking.isEmpty)
        launch.setVisible(true); try await self.wait { launch.checking.isEmpty }
        #expect(launch.selected == .uiTests && launch.plan == .functional)
        launch.submit(); launch.submit()
        try await self.wait { !launch.submitting && owner.runs.count == 1 }
        #expect(await http.posts == 1)
        #expect(owner.runs.first?.execution.binding?.role == .uiTests)
        #expect(owner.runs.first?.branch == "develop" && owner.runs.first?.status == "queued")
        #expect(await http.submittedBranches == ["origin/develop"])
        launch.setVisible(false); #expect(owner.runs.count == 1)
    }

    @Test func nativeEdgeCardsAndCredentialBanners() async throws {
        let output = URL(fileURLWithPath: "/private/tmp/MimicCIRedesign-20261005")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let connection = GitLabConnection(baseURL: URL(string: "https://gitlab.example.invalid")!, projectID: 272, projectPath: "team/mobile")
        for mode in ["single", "pending", "manual", "waiting_for_resource", "old", "missing", "partial", "optional", "one-banner", "two-banners"] {
            let state = CIState(client: try CIAppClient(mode: mode)) { _ in "fixture" }
            state.select(CIContext(project: ProjectContext(path: "/fixture"), connection: connection))
            state.setFeedPresented(true); state.setVisible(true)
            try await self.wait { !state.loading && state.metadataStates.count == 3 && !state.metadataStates.values.contains(.loading) && !state.checkStates.values.contains(.loading) }
            if mode == "optional" { state.loadDetails(5); try await self.wait { state.checkStates[5] == .loaded } }
            let credentials = LaunchCredentials(); credentials.denied = true
            let first = CICredentialSession(store: credentials), second = CICredentialSession(store: credentials)
            if mode.contains("banner") { _ = try? first.token(for: connection.id) }
            if mode == "two-banners" { _ = try? second.token(for: connection.id) }
            for width: CGFloat in [320, 408, 440] {
                for dark in [false, true] {
                    for contrast in [false, true] {
                        let view = Surface {
                            VStack(alignment: .leading, spacing: 10) {
                                CICredentialAccessView(session: first, id: connection.id, service: "GitLab") { }
                                CICredentialAccessView(session: second, id: connection.id, service: "Jenkins") { }
                                if let entry = state.visibleEntries.first { CIPipelineCard(state: state, entry: entry) }
                            }
                        }.environment(\.colorScheme, dark ? .dark : .light).environment(MimicAppearancePreview(increasedContrast: contrast)).frame(width: width)
                        let host = NSHostingView(rootView: view), size = host.fittingSize
                        #expect(abs(size.width - width) < 1 && size.height < 1400)
                        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.contentView = host; host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("edge-\(mode)-\(Int(width))-\(dark ? "dark" : "light")-\(contrast ? "contrast" : "normal").png"))
                        window.contentView = nil; window.close()
                    }
                }
            }
            state.setVisible(false)
        }
    }

    @Test func nativeCardsFitLongDataInLightDarkAndContrast() async throws {
        let suite = "CIRenderApp-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = GitLabConnection(baseURL: URL(string: "https://gitlab.example.invalid")!, projectID: 272, projectPath: "team/mobile")
        let store = DefaultsCIConfigurationStore(defaults: defaults)
        var config = CIConfiguration(); config.connections = [connection]; config.checkouts["/fixture"] = connection.id; store.save(config)
        let credentials = LaunchCredentials(); try credentials.save("fixture", for: connection.id)
        let settings = CISettingsModel(credentials: credentials, store: store); settings.selectCheckout("/fixture")
        let http = LaunchHTTP(), client = JenkinsClient(transport: http)
        let jenkins = JenkinsSettings(defaults: defaults, credentials: credentials, client: client)
        jenkins.address = "https://jenkins.example.invalid"; jenkins.username = "me"; jenkins.enteredToken = "fixture"; jenkins.check()
        try await self.wait { !jenkins.checking }; jenkins.save()
        let directory = URL(fileURLWithPath: "/private/tmp/CIRenderOwner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = ProfileRemoteCoordinator(directory: directory, jenkins: client, gitlab: GitLabClient(transport: http), jenkinsToken: { try jenkins.token(for: $0) }, gitlabToken: { try settings.token(for: $0) })
        defer { owner.stop() }
        let preferences = CILaunchPreferences(defaults: defaults)
        let launch = CILaunchModel(preferences: preferences, settings: jenkins, gitlabSettings: settings, coordinator: owner, snapshot: { try? Profile11Fixture.snapshot(directory: directory, legacyCI: true) },
            submitProfile: { snapshot, action, values, id, contract, project in
                try await owner.submit(id: id, checkout: project, execution: ProfileExecution(snapshot: snapshot, actionID: action.id, parameters: values), jenkins: jenkins.connection!, gitlab: settings.connection, reviewed: contract, validate: {})
            }, client: client, gitlab: GitLabClient(transport: http), project: { ProjectContext(path: "/fixture", branch: "develop") }, validate: { _ in })
        launch.setVisible(true); defer { launch.setVisible(false) }
        try await self.wait { launch.checking.isEmpty }
        let state = CIState(client: try CIAppClient()) { _ in "fixture" }
        state.select(CIContext(project: ProjectContext(path: "/fixture", branch: "develop", commit: "other"), connection: connection))
        state.setFeedPresented(true); state.setVisible(true); defer { state.setVisible(false) }
        try await self.wait { state.metadataStates.count == 3 && state.metadataStates.values.allSatisfy { $0 == .loaded } && state.summaries.count == 2 }
        let output = URL(fileURLWithPath: "/private/tmp/MimicCIRedesign-20261005")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width: CGFloat in [320, 408, 440] {
            for dark in [false, true] {
                for contrast in [false, true] {
                    launch.setVisible(true); try await self.wait { launch.checking.isEmpty }
                    state.setFeedPresented(true)
                    let view = Surface { CISection(state: state, settings: settings, launch: launch, expanded: .constant(true)) }
                        .environment(\.colorScheme, dark ? .dark : .light).environment(MimicAppearancePreview(increasedContrast: contrast)).frame(width: width)
                    let host = NSHostingView(rootView: view), size = host.fittingSize
                    #expect(abs(size.width - width) < 1 && size.height < 1100)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host; host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("ci-\(Int(width))-\(dark ? "dark" : "light")-\(contrast ? "contrast" : "normal").png"))
                    window.contentView = nil; window.close()
                    try await Task.sleep(for: .milliseconds(25))
                }
            }
        }
        launch.setVisible(true); preferences.beta = true; preferences.qualityGates = true
        try await self.wait("all form capabilities") { launch.contracts.count == 3 && launch.checking.isEmpty }
        for kind in RemoteCIKind.allCases {
            launch.open(kind); try await self.wait("branch for " + kind.rawValue) { launch.branch == "develop" }
            let view = Surface { CILaunchActions(launch: launch, preferences: preferences) }.frame(width: 320)
            let host = NSHostingView(rootView: view), size = host.fittingSize
            #expect(size.width == 320 && size.height < 800)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("form-" + kind.rawValue + ".png"))
            window.contentView = nil; window.close(); launch.close()
            try await Task.sleep(for: .milliseconds(25))
            launch.setVisible(true); try await self.wait { launch.checking.isEmpty }
        }
        #expect(state.visibleEntries.count == 3 && state.canShowMore)
        #expect(ciElapsed(-10) == "0:00" && ciElapsed(.nan) == "—" && ciElapsed(3661) == "1:01:01")
    }
}
