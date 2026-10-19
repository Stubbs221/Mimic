//
//  PhysicalDeviceCatalogTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 12.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct PhysicalDeviceCatalogTests {
    private let id = UUID(uuidString: "2B5D106C-0DAF-5250-A9AE-044087D2BA3B")!

    @Test func currentAndLegacyPropertiesProduceSamePhysicalTarget() throws {
        let current = """
        {"result":{"devices":[{"identifier":"\(id)","properties":{
          "hardware":{"reality":"physical","deviceType":"iPad","platform":"iOS","udid":"00008103-TEST","marketingName":"iPad Pro"},
          "state":{"name":"iPad лаборатории 🧪"},"software":{"osVersionNumber":{"stringValue":"18.7.8"}},
          "connection":{"state":"connected","transportType":"wired","screenViewingURL":{"relative":"devices://device/open?id=\(id)"}}
        }}]}}
        """
        let legacy = """
        {"result":{"devices":[{"identifier":"\(id)",
          "hardwareProperties":{"reality":"physical","deviceType":"iPad","platform":"iOS","udid":"00008103-TEST"},
          "deviceProperties":{"name":"iPad лаборатории 🧪","osVersionNumber":"18.7.8","screenViewingURL":"devices://device/open?id=\(id)"},
          "connectionProperties":{"tunnelState":"connected","transportType":"wired"}
        }]}}
        """
        let targets = try PhysicalDeviceCatalog.parse(Data(current.utf8))
        #expect(targets == (try PhysicalDeviceCatalog.parse(Data(legacy.utf8))))
        let target = try #require(targets.first)
        #expect(target.id == id && target.physical?.udid == "00008103-TEST")
        #expect(target.runtime == "iPadOS 18.7.8" && target.isActive && !target.isBooted)
        #expect(target.physical?.screenViewingURL != nil)
        #expect(try JSONDecoder().decode(SimulatorDevice.self, from: JSONEncoder().encode(target)) == target)
    }

    @Test func simulatedEntriesAreExcludedAndDisconnectedDevicesRetained() throws {
        let json = """
        {"result":{"devices":[
          {"identifier":"\(id)","properties":{"hardware":{"reality":"physical","deviceType":"iPhone","udid":"TEST"},"state":{"name":"iPhone"},"connection":{"state":"disconnected"}}},
          {"identifier":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","properties":{"hardware":{"reality":"simulated","deviceType":"iPhone","udid":"SIMULATOR"}}}
        ]}}
        """
        let targets = try PhysicalDeviceCatalog.parse(Data(json.utf8))
        #expect(targets.count == 1)
        #expect(targets[0].state == "disconnected" && !targets[0].isActive && targets[0].physical?.screenViewingURL == nil)
        #expect(try PhysicalDeviceCatalog.parse(Data("{\"result\":{\"devices\":[]}}".utf8)).isEmpty)
    }

    @Test func viewingURLRejectsOtherDevicesAndArbitraryHandlers() {
        let valid = "devices://device/open?id=\(id)"
        #expect(PhysicalDeviceCatalog.viewingURL(valid, deviceID: id) != nil)
        for invalid in ["https://device/open?id=\(id)", "devices://device/open?id=\(UUID())", valid + "&id=\(id)", valid + "#fragment", "devices://device/delete?id=\(id)"] {
            #expect(PhysicalDeviceCatalog.viewingURL(invalid, deviceID: id) == nil)
        }
    }

    @Test func simulatorHistoryStillDecodesAndSimctlRejectsPhysicalTargets() throws {
        let previous = """
        {"id":"\(id)","name":"iPad","runtime":"iOS 27","state":"Booted"}
        """
        let restored = try JSONDecoder().decode(SimulatorDevice.self, from: Data(previous.utf8))
        #expect(restored.physical == nil && restored.isBooted)
        let physical = SimulatorDevice(id: id, name: "iPad", runtime: "iPadOS 18", state: "Booted", physical: .init(udid: "TEST"))
        #expect(!physical.isBooted)
        for action in [MimicAction.simulatorBoot, .simulatorShutdown] {
            #expect(throws: MimicError.invalidSimulator) {
                try CommandSpec.make(action: action, project: .init(path: "/fixture", branch: "main", commit: "fixture"), options: BootstrapOptions(), environment: [:], simulator: physical)
            }
        }
    }
}
