//
//  ProfileTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
import ZIPFoundation
@testable import MimicCore

@Suite(.serialized)
struct ProfileTests {
    private func manifest(steps: [[String: Any]]? = nil) throws -> Data {
        let parameter: [String: Any] = ["id": "name", "title": "Имя", "kind": "text", "defaultValue": "", "required": true]
        let action: [String: Any] = ["id": "fixture", "title": "Fixture", "presentation": "regular", "parameters": [parameter], "requiresXcodeQuit": false, "requiredFiles": [], "requiredTools": [], "steps": steps ?? [["executable": "/usr/bin/printf", "arguments": ["%s", "${name}"], "directory": "${checkout}"]]]
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": "fixture", "version": "1.0.0", "title": "Тестовый профиль", "requiredFiles": [], "actions": [action]])
    }
    private func archive(_ root: URL, manifest: Data, extra: [(String, Data)] = []) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".mimicprofile")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in [("profile.json", manifest)] + extra {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
        }
        return url
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func atomicImportPinsRevisionAndArgumentsWithoutShellExpansion() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(directory: root.appendingPathComponent("Profiles"))
        let first = try store.importArchive(archive(root, manifest: manifest()))
        let execution = ProfileExecution(snapshot: first, actionID: "fixture", parameters: ["name": "a; $(touch marker) ' Москва 👋"])
        let commands = try execution.commands(project: ProjectContext(path: root.path))
        #expect(commands[0].arguments == ["%s", "a; $(touch marker) ' Москва 👋"])
        #expect(execution.action?.allowsMCP == false)
        let second = try store.importArchive(archive(root, manifest: manifest(), extra: [("adapters/data.txt", Data("v2".utf8))]))
        #expect(second.revision != first.revision); #expect(try store.active() == second)
        try store.verify(first); #expect(execution.snapshot == first)
    }
    @Test func rejectedImportLeavesActiveProfileUnchanged() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(directory: root.appendingPathComponent("Profiles"))
        let first = try store.importArchive(archive(root, manifest: manifest()))
        for path in ["../escaped", "/absolute", "adapters/../../escape", "adapters\\escape"] {
            let invalid = try archive(root, manifest: manifest(), extra: [(path, Data())])
            #expect(throws: (any Error).self) { try store.importArchive(invalid) }
            #expect(try store.active() == first)
        }
        let invalidManifest = try manifest(steps: [["executable": "/bin/bash", "arguments": ["-c", "touch unexpected"], "directory": "${checkout}"]])
        #expect(throws: (any Error).self) { try store.importArchive(archive(root, manifest: invalidManifest)) }
        #expect(try store.active() == first)
    }
    @Test func encryptedArchivesAndUnknownSchemasAreRejectedAtomically() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(directory: root.appendingPathComponent("Profiles"))
        let first = try store.importArchive(archive(root, manifest: manifest()))
        let encrypted = try archive(root, manifest: manifest())
        var bytes = [UInt8](try Data(contentsOf: encrypted))
        for offset in 0..<(bytes.count - 46) where Array(bytes[offset..<offset + 4]) == [0x50, 0x4b, 0x01, 0x02] { bytes[offset + 8] |= 1 }
        try Data(bytes).write(to: encrypted)
        #expect(throws: (any Error).self) { try store.importArchive(encrypted) }
        var value = try #require(JSONSerialization.jsonObject(with: manifest()) as? [String: Any])
        value["schemaVersion"] = 99
        #expect(throws: (any Error).self) { try store.importArchive(archive(root, manifest: JSONSerialization.data(withJSONObject: value))) }
        #expect(try store.active() == first)
    }
    @Test func revisionTamperingAndUndeclaredParametersAreRejected() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(directory: root.appendingPathComponent("Profiles"))
        let snapshot = try store.importArchive(archive(root, manifest: manifest()))
        let execution = ProfileExecution(snapshot: snapshot, actionID: "fixture", parameters: ["name": "Valid", "command": "arbitrary"])
        #expect(throws: (any Error).self) { try execution.commands(project: ProjectContext(path: root.path)) }
        let file = URL(fileURLWithPath: snapshot.directory).appendingPathComponent("profile.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("{}".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.verify(snapshot) }
    }
    @Test func generatorRejectsTraversalDuplicatesExistingFilesAndSymlinks() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectContext(path: root.path)
        func plan(_ paths: [String]) throws -> GenerationPlan {
            try JSONDecoder().decode(GenerationPlan.self, from: JSONSerialization.data(withJSONObject: ["digest": String(repeating: "a", count: 64), "files": paths.map { ["path": $0, "exists": false] as [String: Any] }]))
        }
        for paths in [["../escape"], ["new.swift", "new.swift"]] { #expect(throws: (any Error).self) { try ProfileGeneratorValidation.validate(plan(paths), project: project) } }
        try Data().write(to: root.appendingPathComponent("exists.swift"))
        #expect(throws: (any Error).self) { try ProfileGeneratorValidation.validate(plan(["exists.swift"]), project: project) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.path)
        #expect(throws: (any Error).self) { try ProfileGeneratorValidation.validate(plan(["link/new.swift"]), project: project) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_PRIVATE_PROFILE"] != nil)) func privatePackageImportsWithoutExecutingAdapters() throws {
        let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIMIC_PRIVATE_PROFILE"]!)
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try ProfileStore(directory: root.appendingPathComponent("Profiles")).importArchive(path)
        #expect(snapshot.profile.actions.count == 12)
    }
    @Test func appleDestinationsIncludeOnlyIOSAndTVOSSimulators() {
        let destinations = BuildCatalogue.destinations(from: "{ platform:iOS Simulator, id:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA, OS:27.0, name:iPhone }\n{ platform:tvOS Simulator, id:BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB, OS:27.0, name:Apple TV }\n{ platform:watchOS Simulator, id:CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC, name:Watch }")
        #expect(destinations.count == 2); #expect(destinations.last?.platform == .tvos)
    }
}
