// Created by Василий Маслов on 16.10.2026.
import Foundation
import Testing
@testable import MimicCore

/// Opt-in only: creates one isolated account and never logs or persists its full response.
@MainActor @Suite(.serialized) struct ServiceToolLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_SERVICE_LIVE_NAMESPACE"] != nil))
    func authorizedAccountSmoke() async throws {
        let namespace = try #require(ProcessInfo.processInfo.environment["MIMIC_SERVICE_LIVE_NAMESPACE"])
        let archive = try #require(ProcessInfo.processInfo.environment["MIMIC_SERVICE_PROFILE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServiceLive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try ProfileStore(directory: root.appendingPathComponent("Profile")).importArchive(URL(fileURLWithPath: archive), requireInterface: true)
        let tool = try #require(snapshot.profile.serviceTools?.first)
        let suite = "ServiceLive-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = ServiceToolCoordinator(defaults: defaults, directory: root.appendingPathComponent("Receipts"))
        let context = ServiceToolContext(checkout: "/authorized-smoke", profileRevision: snapshot.revision, namespace: namespace, appVersion: "", sourceRevision: "explicit-user-test-target")
        let scope = ServiceToolCoordinator.scope(owner: "live-smoke", tool: tool.id, context: context)
        var checks: [[String: String]] = [], uid = "", email = ""
        for actionID in ["create", "find", "subscription", "expire", "cancelRenewal", "money"] {
            let action = try #require(tool.actions.first { $0.id == actionID })
            let variantID = actionID == "create" ? "random" : actionID == "find" ? "email" : "default"
            let parameters = actionID == "find" ? ["email": email] : actionID == "money" ? ["amount": "1"] : [:]
            let id = UUID()
            _ = try coordinator.start(owner: "live-smoke", tool: tool, context: context, actionID: actionID, variantID: variantID, uid: uid, values: parameters, requestID: id, stillCurrent: { true })
            let deadline = ContinuousClock.now.advanced(by: .seconds(40))
            while coordinator.result(scope: scope, requestID: id)["phase"] == .string("pending"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let result = coordinator.result(scope: scope, requestID: id)
            checks.append(["action": actionID, "phase": result["phase"].string ?? "missing", "httpStatus": String(result["httpStatus"].integer ?? 0)])
            if actionID == "create", result["phase"] == .string("success") { uid = ServiceToolCoordinator.string(result["data"]["uid"]); email = ServiceToolCoordinator.string(result["data"]["email"]) }
            if let report = ProcessInfo.processInfo.environment["MIMIC_SERVICE_LIVE_REPORT"] {
                try JSONSerialization.data(withJSONObject: ["namespace": namespace, "uid": uid, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: [.atomic])
            }
            // Do not include response bodies in a test failure: they may contain live credentials.
            try #require(result["phase"] == .string("success"), "Live action \(actionID): phase \(result["phase"].string ?? "missing"), HTTP \(result["httpStatus"].integer ?? 0)")
        }
    }
}
