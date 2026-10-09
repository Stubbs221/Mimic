//
//  MimicBridge.swift
//  MimicCore
//
//  Created by Василий Маслов on 04.10.2026.
import Darwin
import Foundation

/// JSON values shared by the local bridge and MCP. Credentials never belong in this payload.
public enum BridgeValue: Codable, Sendable, Equatable {
    case object([String: BridgeValue]), array([BridgeValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([BridgeValue].self) { self = .array(v) }
        else { self = try .object(c.decode([String: BridgeValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case let .string(v) = self { v } else { nil } }
    public var object: [String: BridgeValue]? { if case let .object(v) = self { v } else { nil } }
    public var array: [BridgeValue]? { if case let .array(v) = self { v } else { nil } }
    public var integer: Int? {
        guard case let .number(v) = self, v.isFinite, v.rounded() == v, v >= 0, v < Double(Int.max) else { return nil }
        return Int(v)
    }
    public subscript(_ key: String) -> BridgeValue { self.object?[key] ?? .null }
    public static func encode<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}

/// Versioned, single-request connection. IDs correlate transport calls, not execution authorization.
public struct MimicBridgeRequest: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let threadID: String?
    /// Helper-owned connection identity for clients that do not supply a host chat ID.
    /// Neither identity nor the informational client name is a public tool argument.
    public let clientSessionID: String?
    public let clientName: String?
    /// Helpers opt in only when they can strip presentation fields into private MCP metadata.
    public let presentationMetadataVersion: Int?
    public let helperIdentity: AgentHelperIdentity?
    public let method: String
    public let parameters: [String: BridgeValue]
    public init(method: String, parameters: [String: BridgeValue] = [:], id: UUID = UUID(), version: Int = 3, threadID: String? = nil, presentationMetadataVersion: Int? = nil, clientSessionID: String? = nil, clientName: String? = nil, helperIdentity: AgentHelperIdentity? = nil) {
        self.version = version; self.id = id; self.threadID = threadID; self.method = method; self.parameters = parameters; self.presentationMetadataVersion = presentationMetadataVersion
        self.clientSessionID = clientSessionID; self.clientName = clientName; self.helperIdentity = helperIdentity
    }
}

/// Recoverable errors have stable codes; text is localized by the native application.
public struct MimicBridgeReply: Codable, Sendable {
    public let id: UUID
    public let result: BridgeValue
    public let error: String?
    public let message: String?
    public init(id: UUID, result: BridgeValue = .null, error: String? = nil, message: String? = nil) {
        self.id = id; self.result = result; self.error = error; self.message = message
    }
}

public enum MimicBridgeError: Error, Sendable { case unavailable, invalidMessage, timeout, occupied }

/// One socket per logged-in user. The directory is private; the peer UID is also checked.
// MARK: - Socket transport

public enum MimicSocket {
    public static var path: String {
        NSHomeDirectory() + "/Library/Application Support/Mimic/Bridge/mcp.sock"
    }
    public static let maximumBytes = 1024 * 1024

    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw MimicBridgeError.invalidMessage }
        value.sun_family = sa_family_t(AF_UNIX); value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        return value
    }
    static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    static func wait(_ fd: Int32, _ events: Int16, timeout: Int32 = 30_000) throws {
        var p = pollfd(fd: fd, events: events, revents: 0)
        let status = poll(&p, 1, timeout)
        guard status > 0 else { throw MimicBridgeError.timeout }
        guard p.revents & events != 0 else { throw MimicBridgeError.unavailable }
    }
    static func receive(_ fd: Int32, timeout: Int32 = 30_000) throws -> Data {
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while result.count <= maximumBytes {
            try wait(fd, Int16(POLLIN), timeout: timeout)
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw MimicBridgeError.unavailable }
            if let newline = bytes.prefix(count).firstIndex(of: 10) {
                result.append(contentsOf: bytes[..<newline])
                guard result.count <= maximumBytes else { throw MimicBridgeError.invalidMessage }
                return result
            }
            result.append(contentsOf: bytes.prefix(count))
        }
        throw MimicBridgeError.invalidMessage
    }
    static func send(_ data: Data, to fd: Int32) throws {
        guard data.count <= maximumBytes else { throw MimicBridgeError.invalidMessage }
        let bytes = Array(data) + [10]
        var offset = 0
        while offset < bytes.count {
            try wait(fd, Int16(POLLOUT))
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            guard count > 0 else { throw MimicBridgeError.unavailable }
            offset += count
        }
    }
    /// Blocking socket operations stay off the UI actor. A disconnected caller never repeats a mutation.
    @concurrent public static func call(_ request: MimicBridgeRequest, path: String = MimicSocket.path) async throws -> MimicBridgeReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MimicBridgeError.unavailable }
        defer { close(fd) }
        configure(fd)
        var address = try address(path)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0 else { throw MimicBridgeError.unavailable }
        try send(JSONEncoder().encode(request), to: fd)
        let reply = try JSONDecoder().decode(MimicBridgeReply.self, from: receive(fd, timeout: request.method == "get_build_configuration" || request.method == "cli_get_build_configuration" ? 130_000 : 30_000))
        guard reply.id == request.id else { throw MimicBridgeError.invalidMessage }
        return reply
    }
}

