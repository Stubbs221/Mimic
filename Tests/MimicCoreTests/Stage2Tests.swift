//
//  Stage2Tests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 01.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct Stage2Tests {
    @Test
    func catalogKeepsOnlyAvailableAppleDevicesAndOrdersBootedFirst() throws {
        let data = Data(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-6":[{"udid":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"iPhone 16","state":"Shutdown","isAvailable":true},{"udid":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","name":"iPad Pro","state":"Booted","isAvailable":true},{"udid":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","name":"iPhone Old","state":"Shutdown","isAvailable":false}],"com.apple.CoreSimulator.SimRuntime.tvOS-18-6":[{"udid":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD","name":"Apple TV","state":"Booted","isAvailable":true}]}}"#.utf8)
        let devices = try SimulatorCatalog.parse(data)
        #expect(devices.map(\.name) == ["iPad Pro", "Apple TV", "iPhone 16"])
        #expect(devices.first?.runtime == "iOS 18.6")
        #expect(throws: (any Error).self) { try SimulatorCatalog.parse(Data(#"{"devices":{"x":[{"udid":"$(touch NEVER)","name":"iPhone","state":"Booted","isAvailable":true}]}}"#.utf8)) }
    }

    @Test
    func simulatorCommandsTargetExactlyOneUUID() throws {
        let project = ProjectContext(path: "/tmp/Project with spaces")
        let device = SimulatorDevice(id: UUID(), name: "iPhone", runtime: "iOS 18", state: "Shutdown")
        let boot = try CommandSpec.make(action: .simulatorBoot, project: project, options: BootstrapOptions(), environment: [:], simulator: device)
        let shutdown = try CommandSpec.make(action: .simulatorShutdown, project: project, options: BootstrapOptions(), environment: [:], simulator: device)
        #expect(boot.executable == "/usr/bin/xcrun")
        #expect(boot.arguments == ["simctl", "boot", device.id.uuidString])
        #expect(shutdown.arguments == ["simctl", "shutdown", device.id.uuidString])
        #expect(throws: MimicError.invalidSimulator) { try CommandSpec.make(action: .simulatorBoot, project: project, options: BootstrapOptions(), environment: [:]) }
    }

    @Test(arguments: [("ProfileHeader", true), ("A", true), ("profile", false), ("Foo123", false), ("../Foo", false), ("Foo$(touch NEVER)", false)])
    func generatorNameValidation(input: String, valid: Bool) { #expect(GenerationRequest.validName(input) == valid) }

    @Test
    func oldHistoryDecodesWithoutNewParameters() throws {
        let original = TaskRecord(action: .format, project: ProjectContext(path: "/tmp/project"))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "generation"); json.removeValue(forKey: "simulator")
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.id == original.id)
        #expect(decoded.generation == nil)
        #expect(decoded.simulator == nil)
    }

    @Test
    func summarySeparatesProjectsAndDoesNotCountRunningAsSuccess() {
        let project = ProjectContext(path: "/tmp/one")
        var success = TaskRecord(action: .format, project: project); success.status = .succeeded; success.finishedAt = Date()
        var error = TaskRecord(action: .proto, project: project); error.status = .failed; error.finishedAt = Date()
        let running = TaskRecord(action: .bootstrap, project: project)
        var other = TaskRecord(action: .format, project: ProjectContext(path: "/tmp/two")); other.status = .succeeded
        let summary = ActivitySummary(records: [success, error, running, other], path: project.path)
        #expect(summary.succeeded == 1); #expect(summary.failed == 1); #expect(summary.last?.id == error.id)
    }

    @Test
    func gitRenameAndUntrackedCountsPreserveFilenameBoundaries() {
        let result = GitSummary(porcelain: " M Some File.swift\0R  New.swift\0Old.swift\0?? Untracked.swift\0")
        #expect(result.changed == 2); #expect(result.untracked == 1)
        #expect(GitSummary(porcelain: "").changed == 0)
    }

}
