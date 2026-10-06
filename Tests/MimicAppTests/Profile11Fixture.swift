//
//  Profile11Fixture.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation
import MimicCore
import ZIPFoundation

/// Disposable profile data, with optional wire names used by the existing HTTP fixtures.
enum Profile11Fixture {
    static func data(legacyCI: Bool = false) throws -> Data {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Mimic11/profile.json")
        let data = try Data(contentsOf: path)
        guard legacyCI else { return data }
        var value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var actions = value["actions"] as! [[String: Any]], interface = value["interface"] as! [String: Any], bindings = interface["bindings"] as! [[String: Any]]
        let names: [String: [String: String]] = ["uiTests": ["branch": "branch", "plan": "TEST_PLAN"], "beta": ["branch": "branch", "target": "TARGET", "rebase": "REBASE_BRANCH", "upload": "UPLOAD_TO_APP_DISTRIBUTION"], "qualityGates": Dictionary(uniqueKeysWithValues: [("branch", "branch")] + QualityGate.allCases.map { ($0.profileField.rawValue, $0.rawValue) })]
        for i in bindings.indices {
            guard let role = bindings[i]["role"] as? String, let fields = names[role] else { continue }
            let old = bindings[i]["fields"] as! [String: String], index = actions.firstIndex { $0["id"] as? String == bindings[i]["actionID"] as? String }!
            var parameters = actions[index]["parameters"] as! [[String: Any]]
            for j in parameters.indices {
                let field = old.first { $0.value == parameters[j]["id"] as? String }!.key
                parameters[j]["id"] = fields[field]
                if field == "target" { parameters[j]["choices"] = ["movie"]; parameters[j]["defaultValue"] = "movie" }
                if field == "rebase" { parameters[j]["defaultValue"] = ""; parameters[j]["required"] = false }
            }
            actions[index]["parameters"] = parameters
            actions[index]["remote"] = ["job": role == "uiTests" ? "ios_ui_tests_simulator" : role == "beta" ? "ios_beta" : "ios_launch_qualitygates", "branchParameter": role == "uiTests" ? "BRANCH" : "SELECTED_BRANCH", "tracking": "jenkinsOnly"]
            bindings[i]["fields"] = fields
        }
        value["actions"] = actions; interface["bindings"] = bindings; value["interface"] = interface
        return try JSONSerialization.data(withJSONObject: value)
    }
    static func snapshot(directory: URL, legacyCI: Bool = false) throws -> ProfileSnapshot {
        ProfileSnapshot(profile: try JSONDecoder().decode(MimicProfile.self, from: data(legacyCI: legacyCI)), revision: "fixture", directory: directory.path)
    }
    static func install(directory: URL, data: Data? = nil) throws -> ProfileSnapshot {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try data ?? self.data(), path = directory.appendingPathComponent(UUID().uuidString + ".mimicprofile")
        let archive = try Archive(url: path, accessMode: .create)
        try archive.addEntry(with: "profile.json", type: .file, uncompressedSize: Int64(bytes.count), provider: { offset, size in bytes.subdata(in: Int(offset)..<Int(offset) + size) })
        return try ProfileStore(directory: directory.appendingPathComponent("Profiles")).importArchive(path, requireInterface: true)
    }
}
