// Created by Василий Маслов on 16.10.2026.
import Foundation
import Testing
@testable import MimicCore

@MainActor @Suite(.serialized) struct ServiceToolHTTPTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_SERVICE_PROFILE"] != nil))
    func allEightCommandsUseHTTPFormsAndDocumentedAcknowledgements() async throws {
        let profilePath = try #require(ProcessInfo.processInfo.environment["MIMIC_SERVICE_PROFILE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServiceHTTP-" + UUID().uuidString)
        let snapshot = try ProfileStore(directory: root.appendingPathComponent("Profile")).importArchive(URL(fileURLWithPath: profilePath), requireInterface: true)
        let tool = try #require(snapshot.profile.serviceTools?.first)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/service-http-server.py").path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
        let portText = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try #require(Int(portText))
        let suite = "ServiceHTTP-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = ServiceToolCoordinator(defaults: defaults, directory: root.appendingPathComponent("Receipts"), transport: { request in
            var local = request, url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.scheme = "http"; url.host = "127.0.0.1"; url.port = port; local.url = url.url
            let variant = tool.actions.flatMap(\.variants).first { $0.path == request.url?.path && $0.method == request.httpMethod }
            local.setValue(variant?.responseKind ?? "uid", forHTTPHeaderField: "X-Fixture-Response")
            return try await ServiceToolCoordinator.http(local)
        })
        let context = ServiceToolContext(checkout: "/fixture", profileRevision: snapshot.revision, namespace: "fixture", appVersion: "456", sourceRevision: "confirmed")
        let scope = ServiceToolCoordinator.scope(owner: "fixture", tool: tool.id, context: context)
        for action in tool.actions {
            for variant in action.variants {
                var values: [String: String] = [:]
                for field in variant.fields where field.required && field.defaultValue.isEmpty && field.source == nil {
                    values[field.id] = field.id == "email" ? "fixture@example.test" : field.id == "phone" ? "+79000000000" : "1"
                }
                let id = UUID()
                _ = try coordinator.start(owner: "fixture", tool: tool, context: context, actionID: action.id, variantID: variant.id, uid: "123", values: values, requestID: id, stillCurrent: { true })
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while coordinator.result(scope: scope, requestID: id)["phase"] == .string("pending"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                #expect(coordinator.result(scope: scope, requestID: id)["phase"] == .string("success"), "HTTP form: \(action.id)/\(variant.id)")
            }
        }
    }
}
