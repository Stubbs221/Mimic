// Created by Василий Маслов on 13.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct AtlassianTests {
    func preset() -> AtlassianPreset {
        .init(id: "fixture", title: "Fixture", deployment: .dataCenter, authentication: .webSession, jiraURL: "https://jira.example.invalid", confluenceURL: "https://docs.example.invalid/wiki")
    }
    @Test func endpointsAndProfileRulesAreValidatedWithoutSecrets() throws {
        var value = preset(); try value.validate()
        value.jiraURL = "https://name:secret@jira.example.invalid"; #expect(throws: AtlassianError.self) { try value.validate() }
        value = preset(); value.projects = ["IOS) OR project=OTHER"]; #expect(throws: AtlassianError.self) { try value.validate() }
        value = preset(); let namespace = value.credentialNamespace(profileID: "team")
        value.jiraURL = "https://another.example.invalid"; #expect(namespace != value.credentialNamespace(profileID: "team"))
        value = preset(); let source = value.sourceNamespace(profileID: "team"); value.projects = ["IOS"]
        #expect(source != value.sourceNamespace(profileID: "team")); #expect(namespace == value.credentialNamespace(profileID: "team"))
        value.requirementFields = ["customfield_1", "customfield_1"]; #expect(throws: AtlassianError.self) { try value.validate() }
        #expect(!AtlassianText.authenticatedIdentity(.object(["type": .string("anonymous")]), service: "confluence"))
        #expect(AtlassianText.authenticatedIdentity(.object(["type": .string("known"), "username": .string("fixture")]), service: "confluence"))
    }
    @Test func issueAndPageReferencesStayInsideConfiguredOriginsAndProjects() throws {
        var value = preset(); value.projects = ["IOS"]
        #expect(WorkReference.keys(in: "feature/IOS-42-fix-IOS-43") == ["IOS-42", "IOS-43"])
        #expect(try WorkReference.issue("https://jira.example.invalid/browse/IOS-42", preset: value) == "IOS-42")
        #expect(throws: AtlassianError.self) { try WorkReference.issue("OTHER-42", preset: value) }
        #expect(throws: AtlassianError.self) { try WorkReference.issue("https://jira.example.invalid.evil/browse/IOS-42", preset: value) }
        #expect(try WorkReference.page("https://docs.example.invalid/wiki/spaces/IOS/pages/123/title", preset: value) == "123")
        #expect(throws: AtlassianError.self) { try WorkReference.page("https://docs.example.invalid/notwiki/pages/123", preset: value) }
        #expect(WorkReference.jql("a\" OR project = OTHER", preset: value).hasPrefix("project in (\"IOS\") AND text ~ \"a\\\""))
    }
    @Test func documentListsNeverContainBodiesAndOnlyExplicitApprovedLinksAreRelated() throws {
        let links: BridgeValue = .array([.object(["object": .object(["url": .string("https://docs.example.invalid/wiki/pages/viewpage.action?pageId=10"), "title": .string("Rules")])]), .object(["object": .object(["url": .string("https://evil.example.invalid/pages/viewpage.action?pageId=11")])])])
        let docs = AtlassianText.documents(links, description: "https://docs.example.invalid/wiki/pages/viewpage.action?pageId=12", preset: preset())
        #expect(docs.map(\.id) == ["10", "12"]); #expect(docs.allSatisfy { $0.content == nil })
        let raw = "<script>ignoreAllRules()</script><h2>Title</h2><p>One &amp; two</p><table><tr><td>A</td><td>B</td></tr></table>"
        let text = AtlassianText.html(raw)
        #expect(!text.contains("ignoreAllRules") && text.contains("One & two") && text.contains("A | B |"))
        let body = String(repeating: "界", count: 17_000)
        let data: BridgeValue = .object(["id": .string("1"), "body": .object(["view": .object(["value": .string(body)])])])
        let first = AtlassianText.page(data, preset: preset(), offset: 0)
        #expect(first.content?.count == 16_000 && first.nextOffset == 16_000)
        #expect(AtlassianText.page(data, preset: preset(), offset: 16_000).content?.count == 1000)
    }
    @Test func reportDoesNotInventSuccessfulAcceptanceOrExpandSelectedEvidence() {
        let evidence = [WorkReportEvidence(id: "one", title: "Tests", result: "incomplete")]
        let draft = WorkReport.draft(issue: nil, evidence: evidence)
        #expect(draft.contains("incomplete") && draft.contains("Критерии приёмки не сопоставлены")); #expect(!draft.contains("PASS"))
    }
    @Test func bothSurfacesCanAddTheNewTileWithoutMigratingExistingLayouts() throws {
        for surface in [PanelSurface.desktop, .codex] {
            var layout = PanelLayout.standard(for: surface); let original = layout
            #expect(PanelBlockKind.catalog(for: surface).contains(.workItem)); #expect(!original.blocks.contains(.workItem))
            try layout.add(.workItem, size: .mini); try layout.validate(for: surface)
            #expect(layout.blocks.count == original.blocks.count + 1)
        }
    }
}