/// The native app owns the listener. Closing a Codex panel cannot stop application jobs.
// MARK: - Native listener

@MainActor public final class MimicBridgeListener {
    private var source: (any DispatchSourceRead)?
    private var fd: Int32 = -1
    private var active = 0
    private let path: String
    public init(path: String = MimicSocket.path) { self.path = path }
    public func start(handler: @escaping @MainActor @Sendable (MimicBridgeRequest) async -> MimicBridgeReply) throws {
        guard self.fd < 0 else { return }
        let directory = URL(fileURLWithPath: self.path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MimicBridgeError.unavailable }
        MimicSocket.configure(fd)
        var address = try MimicSocket.address(self.path)
        if FileManager.default.fileExists(atPath: self.path) {
            let alive = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            close(fd)
            guard alive != 0 else { throw MimicBridgeError.occupied }
            try FileManager.default.removeItem(atPath: self.path)
            return try self.start(handler: handler)
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 32) == 0 else { close(fd); throw MimicBridgeError.unavailable }
        chmod(self.path, 0o600); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var uid: uid_t = 0, gid: gid_t = 0
                // Two six-request video pipelines plus liveness probes and control traffic must fit.
                // Retain a hard bound for malformed/slow local clients.
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), self.active < 32 else { close(client); return }
                MimicSocket.configure(client); self.active += 1
                Task {
                    await Self.serve(client, handler: handler)
                    self.active -= 1
                }
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source; source.resume()
    }
    public func stop() {
        guard self.fd >= 0 else { return }
        self.source?.cancel(); self.source = nil; self.fd = -1
        try? FileManager.default.removeItem(atPath: self.path)
    }
    @concurrent private static func serve(_ fd: Int32, handler: @MainActor @Sendable (MimicBridgeRequest) async -> MimicBridgeReply) async {
        defer { close(fd) }
        do {
            let request = try JSONDecoder().decode(MimicBridgeRequest.self, from: MimicSocket.receive(fd))
            let compatible = request.version == 3 || request.version == 2 && ["prepare_development_update", "get_development_update_state"].contains(request.method)
            let reply: MimicBridgeReply
            if !compatible { reply = .init(id: request.id, error: "unsupportedVersion") }
            else if request.method == "bridge_ping", request.parameters.isEmpty {
                // Internal IPC only: no model/tool registration and no native app-state work.
                reply = .init(id: request.id, result: .object(["version": .number(3)]))
            } else { reply = await handler(request) }
            try MimicSocket.send(JSONEncoder().encode(reply), to: fd)
        } catch { /* A malformed/disconnected peer is isolated from other clients and app state. */ }
    }
}
