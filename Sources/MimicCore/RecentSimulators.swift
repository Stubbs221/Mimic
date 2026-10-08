//
//  RecentSimulators.swift
//  MimicCore
//
//  Created by Василий Маслов on 02.10.2026.
import Foundation

/// Successful Mimic usage only, keyed by the concrete Xcode developer directory.
public struct SimulatorUsage: Codable, Sendable {
    public private(set) var dates: [String: [UUID: Date]] = [:]
    public init() { }
    /// Removes successful-use history only for this Xcode; running devices remain discoverable.
    public mutating func forget(_ id: UUID, developer: String) {
        self.dates[developer]?[id] = nil
    }
    public mutating func record(_ id: UUID, developer: String, at date: Date = Date()) {
        self.dates[developer, default: [:]][id] = date
        let newest = self.dates[developer, default: [:]].sorted { $0.value > $1.value }.prefix(100)
        self.dates[developer] = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    public func recent(_ devices: [SimulatorDevice], developer: String, limit: Int = 5) -> [SimulatorDevice] {
        var seen = Set<UUID>()
        let unique = devices.filter { seen.insert($0.id).inserted }
        let usage = self.dates[developer] ?? [:]
        return Array(unique.sorted { first, second in
            if first.isBooted != second.isBooted { return first.isBooted }
            let firstDate = usage[first.id], secondDate = usage[second.id]
            if firstDate != secondDate { return (firstDate ?? .distantPast) > (secondDate ?? .distantPast) }
            let version = first.runtime.compare(second.runtime, options: .numeric)
            if version != .orderedSame { return version == .orderedDescending }
            let name = first.name.localizedStandardCompare(second.name)
            return name == .orderedSame ? first.id.uuidString < second.id.uuidString : name == .orderedAscending
        }.prefix(max(0, limit)))
    }
}

/// Storage is replaceable so tests never alter a user's recent devices.
@MainActor
public protocol SimulatorUsageStore {
    func load() -> SimulatorUsage
    func save(_ usage: SimulatorUsage)
}

@MainActor
public struct DefaultsSimulatorUsageStore: SimulatorUsageStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> SimulatorUsage {
        guard let data = defaults.data(forKey: "simulatorUsage") else { return SimulatorUsage() }
        return (try? JSONDecoder().decode(SimulatorUsage.self, from: data)) ?? SimulatorUsage()
    }

    public func save(_ usage: SimulatorUsage) {
        if let data = try? JSONEncoder().encode(usage) { self.defaults.set(data, forKey: "simulatorUsage") }
    }
}
