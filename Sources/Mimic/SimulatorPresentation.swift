//
//  SimulatorPresentation.swift
//  Mimic
//
//  Created by Василий Маслов on 07.10.2026.
import AppKit
import MimicCore
import Observation

/// Catalogue polling invalidates simulator readers, without publishing through the task owner.
@MainActor @Observable final class SimulatorPanelState {
    private(set) var presentation = SimulatorPresentation(devices: [], usage: SimulatorUsage(), developer: "")
    var loading = false
    var error = ""
    var physicalError = ""
    var search = "" { didSet { if oldValue != search { pageIndex = 0 } } }
    var filter = SimulatorFilter.all { didSet { if oldValue != filter { pageIndex = 0 } } }
    var pageIndex = 0
    /// Existing cards do not depend on background request activity.
    var initialLoading: Bool { presentation.devices.isEmpty && loading }

    func apply(devices: [SimulatorDevice], usage: SimulatorUsage, developer: String) {
        guard presentation.devices != devices || presentation.usage.dates != usage.dates || presentation.developer != developer else { return }
        let interval = FramePerformanceTrace.begin("Simulator presentation")
        defer { FramePerformanceTrace.end("Simulator presentation", interval) }
        presentation = SimulatorPresentation(devices: devices, usage: usage, developer: developer)
        pageIndex = SimulatorCatalogPage(devices: presentation.catalog(filter: filter, search: search), index: pageIndex).index
    }
}

enum SimulatorFilter: String, CaseIterable {
    case all, booted, recent
    var title: String { text("simulators.filter." + self.rawValue) }
}

/// Both surfaces use the same catalogue-wide identities, even when a search hides a duplicate.
struct SimulatorPresentation {
    let devices: [SimulatorDevice]
    let usage: SimulatorUsage
    let developer: String
    let ordered: [SimulatorDevice]
    private let shortIDs: [UUID: String]

    init(devices: [SimulatorDevice], usage: SimulatorUsage, developer: String) {
        self.devices = devices; self.usage = usage; self.developer = developer
        let recent = usage.recent(devices, developer: developer, limit: devices.count)
        let connected = recent.filter { $0.physical != nil && $0.isActive }
        self.ordered = connected + recent.filter { $0.physical == nil || !$0.isActive }
        struct Identity: Hashable { let name: String; let runtime: String }
        let groups = Dictionary(grouping: self.ordered) { Identity(name: $0.name, runtime: $0.runtime) }
        var identifiers: [UUID: String] = [:]
        for matches in groups.values where matches.count > 1 {
            let strings = matches.map { $0.id.uuidString }
            for device in matches {
                let identifier = device.id.uuidString
                let length = (4...identifier.count).first { length in
                    strings.filter { $0.hasPrefix(identifier.prefix(length)) }.count == 1
                } ?? identifier.count
                identifiers[device.id] = String(identifier.prefix(length))
            }
        }
        self.shortIDs = identifiers
    }
    func isRecent(_ device: SimulatorDevice) -> Bool { self.usage.dates[self.developer]?[device.id] != nil }
    func compact(full: Bool) -> [SimulatorDevice] {
        let connected = self.ordered.contains { $0.physical != nil && $0.isActive }
        return Array(self.ordered.filter { $0.isActive || self.isRecent($0) }.prefix(connected ? (full ? 2 : 1) : (full ? 4 : 2)))
    }
    func catalog(filter: SimulatorFilter, search: String) -> [SimulatorDevice] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.ordered.filter { device in
            (filter == .all || (filter == .booted ? device.isActive : self.isRecent(device))) &&
            (query.isEmpty || (device.name + " " + device.runtime + " " + device.state + " " + device.id.uuidString + " " + (device.physical?.udid ?? "") + " " + Self.status(device)).localizedCaseInsensitiveContains(query))
        }
    }
    static func status(_ device: SimulatorDevice, compact: Bool = false) -> String {
        guard let physical = device.physical else { return text(device.isBooted ? "simulators.booted" : "simulators.off") }
        if device.isActive {
            if physical.transport == "wired" { return text(compact ? "devices.usb" : "devices.connected.usb") }
            if physical.transport == "localNetwork" || physical.transport == "network" { return text(compact ? "devices.network" : "devices.connected.network") }
            return text("devices.connected")
        }
        return text(device.state == "connecting" ? "devices.connecting" : "devices.disconnected")
    }
    func shortID(_ device: SimulatorDevice) -> String? {
        self.shortIDs[device.id]
    }
    static func symbol(_ device: SimulatorDevice) -> String {
        if device.runtime.hasPrefix("tvOS") { return "appletv" }
        return device.runtime.hasPrefix("iPadOS") || device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
    }
}

