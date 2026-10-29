//
//  XcodeProjectConfigurationsTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct XcodeProjectConfigurationsTests {
    private let project = """
    // !$*UTF8*$!
    {
        objects = {
            ROOT = { isa = PBXProject; buildConfigurationList = CONFIGS; };
            CONFIGS = { isa = XCConfigurationList; buildConfigurations = (RELEASE, DEBUG); };
            RELEASE = { isa = XCBuildConfiguration; name = "Релиз для команды"; };
            DEBUG = { isa = XCBuildConfiguration; name = Debug; };
            TARGET = { isa = XCBuildConfiguration; name = "Target only"; };
        };
        rootObject = ROOT;
    }
    """

    @Test func readsOpenStepProjectConfigurationsWithoutTargetOnlyNames() throws {
        #expect(try XcodeProjectConfigurations.names(in: Data(project.utf8)) == ["Debug", "Релиз для команды"])
    }

    @Test func rejectsMalformedMissingAndDuplicateConfigurations() {
        for text in ["invalid", project.replacingOccurrences(of: "rootObject = ROOT", with: "rootObject = MISSING"),
                     project.replacingOccurrences(of: "(RELEASE, DEBUG)", with: "(MISSING)"),
                     project.replacingOccurrences(of: "(RELEASE, DEBUG)", with: "(DEBUG, DEBUG)"),
                     project.replacingOccurrences(of: "(RELEASE, DEBUG)", with: "()"),
                     project.replacingOccurrences(of: "name = Debug", with: "name = \"\"")] {
            #expect(throws: BuildError.catalogueResponse) { try XcodeProjectConfigurations.names(in: Data(text.utf8)) }
        }
    }

    @Test func workspaceCatalogueReadsConfigurationsWithoutASecondXcodeProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-configurations-" + UUID().uuidString)
        let bundle = directory.appendingPathComponent("Fixture.xcodeproj")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(project.utf8).write(to: bundle.appendingPathComponent("project.pbxproj"))
        let context = ProjectContext(path: directory.path, developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcworkspace", configurationProject: "Fixture.xcodeproj"))
        var queries = 0
        let value = try BuildCatalogue.inspect(project: context, scheme: "", includeTestPlans: false, timeout: 5) { args, _, _ in
            queries += 1
            #expect(args.contains("-workspace") && !args.contains("-project"))
            return (0, #"{"workspace":{"schemes":["Fixture"]}}"#)
        }
        #expect(queries == 1 && value.schemes == ["Fixture"] && value.configurations == ["Debug", "Релиз для команды"])
    }
}
