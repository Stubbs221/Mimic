//
//  ProfileIntegrationTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import AppKit
import SwiftUI
import Testing
import ZIPFoundation
import MimicCore
@testable import Mimic

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor struct ProfileIntegrationTests {
    @Test func catalogueOmitsCommandsAndRequiresAllowedActionAndPinnedProfileContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileBridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Disposable fixture"]] {
            #expect(EnvironmentInspector.capture("/usr/bin/git", arguments, directory: root.path).0 == 0)
        }
        let json = #"{"schemaVersion":1,"id":"fixture","version":"1","title":"Fixture","requiredFiles":[],"actions":[{"id":"allowed","title":"Разрешённое действие с длинным названием 👋","presentation":"regular","mcpAllowed":true,"requiresXcodeQuit":false,"requiredFiles":[],"requiredTools":[],"parameters":[],"steps":[{"executable":"/usr/bin/true","arguments":[],"directory":"${checkout}"}]},{"id":"private","title":"Private","presentation":"regular","requiresXcodeQuit":false,"requiredFiles":[],"requiredTools":[],"parameters":[],"steps":[{"executable":"/usr/bin/true","arguments":[],"directory":"${checkout}"}]}]}"#
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        manifest["services"] = ["jenkinsURL": "https://ci.example.invalid"]
        var definitions = try #require(manifest["actions"] as? [[String: Any]])
        definitions.append(["id": "remote", "title": "Remote", "presentation": "ci", "mcpAllowed": true, "requiresXcodeQuit": false, "requiredFiles": [], "requiredTools": [], "parameters": [], "steps": [], "remote": ["job": "fixture", "branchParameter": "REF", "tracking": "jenkinsOnly"]])
        manifest["actions"] = definitions
        let url = root.appendingPathComponent("fixture.mimicprofile"), data = try JSONSerialization.data(withJSONObject: manifest)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "profile.json", type: .file, uncompressedSize: Int64(data.count), provider: { offset, size in data.subdata(in: Int(offset)..<Int(offset) + size) })
        let directory = root.appendingPathComponent("Storage"), store = ProfileStore(directory: directory.appendingPathComponent("Profiles"))
        let snapshot = try store.importArchive(url)
        let suite = "ProfileBridge-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TaskCoordinator(directory: directory, defaults: defaults)
        let project = try EnvironmentInspector.project(path: root.path)
        model.projects = [project]; model.selectedProjectPath = project.path
        var barrier = TaskRecord(action: .format, project: project); barrier.status = .running
        model.records = [barrier]
        let integration = MimicIntegration(model: model, defaults: defaults)
        let state = try await integration.handle(MimicBridgeRequest(method: "get_state"))
        #expect(state["version"].integer == 3)
        #expect(state["actions"].array?.count == 2)
        #expect(state["actions"].array?.first?["id"].string == "allowed")
        #expect(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("executable"))
        let context = state["context"], id = UUID()
        let uiJSON = #"{"schemaVersion":1,"id":"ui","version":"1","title":"Разработка приложения Apple — расширенная конфигурация команды 👋","requiredFiles":[],"actions":[{"id":"ui","title":"Подготовка рабочего окружения для интеграционного тестирования приложения Apple","presentation":"preparation","requiresXcodeQuit":false,"requiredFiles":[],"requiredTools":[],"steps":[{"executable":"/usr/bin/true","arguments":[],"directory":"${checkout}"}],"parameters":[{"id":"name","title":"Название компонента профиля","kind":"text","defaultValue":"SubscriptionManagementProfileHeaderМосква東京🙂","required":true},{"id":"dependencies","title":"Обновить зависимости пользовательского интерфейса и проверить доступность инструментов разработки","kind":"boolean","defaultValue":"true","required":true},{"id":"platform","title":"Платформа","kind":"platform","defaultValue":"tvos","required":true}]}]}"#
        let uiProfile = try JSONDecoder().decode(MimicProfile.self, from: Data(uiJSON.utf8))
        #expect(uiProfile.interface == nil)
        for width: CGFloat in [320, 440] {
            let view = NSHostingView(rootView: ProfileSetupView(model: model).padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 300); view.layoutSubtreeIfNeeded()
            #expect(view.bounds.width == width)
            if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/acceptance/profile-\(Int(width)).png")
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try image.representation(using: .png, properties: [:])?.write(to: output)
            }
        }
        let parameters: [String: BridgeValue] = ["actionID": .string("allowed"), "parameters": .object([:]), "context": context, "requestID": .string(id.uuidString)]
        let request = MimicBridgeRequest(method: "run_local_action", parameters: parameters)
        let first = try await integration.handle(request)
        #expect(first["id"].string == id.uuidString)
        #expect(model.records.first { $0.id == id }?.profileExecution?.snapshot == snapshot)
        var denied = parameters; denied["actionID"] = .string("private"); denied["requestID"] = .string(UUID().uuidString)
        await #expect(throws: (any Error).self) { try await integration.handle(MimicBridgeRequest(method: "run_local_action", parameters: denied)) }
        let originalLedger = defaults.data(forKey: "mcpLocalRequests")
        var arbitrary = parameters; arbitrary["parameters"] = .object(["command": .string("synthetic-ledger-private")]); arbitrary["requestID"] = .string(UUID().uuidString)
        await #expect(throws: (any Error).self) { try await integration.handle(MimicBridgeRequest(method: "run_local_action", parameters: arbitrary)) }
        #expect(defaults.data(forKey: "mcpLocalRequests") == originalLedger)
        arbitrary["actionID"] = .string("remote"); arbitrary["requestID"] = .string(UUID().uuidString)
        await #expect(throws: (any Error).self) { try await integration.handle(MimicBridgeRequest(method: "run_remote_action", parameters: arbitrary)) }
        #expect(defaults.data(forKey: "mcpLocalRequests") == originalLedger)
        #expect(first["context"]["profileRevision"].string == snapshot.revision)
        // Reimport different bytes; the accepted request remains bound to the first revision.
        let anotherURL = root.appendingPathComponent("another.mimicprofile"), another = try Archive(url: anotherURL, accessMode: .create)
        for (path, bytes) in [("profile.json", data), ("adapters/version.txt", Data("2".utf8))] {
            try another.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), provider: { offset, size in bytes.subdata(in: Int(offset)..<Int(offset) + size) })
        }
        model.activeProfile = try store.importArchive(anotherURL)
        let duplicate = try await integration.handle(request)
        #expect(duplicate["id"] == first["id"])
        var stale = parameters; stale["requestID"] = .string(UUID().uuidString)
        await #expect(throws: (any Error).self) { try await integration.handle(MimicBridgeRequest(method: "run_local_action", parameters: stale)) }
        #expect(model.records.filter { $0.profileExecution != nil }.count == 1)
        model.stopAndExit()
    }
}