/// Pages are sliced after filtering and ordering; refreshes keep the nearest valid page.
struct SimulatorCatalogPage {
    static let size = 8
    let index: Int
    let count: Int
    let devices: [SimulatorDevice]

    init(devices: [SimulatorDevice], index: Int) {
        self.count = max(1, (devices.count + Self.size - 1) / Self.size)
        self.index = min(max(0, index), self.count - 1)
        self.devices = Array(devices.dropFirst(self.index * Self.size).prefix(Self.size))
    }
}

struct SimulatorCatalogSnapshot: Sendable {
    let devices: [SimulatorDevice]
    let developer: String
    var physicalError: String = ""
}

/// Injectable system boundaries keep catalogue, admission and window tests off live simulators.
struct SimulatorPanelServices {
    var catalog: @Sendable (ProjectContext) async throws -> SimulatorCatalogSnapshot = { project in
        try await Task.detached {
            let developer = project.developerDirectory ?? EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
            guard !developer.isEmpty else { throw MimicError.invalidSimulator }
            var environment = EnvironmentInspector.environment(project: project); environment["DEVELOPER_DIR"] = developer
            let result = EnvironmentInspector.capture("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], environment: environment)
            guard result.0 == 0 else { throw MimicError.invalidSimulator }
            let simulators = try SimulatorCatalog.parse(Data(result.1.utf8))
            do {
                let physical = try PhysicalDeviceCatalog.discover(developer: developer, environment: environment)
                return SimulatorCatalogSnapshot(devices: simulators + physical, developer: developer)
            } catch {
                return SimulatorCatalogSnapshot(devices: simulators, developer: developer, physicalError: text("devices.discovery.error"))
            }
        }.value
    }
    var inspect: @Sendable (ProjectContext) async throws -> ProjectContext = { project in
        try await Task.detached { try EnvironmentInspector.project(path: project.path, developerDirectory: project.developerDirectory, appleTarget: project.appleTarget) }.value
    }
    var open: @MainActor (SimulatorDevice, String) async throws -> Void = { device, developer in
        let url = try SimulatorWindowTarget.application(developer: developer, physical: device.physical != nil)
        let configuration = NSWorkspace.OpenConfiguration()
        if device.physical == nil { configuration.arguments = ["-CurrentDeviceUDID", device.id.uuidString] }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            if url.lastPathComponent == "DeviceHub.app" {
                let target: URL
                if let physical = device.physical {
                    guard device.isActive, let validated = PhysicalDeviceCatalog.viewingURL(physical.screenViewingURL?.absoluteString, deviceID: device.id) else {
                        continuation.resume(throwing: MimicError.invalidSimulator); return
                    }
                    target = validated
                } else { target = SimulatorWindowTarget.deviceURL(device.id) }
                NSWorkspace.shared.open([target], withApplicationAt: url, configuration: configuration, completionHandler: completion)
            } else {
                NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
            }
        }
    }
}

/// Xcode 27 moved simulator windows into DeviceHub. Resolve only inside the selected Xcode.
enum SimulatorWindowTarget {
    static func application(developer: String, physical: Bool = false, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> URL {
        let root = URL(fileURLWithPath: developer)
        let hub = root.deletingLastPathComponent().appendingPathComponent("Applications/DeviceHub.app")
        let candidates = physical ? [hub] : [root.appendingPathComponent("Applications/Simulator.app"), hub]
        guard let target = candidates.first(where: { exists($0.path) }) else { throw MimicError.invalidSimulator }
        return target
    }

    /// Deliver a device request to an already running DeviceHub as well as its first launch.
    static func deviceURL(_ id: UUID) -> URL {
        var url = URLComponents(); url.scheme = "devices"; url.host = "device"; url.path = "/open"
        url.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return url.url!
    }
}

/// A presentation reservation starts before async admission; its generation also guards late opens.
struct SimulatorPanelOperation {
    let id: UUID
    let device: SimulatorDevice
    let action: MimicAction
    let project: ProjectContext
    let developer: String
    let revision: UUID
}

struct SimulatorPanelFailure {
    let message: String
    let taskID: UUID?
}