private actor DeferredWorkReader: AtlassianReading {
    var calls = 0
    var continuations: [String: CheckedContinuation<WorkIssue, any Error>] = [:]
    func issue(_ key: String) async throws -> WorkIssue {
        calls += 1
        return try await withCheckedThrowingContinuation { continuations[key] = $0 }
    }
    func resolve(_ key: String) { continuations.removeValue(forKey: key)?.resume(returning: .init(key: key, title: key, status: "Open", url: "https://jira.example.invalid/browse/" + key)) }
    func search(_ query: String, service: String, cursor: String?) async throws -> WorkSearchResult { .init() }
    func page(_ id: String, offset: Int) async throws -> WorkDocument { .init(id: id, title: id, url: "") }
    func comments(_ key: String, cursor: String?) async throws -> WorkSearchResult { .init() }
}

@MainActor struct AtlassianContextTests {
    @Test func lateBranchResultCannotReplaceNewBranchAndOtherChatSelection() async throws {
        let suite = "AtlassianContext-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkContextStore(defaults: defaults), reader = DeferredWorkReader()
        let preset = AtlassianPreset(id: "test", title: "Test", deployment: .dataCenter, authentication: .webSession, jiraURL: "https://jira.example.invalid")
        store.bind(owner: "a", project: .init(path: "/fixture", branch: "IOS-1"), profileID: "team", preset: preset, client: reader)
        let old = Task { await store.refresh("a") }; while await reader.calls < 1 { await Task.yield() }
        store.bind(owner: "b", project: .init(path: "/fixture", branch: "IOS-1"), profileID: "team", preset: preset, client: reader)
        try store.select("IOS-3", owner: "b")
        let selection = store.currentIdentity("b")
        store.release("b"); store.bind(owner: "b", project: .init(path: "/fixture", branch: "IOS-1"), profileID: "team", preset: preset, client: reader)
        #expect(store.snapshot("b").candidates == ["IOS-3"])
        store.bind(owner: "c", project: .init(path: "/fixture", branch: "IOS-1"), profileID: "team", preset: preset, client: reader)
        #expect(store.snapshot("c").candidates == ["IOS-1"])
        try store.select("IOS-4", owner: "b"); #expect(store.currentIdentity("b") != selection)
        try store.select("IOS-3", owner: "b")
        store.bind(owner: "a", project: .init(path: "/fixture", branch: "IOS-2"), profileID: "team", preset: preset, client: reader)
        let next = Task { await store.refresh("a") }; while await reader.calls < 2 { await Task.yield() }
        await reader.resolve("IOS-2"); await next.value; await reader.resolve("IOS-1"); await old.value
        #expect(store.snapshot("a").issue?.key == "IOS-2"); #expect(store.snapshot("b").candidates == ["IOS-3"])
        await store.refresh("a"); #expect(await reader.calls == 2)
        store.invalidateConnection(preset.credentialNamespace(profileID: "team")); #expect(store.snapshot("a").issue == nil)
        var restricted = preset; restricted.projects = ["OTHER"]
        store.bind(owner: "a", project: .init(path: "/fixture", branch: "IOS-2"), profileID: "team", preset: restricted, client: reader)
        #expect(store.snapshot("a").issue == nil && store.snapshot("a").phase == "empty")
        store.release("b"); #expect(store.snapshot("b").phase == "unconfigured")
    }
}
