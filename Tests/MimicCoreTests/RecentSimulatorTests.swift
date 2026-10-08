//
//  RecentSimulatorTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct RecentSimulatorTests {
    private func device(_ name: String, version: String, booted: Bool = false) -> SimulatorDevice {
        SimulatorDevice(id: UUID(), name: name, runtime: version, state: booted ? "Booted" : "Shutdown")
    }

    @Test
    func forgetSurvivesEncodingWithoutChangingOtherXcodeHistory() throws {
        let device = self.device("iPad", version: "iOS 27")
        var usage = SimulatorUsage(); usage.record(device.id, developer: "A"); usage.record(device.id, developer: "B")
        usage.forget(device.id, developer: "A")
        let restored = try JSONDecoder().decode(SimulatorUsage.self, from: JSONEncoder().encode(usage))
        #expect(restored.dates["A"]?[device.id] == nil && restored.dates["B"]?[device.id] != nil)
    }

    @Test
    func firstUseSortsNumericRuntimeAndName() {
        let old = self.device("iPhone Old", version: "iOS 9.3"), newer = self.device("iPhone B", version: "iOS 26.1"), newest = self.device("iPhone A", version: "iOS 26.1")
        #expect(SimulatorUsage().recent([old, newer, newest], developer: "/Xcode").map(\.id) == [newest.id, newer.id, old.id])
    }

    @Test
    func bootedThenRecentThenFallbackWithoutDuplicates() {
        let booted = self.device("iPad", version: "iOS 18", booted: true), recent = self.device("iPhone", version: "iOS 18"), fallback = self.device("iPhone New", version: "iOS 26")
        var usage = SimulatorUsage(); usage.record(recent.id, developer: "/Xcode")
        #expect(usage.recent([recent, fallback, booted, recent], developer: "/Xcode").map(\.id) == [booted.id, recent.id, fallback.id])
    }

    @Test
    func deletedDevicesExcludedAndXcodeHistoryIndependent() throws {
        let first = self.device("iPhone A", version: "iOS 18"), second = self.device("iPhone B", version: "iOS 18")
        var usage = SimulatorUsage()
        usage.record(second.id, developer: "/Xcode-A", at: Date(timeIntervalSince1970: 10))
        usage.record(UUID(), developer: "/Xcode-A", at: Date(timeIntervalSince1970: 20))
        #expect(usage.recent([first, second], developer: "/Xcode-A").map(\.id) == [second.id, first.id])
        #expect(usage.recent([first, second], developer: "/Xcode-B").map(\.id) == [first.id, second.id])
        let decoded = try JSONDecoder().decode(SimulatorUsage.self, from: JSONEncoder().encode(usage))
        #expect(decoded.recent([first, second], developer: "/Xcode-A").first?.id == second.id)
    }

    @Test
    func listIsLimitedToFiveAndLatestSuccessWins() {
        let devices = (0 ..< 10).map { self.device("iPhone \($0)", version: "iOS 26") }
        var usage = SimulatorUsage()
        for (index, device) in devices.enumerated() {
            usage.record(device.id, developer: "/Xcode", at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(usage.recent(devices, developer: "/Xcode").map(\.id) == Array(devices.reversed().prefix(5)).map(\.id))
        usage.record(devices[0].id, developer: "/Xcode", at: Date(timeIntervalSince1970: 100))
        #expect(usage.recent(devices, developer: "/Xcode").first?.id == devices[0].id)
    }
}
