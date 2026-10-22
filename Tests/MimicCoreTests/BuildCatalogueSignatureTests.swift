// Created by Василий Маслов on 22.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct BuildCatalogueSignatureTests {
    @Test func configurationTracksIgnoredWorkspaceReferencesAndResolvedFilesButNotSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write(".gitignore", "*.xcworkspace\n*.xcodeproj\n")
        #expect(EnvironmentInspector.capture("/usr/bin/git", ["init", root.path]).0 == 0)
        try write("App.xcworkspace/contents.xcworkspacedata", #"<Workspace><Group location="group:Generated"><FileRef location="group:App.xcodeproj"/></Group></Workspace>"#)
        try write("Generated/App.xcodeproj/project.pbxproj", "configuration one")
        try write("Generated/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", "resolved one")
        try write("Xcode.app/Contents/Info.plist", "Xcode one")
        try write("Source.swift", "source one")
        let project = ProjectContext(path: root.path, developerDirectory: root.appendingPathComponent("Xcode.app/Contents/Developer").path, appleTarget: .init(path: "App.xcworkspace"))
        let original = try BuildCatalogueSignature.configurationDigest(project: project)
        try write("Source.swift", "source two")
        #expect(try BuildCatalogueSignature.configurationDigest(project: project) == original)
        try write("Generated/App.xcodeproj/project.pbxproj", "configuration two")
        let changed = try BuildCatalogueSignature.configurationDigest(project: project)
        #expect(changed != original)
        try write("Generated/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", "resolved two")
        #expect(try BuildCatalogueSignature.configurationDigest(project: project) != changed)
    }

    @Test func bootStateAndDeviceOrderingDoNotInvalidateDestinations() throws {
        func digest(_ devices: [[String: Any]]) throws -> String {
            try BuildCatalogueSignature.destinationDigest(json: JSONSerialization.data(withJSONObject: ["devices": ["iOS-27": devices]]))
        }
        let phone: [String: Any] = ["udid": "phone", "name": "iPhone", "isAvailable": true, "state": "Shutdown"]
        let pad: [String: Any] = ["udid": "pad", "name": "iPad", "isAvailable": true, "state": "Shutdown"]
        var booted = phone; booted["state"] = "Booted"
        #expect(try digest([phone, pad]) == digest([pad, booted]))
        #expect(try digest([phone, pad]) != digest([pad]))
        var renamed = phone; renamed["name"] = "Renamed"
        #expect(try digest([phone, pad]) != digest([renamed, pad]))
    }
}
