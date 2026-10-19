//
//  PhysicalDeviceCatalog.swift
//  MimicCore
//
//  Created by Василий Маслов on 12.10.2026.
import Foundation

/// Minimal device metadata; serial numbers, network addresses and raw CoreDevice output are discarded.
public struct PhysicalDeviceInfo: Codable, Equatable, Sendable {
    public let udid: String
    public let transport: String?
    public let screenViewingURL: URL?
    public init(udid: String, transport: String? = nil, screenViewingURL: URL? = nil) {
        self.udid = udid; self.transport = transport; self.screenViewingURL = screenViewingURL
    }
}

/// Read-only discovery independent of simctl. Supports legacy and Xcode 27 JSON property shapes.
public enum PhysicalDeviceCatalog {
    // MARK: - Decoding

    private struct Envelope: Decodable { let result: Result }
    private struct Result: Decodable { let devices: [Device] }
    private struct Device: Decodable {
        let identifier: UUID
        let properties: Properties?
        let hardwareProperties: Hardware?
        let deviceProperties: LegacySoftware?
        let connectionProperties: Connection?
    }
    private struct Properties: Decodable {
        let hardware: Hardware?
        let state: State?
        let software: Software?
        let connection: Connection?
    }
    private struct Hardware: Decodable {
        let reality: String?
        let platform: String?
        let deviceType: String?
        let udid: String?
        let marketingName: String?
    }
    private struct State: Decodable { let name: String? }
    private struct Software: Decodable { let osVersionNumber: Version? }
    private struct Version: Decodable {
        let value: String
        private enum CodingKeys: String, CodingKey { case stringValue }
        init(from decoder: any Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) { self.value = string }
            else { self.value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .stringValue) }
        }
    }
    private struct LegacySoftware: Decodable {
        let name: String?
        let osVersionNumber: String?
        let screenViewingURL: String?
    }
    private struct Connection: Decodable {
        let state: String?
        let tunnelState: String?
        let transportType: String?
        let screenViewingURL: ViewingURL?
    }
    private struct ViewingURL: Decodable {
        let value: String
        private enum CodingKeys: String, CodingKey { case relative }
        init(from decoder: any Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) { self.value = string }
            else { self.value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .relative) }
        }
    }

    // MARK: - Public methods

    /// Includes remembered disconnected physical targets, never simulated entries returned by Xcode 27.
    public static func parse(_ data: Data) throws -> [SimulatorDevice] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        var seen = Set<UUID>()
        return envelope.result.devices.compactMap { device in
            guard let hardware = device.properties?.hardware ?? device.hardwareProperties,
                  hardware.reality == "physical", let udid = hardware.udid, !udid.isEmpty,
                  seen.insert(device.identifier).inserted else { return nil }
            let connection = device.properties?.connection ?? device.connectionProperties
            let platform = hardware.deviceType == "iPad" ? "iPadOS" : hardware.platform ?? "iOS"
            let version = device.properties?.software?.osVersionNumber?.value ?? device.deviceProperties?.osVersionNumber
            let runtime = [platform, version].compactMap { $0 }.joined(separator: " ")
            let rawURL = connection?.screenViewingURL?.value ?? device.deviceProperties?.screenViewingURL
            let physical = PhysicalDeviceInfo(udid: udid, transport: connection?.transportType,
                                              screenViewingURL: self.viewingURL(rawURL, deviceID: device.identifier))
            return SimulatorDevice(id: device.identifier,
                                   name: device.properties?.state?.name ?? device.deviceProperties?.name ?? hardware.marketingName ?? platform,
                                   runtime: runtime, state: connection?.state ?? connection?.tunnelState ?? "disconnected", physical: physical)
        }
    }

    /// A CoreDevice result cannot direct the UI to another device or an arbitrary URL handler.
    public static func viewingURL(_ value: String?, deviceID: UUID) -> URL? {
        guard let value, let components = URLComponents(string: value),
              components.scheme == "devices", components.host == "device", components.path == "/open",
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              components.queryItems?.count == 1,
              let item = components.queryItems?.first, item.name == "id", item.value.flatMap(UUID.init(uuidString:)) == deviceID else { return nil }
        return components.url
    }

    /// JSON goes into a private disposable file so discovery also works with older devicectl releases.
    /// The command and result size are bounded; a failure must not erase the simulator catalogue.
    public static func discover(developer: String, environment: [String: String]) throws -> [SimulatorDevice] {
        guard FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/devicectl") else { return [] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-device-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("devices.json")
        let result = EnvironmentInspector.boundedCapture("/usr/bin/xcrun", ["devicectl", "list", "devices", "--quiet", "--timeout", "6", "--json-output", output.path], environment: environment)
        guard result.0 == 0,
              let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { throw MimicError.invalidSimulator }
        return try self.parse(Data(contentsOf: output))
    }
}
