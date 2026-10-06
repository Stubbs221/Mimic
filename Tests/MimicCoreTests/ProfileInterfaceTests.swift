//
//  ProfileInterfaceTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation
import Testing
import ZIPFoundation
@testable import MimicCore

@Suite(.serialized) struct ProfileInterfaceTests {
    private var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Mimic11/profile.json") }
    private func manifest() throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any]) }
    private func profile(_ value: [String: Any]) throws -> MimicProfile { try JSONDecoder().decode(MimicProfile.self, from: JSONSerialization.data(withJSONObject: value)) }
    private func archive(_ data: [String: Any], root: URL) throws -> URL {
        let bytes = try JSONSerialization.data(withJSONObject: data), url = root.appendingPathComponent(UUID().uuidString + ".mimicprofile")
        let zip = try Archive(url: url, accessMode: .create)
        try zip.addEntry(with: "profile.json", type: .file, uncompressedSize: Int64(bytes.count), provider: { offset, size in bytes.subdata(in: Int(offset)..<Int(offset) + size) })
        return url
    }
    @Test func bindingsUseSemanticsDespiteOpaqueNamesAndReversedOrder() throws {
        let profile = try profile(manifest()); try ProfileValidation.validate(profile, files: ["profile.json"])
        let snapshot = ProfileSnapshot(profile: profile, revision: "fixture", directory: "/private/tmp/fixture")
        for platform in BootstrapPlatform.allCases {
            let options = BootstrapOptions.standard(platform: platform)
            let execution = try snapshot.execution(role: .bootstrap, values: options.profileValues)
            let record = execution.record(id: UUID(), project: ProjectContext(path: "/private/tmp/fixture"))
            #expect(record.action == .bootstrap); #expect(record.options == options); #expect(record.metadataOnly)
            #expect(record.profileExecution?.snapshot == snapshot)
        }
        for role in [ProfileToolRole.generateUI, .generateSicilia, .generateGalera] {
            let record = try snapshot.execution(role: role, values: [.name: "Header"]).record(id: UUID(), project: ProjectContext(path: "/private/tmp/fixture"))
            #expect(record.action == .generation); #expect(record.generation?.kind == role.generator); #expect(record.generation?.name == "Header")
            #expect(!record.metadataOnly)
        }
    }
    @Test func invalidBindingsAndLegacyImportCannotReplaceActiveRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(directory: root.appendingPathComponent("Profiles")), value = try manifest()
        let snapshot = try store.importArchive(archive(value, root: root), requireInterface: true)
        for mutation in 0..<4 {
            var invalid = value, interface = try #require(value["interface"] as? [String: Any]), bindings = try #require(interface["bindings"] as? [[String: Any]])
            switch mutation {
            case 0: bindings.removeLast()
            case 1: bindings[0]["actionID"] = "absent"
            case 2: bindings[0]["fields"] = ["platform": "input_bootstrap_full"]
            default: invalid["schemaVersion"] = 1; invalid.removeValue(forKey: "interface")
            }
            if mutation != 3 { interface["bindings"] = bindings; invalid["interface"] = interface }
            #expect(throws: (any Error).self) { try store.importArchive(archive(invalid, root: root), requireInterface: true) }
            #expect(try store.active() == snapshot)
        }
        var replacement = value; replacement["version"] = "1.1.1"
        let next = try store.importArchive(archive(replacement, root: root), requireInterface: true)
        #expect(next.revision != snapshot.revision); try store.verify(snapshot)
    }
    @Test func conditionalRequirementsFollowSelectedPhases() throws {
        var value = try manifest(), actions = try #require(value["actions"] as? [[String: Any]])
        let index = try #require(actions.firstIndex { $0["id"] as? String == "opaque-0" })
        actions[index]["toolRequirements"] = [["tool": "mimic-fixture-absent", "whenAny": [["input_bootstrap_full": "true"], ["input_bootstrap_dependencies": "true"]]]]
        value["actions"] = actions; let profile = try profile(value); try ProfileValidation.validate(profile, files: ["profile.json"])
        let snapshot = ProfileSnapshot(profile: profile, revision: "fixture", directory: "/private/tmp/fixture"), project = ProjectContext(path: "/private/tmp/fixture")
        #expect(try snapshot.execution(role: .bootstrap, values: BootstrapOptions.standard().profileValues).missingTools(project: project) == ["mimic-fixture-absent"])
        var partial = BootstrapOptions(); partial.full = false; partial.dependencies = false
        #expect(try snapshot.execution(role: .bootstrap, values: partial.profileValues).missingTools(project: project).isEmpty)
    }
    @Test func splitMarkersSkipAndExitStatusControlProgress() throws {
        let profile = try profile(manifest()), markers = try #require(profile.actions.first { $0.id == "opaque-0" }?.progress)
        var progress = BootstrapProgress(matchers: markers)
        progress.consume(Data("\u{1B}[32mfixture-be".utf8)); #expect(progress.fraction == 0)
        progress.consume(Data("gin\u{1B}[0m\nfixture-do".utf8)); #expect(progress.currentStep == .brew); #expect(progress.stage == .dependencies)
        progress.consume(Data("ne\nfixture-skip\n".utf8)); #expect(progress.completedSteps == [.brew]); #expect(progress.skippedSteps == [.mint]); #expect(progress.fraction < 1)
        progress.finish(succeeded: false); progress.consume(Data("fixture-done".utf8)); #expect(progress.fraction < 1)
        var success = BootstrapProgress(matchers: markers); success.finish(succeeded: true); #expect(success.fraction == 1)
    }
    @Test func reviewedCIFieldsMapToWireParametersWithoutUIAssumptions() throws {
        let profile = try profile(manifest()), snapshot = ProfileSnapshot(profile: profile, revision: "fixture", directory: "/private/tmp/fixture")
        let execution = try snapshot.execution(role: .beta, values: [.branch: "feature/long", .target: "App", .rebase: "main", .upload: "FALSE"]), action = try #require(execution.action)
        let fields = Dictionary(uniqueKeysWithValues: action.parameters.filter { $0.kind != .branch }.map { ($0.id, ProfileRemoteField(defaultValue: $0.defaultValue, choices: $0.choices ?? [], boolean: false)) })
        let contract = ProfileRemoteContract(fields: fields, gitBranch: true, branchValues: ["origin/feature/long"])
        let wire = try contract.wireParameters(execution.parameters, action: action, branch: "feature/long")
        #expect(wire["REF"] == "origin/feature/long"); #expect(wire["input_beta_target"] == "App"); #expect(wire["input_beta_upload"] == "FALSE"); #expect(wire["TARGET"] == nil)
    }
    @Test func legacyHistoryKeepsOriginalActionAndGeneratorKeysOnSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        var record = TaskRecord(action: .generation, project: ProjectContext(path: root.path), generation: GenerationRequest(kind: .module, name: "Header", digest: "fixture"))
        record.status = .succeeded; record.finishedAt = Date()
        var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        value["action"] = "celestial"; var generation = try #require(value["generation"] as? [String: Any]); generation["kind"] = "sicilia"; value["generation"] = generation
        let path = root.appendingPathComponent("history.json"); try JSONSerialization.data(withJSONObject: [value]).write(to: path)
        let store = HistoryStore(directory: root), restored = try store.load()
        #expect(restored.first?.action == .generation); #expect(restored.first?.generation?.kind == .module)
        try store.save(restored)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]])
        #expect(saved.first?["action"] as? String == "celestial"); #expect((saved.first?["generation"] as? [String: Any])?["kind"] as? String == "sicilia")
    }
}
