//
//  SimulatorQueueTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct SimulatorQueueTests {
    @Test func fifoIncludesSimulatorAndUnknownPreventsEveryOtherMutation() {
        let project = ProjectContext(path: "/private/tmp/fixture")
        let simulator = SimulatorActivity(id: UUID(), project: project, developer: "/fixture", deviceID: UUID(), sessionID: nil, kind: .start, createdAt: Date(timeIntervalSince1970: 1))
        let legacy = TaskRecord(action: .format, project: project)
        let build = BuildActivity(id: UUID(), project: project, parameters: .init(), source: "fixture")
        #expect(QueuePolicy.nextActivity(in: [legacy], builds: [build], simulators: [simulator]) == .simulator(simulator.id))
        var unknown = simulator; unknown.status = .unknown
        #expect(QueuePolicy.nextActivity(in: [legacy], builds: [build], simulators: [unknown]) == nil)
        unknown.queueReleased = true
        #expect(QueuePolicy.nextActivity(in: [legacy], builds: [build], simulators: [unknown]) == .legacy(legacy.id))
    }
    @Test func customNamedIOSDevicesRemainSelectable() throws {
        let data = Data(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"Mimic Apple Probe","state":"Booted","isAvailable":true}]}}"#.utf8)
        #expect(try SimulatorCatalog.parse(data).first?.name == "Mimic Apple Probe")
    }
    @Test func facadeRejectsArbitraryDSLAndInvalidPayloadFields() throws {
        #expect(throws: AppleSimulatorError.arguments) { try SimulatorBridge.action(.object(["type": .string("shell"), "command": .string("fixture")])) }
        #expect(throws: AppleSimulatorError.arguments) { try SimulatorBridge.action(.object(["type": .string("home"), "text": .string("fixture")])) }
        #expect(try SimulatorBridge.action(.object(["type": .string("text"), "text": .string("Привет 🧪")])) == .text("Привет 🧪"))
    }
}
