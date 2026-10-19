// Created by Василий Маслов on 13.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

/// Explicit local qualification uses only dummy data in a disposable Keychain namespace.
@MainActor struct AtlassianCredentialTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_ATLASSIAN_KEYCHAIN_FIXTURE"] == "1", "Disposable local Keychain fixture"))
    func verifiedPairReplacesBothServicesAndLegacySessionsStayReadable() throws {
        let keychain = AtlassianKeychain(namespace: "fixture-" + UUID().uuidString)
        defer { for account in ["jira", "confluence", "restSessions"] { keychain.remove(account) } }
        let preset = AtlassianPreset(id: "fixture", title: "Fixture", deployment: .dataCenter, authentication: .personalAccessToken, jiraURL: "https://jira.example.invalid", confluenceURL: "https://docs.example.invalid")
        try keychain.write(Data("legacy-jira".utf8), account: "jira")
        try keychain.write(Data("legacy-confluence".utf8), account: "confluence")
        #expect(try keychain.restHeaders(preset)["jira"]?["Authorization"] == "Bearer legacy-jira")
        try keychain.writeRESTSessions(["jira": Data("pair-jira".utf8), "confluence": Data("pair-confluence".utf8)])
        let headers = try keychain.restHeaders(preset)
        #expect(headers["jira"]?["Authorization"] == "Bearer pair-jira")
        #expect(headers["confluence"]?["Authorization"] == "Bearer pair-confluence")
        let pair = try JSONDecoder().decode([String: Data].self, from: keychain.data("restSessions"))
        #expect(Set(pair.keys) == ["jira", "confluence"])
    }
}
