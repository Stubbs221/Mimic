//
//  SimulatorCoordinator.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppleSimulatorMCP
import Combine
import CryptoKit
import Foundation
import MimicCore

/// Native owner is replaceable for fixture tests; the secret is never part of this interface's UI payload.
@MainActor protocol SimulatorNativeDriver: AnyObject {
    func connect(developerDirectory: String) async throws
    func authorize(workspace: URL) async throws
    func startSession(deviceID: UUID, workspace: URL?) async throws -> AppleSimulatorDescriptor
    func capture(_ id: UUID) async throws -> SimulatorFrame
    func perform(_ id: UUID, action: AppleSimulatorAction, revision: UInt64) async throws -> SimulatorFrame
    func install(_ id: UUID) async throws
    func close(_ id: UUID) async throws
    func disconnect() async
}
extension Xcode27SimulatorConnection: SimulatorNativeDriver {
    func capture(_ id: UUID) async throws -> SimulatorFrame { try await SimulatorArtifactReader.read(session.capture(sessionID: id)) }
    func perform(_ id: UUID, action: AppleSimulatorAction, revision: UInt64) async throws -> SimulatorFrame { try await SimulatorArtifactReader.read(session.perform(sessionID: id, action: action, observedRevision: revision)) }
    func install(_ id: UUID) async throws { try await session.installAndRun(sessionID: id) }
    func close(_ id: UUID) async throws { try await session.close(sessionID: id) }
}

/// All native calls are admitted through TaskCoordinator's FIFO. Typed input exists only until its call completes.
@MainActor final class SimulatorCoordinator: ObservableObject {
    @Published private(set) var records: [SimulatorActivity] = []
    @Published private(set) var descriptor: AppleSimulatorDescriptor?
    private(set) var frame: SimulatorFrame?
    private(set) var ownerProject: ProjectContext?
    private var ownerDeveloper: String?
    private var driver: (any SimulatorNativeDriver)?
    private var pending: [UUID: (AppleSimulatorAction?, UInt64?)] = [:]
    // Process-local key prevents fingerprints of low-entropy typed secrets becoming a dictionary oracle.
    private let fingerprintKey = SymmetricKey(size: .bits256)
    private var fingerprints: [UUID: Data] = [:]
    // Same persisted array remains the replay ledger; only the UI/queue projection is retained.
    private var ledger: [UUID: SimulatorActivity] = [:]
    private var storageUnavailable = false
    private var activeID: UUID?
    private var stopped = false
    private var reading = false
    private var heartbeatAt = Date()
    private var leaseTimer: Task<Void, Never>?
    private let path: URL
    private let makeDriver: () -> any SimulatorNativeDriver
    private let inspect: @Sendable (ProjectContext) async throws -> ProjectContext
    private let supports: @Sendable (String) -> Bool
    private let catalogue: @Sendable (String) async throws -> [SimulatorDevice]
    var currentProject: () -> ProjectContext? = { nil }
    /// Additional registered chat contexts may enter the same FIFO without changing desktop selection.
    var currentProfile: () -> ProfileSnapshot? = { nil }
    var acceptsProject: (ProjectContext) -> Bool = { _ in false }
    private func accepts(_ project: ProjectContext) -> Bool { currentProject() == project || acceptsProject(project) }
    var mayAdmit: () -> Bool = { true }
    var schedule: () -> Void = { }
    init(directory: URL, supports: @escaping @Sendable (String) -> Bool = { SimulatorCoordinator.supported($0) }, makeDriver: @escaping () -> any SimulatorNativeDriver = { Xcode27SimulatorConnection() }, inspect: @escaping @Sendable (ProjectContext) async throws -> ProjectContext = { project in
        try await Task.detached { try EnvironmentInspector.project(path: project.path, developerDirectory: project.developerDirectory, appleTarget: project.appleTarget) }.value
    }, catalogue: @escaping @Sendable (String) async throws -> [SimulatorDevice] = { developer in
        try await Task.detached {
            var environment = ProcessInfo.processInfo.environment; environment["DEVELOPER_DIR"] = developer
            let result = EnvironmentInspector.capture("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], environment: environment)
            guard result.0 == 0 else { throw AppleSimulatorError.unsupported }; return try SimulatorCatalog.parse(Data(result.1.utf8))
        }.value
    }) {
        path = directory.appendingPathComponent("SimulatorActivities.json"); self.makeDriver = makeDriver; self.supports = supports; self.inspect = inspect; self.catalogue = catalogue
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                let saved = try JSONDecoder().decode([SimulatorActivity].self, from: Data(contentsOf: path))
                for var record in saved {
                    guard ledger[record.id] == nil else { throw BuildError.duplicate }
                    if record.status == .running || record.status == .preparing { record.status = .unknown; record.errorCode = "connectionLost" }
                    if record.status == .queued { record.status = .cancelled }
                    ledger[record.id] = record
                }
                records = Self.retained(Array(ledger.values))
            } catch { ledger = [:]; storageUnavailable = true }
        }
    }
    var busy: Bool { activeID != nil || reading || records.contains(where: \.holdsQueue) }
    var hasPending: Bool { busy || descriptor != nil || records.contains { $0.status == .queued } }
    var canExit: Bool { activeID == nil && !reading && descriptor == nil }
    var metadata: BridgeValue {
        .object(["session": descriptor.map { .object(["id": .string($0.id.uuidString), "deviceID": .string($0.deviceID.uuidString), "context": ownerProject.map { MimicIntegration.context($0) } ?? .null, "revision": frame.map { .number(Double($0.revision)) } ?? .null, "ready": .bool(frame != nil && !busy)]) } ?? .null, "activities": .array(records.map(\.metadata)), "busy": .bool(busy)])
    }

    // MARK: - Admission and shared execution

    func configuration(project: ProjectContext) async throws -> BridgeValue {
        let developer = try await resolveDeveloper(project)
        guard accepts(project) else { throw BuildError.context }
        let version = Self.version(developer)
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let availability = AppleSimulatorAvailability.evaluate(selectedXcodeVersion: version, macOSMajor: system.majorVersion, macOSMinor: system.minorVersion, nativeToolsAvailable: driver != nil && ownerProject == project)
        let devices = try await catalogue(developer)
        guard accepts(project) else { throw BuildError.context }
        return .object(["context": MimicIntegration.context(project), "developer": .string(developer), "version": .string(version), "availability": .string(availability.rawValue), "devices": try BridgeValue.encode(devices), "state": metadata])
    }
    func submit(id: UUID, kind: SimulatorActivity.Kind, project: ProjectContext, device: UUID, sessionID: UUID? = nil, action: AppleSimulatorAction? = nil, revision: UInt64? = nil) async throws -> SimulatorActivity {
        let admittedProfile = currentProfile()
        guard kind == .action ? action != nil && revision != nil : action == nil && revision == nil else { throw AppleSimulatorError.arguments }
        let fingerprint = try requestFingerprint(action: action, revision: revision)
        if let existing = activity(id) {
            guard existing.kind == kind, existing.project == project, existing.deviceID == device, existing.sessionID == sessionID else { throw BuildError.duplicate }
            if kind == .action {
                // Legacy/restarted requests have no trusted payload identity: never assert success.
                guard fingerprints[id] == fingerprint else { throw BuildError.duplicate }
            }
            return existing
        }
        guard !storageUnavailable else { throw BuildError.unavailable }
        guard !stopped, mayAdmit(), (kind == .close ? ownerProject == project : accepts(project)) else { throw BuildError.context }
        try checkCapacity()
        if kind == .start {
            guard descriptor == nil, !records.contains(where: { $0.kind == .start && $0.status.isPending }) else { throw AppleSimulatorError.occupied }
        } else {
            guard descriptor?.id == sessionID, descriptor?.deviceID == device, ownerProject == project else { throw AppleSimulatorError.noSession }
            if kind != .close { guard frame != nil, !records.contains(where: { $0.status == .unknown && !$0.queueReleased }) else { throw AppleSimulatorError.connectionLost } }
        }
        if kind == .action { guard let action, revision == frame?.revision else { throw AppleSimulatorError.arguments }; try frame?.validate(action) }
        let developer = kind == .close ? ownerDeveloper ?? (project.developerDirectory ?? "") : try await resolveDeveloper(project)
        if kind != .close { guard accepts(project), try await inspect(project) == project, mayAdmit(), !stopped else { throw BuildError.context } }
        guard kind == .close || supports(developer) else { throw AppleSimulatorError.unsupported }
        // Recheck after admission suspensions; another caller may have reserved this request or session.
        if activity(id) != nil { return try await submit(id: id, kind: kind, project: project, device: device, sessionID: sessionID, action: action, revision: revision) }
        if kind == .start { guard descriptor == nil, !records.contains(where: { $0.kind == .start && $0.status.isPending }) else { throw AppleSimulatorError.occupied } }
        else { guard descriptor?.id == sessionID, ownerDeveloper == developer else { throw BuildError.context } }
        try checkCapacity()
        var record = SimulatorActivity(id: id, project: project, developer: developer, deviceID: device, sessionID: sessionID, kind: kind)
        record.profileID = admittedProfile?.id; record.profileRevision = admittedProfile?.revision
        records.append(record); pending[id] = (action, revision); fingerprints[id] = fingerprint
        do { try persist() } catch { records.removeAll { $0.id == id }; ledger[id] = nil; pending[id] = nil; fingerprints[id] = nil; throw error }
        schedule(); return records.first { $0.id == id } ?? record
    }
    /// Includes evicted completed IDs so public lookup and duplicate admission stay idempotent.
    func activity(_ id: UUID) -> SimulatorActivity? { records.first { $0.id == id } ?? ledger[id] }
    private func checkCapacity() throws {
        guard records.filter({ $0.status.isPending || $0.holdsQueue }).count < 100 else { throw BuildError.capacity }
    }
    private static func retained(_ values: [SimulatorActivity]) -> [SimulatorActivity] {
        let ordered = values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        let unresolved = ordered.filter { $0.status.isPending || $0.holdsQueue }
        let completed = ordered.filter { !$0.status.isPending && !$0.holdsQueue }.suffix(100)
        return (Array(completed) + unresolved).sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    /// Exact scalar/bit identities avoid conflating rounded Apple commands or Unicode input.
    private func requestFingerprint(action: AppleSimulatorAction?, revision: UInt64?) throws -> Data {
        var components = [revision.map(String.init) ?? "none"]
        switch action {
        case let .tap(x, y): components += ["tap", String(x.bitPattern), String(y.bitPattern)]
        case let .swipe(x, y, endX, endY, duration): components += ["swipe", String(x.bitPattern), String(y.bitPattern), String(endX.bitPattern), String(endY.bitPattern), String(duration.bitPattern)]
        case let .text(value): components += ["text", value]
        case .home: components += ["home"]
        case let .orientation(value): components += ["orientation", value.rawValue]
        case nil: components += ["none"]
        }
        return Data(HMAC<SHA256>.authenticationCode(for: try JSONEncoder().encode(components), using: fingerprintKey))
    }
    func start(_ record: SimulatorActivity) {
        guard !busy, !stopped, records.first(where: { $0.id == record.id })?.status == .queued else { return }
        activeID = record.id; update(record.id, status: .preparing)
        Task {
            var nativeCallStarted = false
            do {
                if record.kind != .close {
                    guard try await inspect(record.project) == record.project, accepts(record.project), try await resolveDeveloper(record.project) == record.developer else { throw BuildError.context }
                    let devices = try await catalogue(record.developer)
                    guard devices.contains(where: { $0.id == record.deviceID }), accepts(record.project), !stopped else { throw BuildError.context }
                }
                update(record.id, status: .running)
                try persist()
                if record.kind == .start {
                    let connection = makeDriver(); driver = connection
                    try await connection.connect(developerDirectory: record.developer)
                    try await connection.authorize(workspace: URL(fileURLWithPath: record.project.workspace))
                    guard accepts(record.project), !stopped else { throw BuildError.context }
                    nativeCallStarted = true
                    descriptor = try await connection.startSession(deviceID: record.deviceID, workspace: URL(fileURLWithPath: record.project.workspace))
                    ownerProject = record.project; ownerDeveloper = record.developer
                    frame = try await connection.capture(try sessionID(record))
                    heartbeatAt = Date(); beginLease()
                } else {
                    let id = try sessionID(record)
                    guard let driver else { throw AppleSimulatorError.noSession }
                    if record.kind == .action {
                        guard let action = pending[record.id]?.0, let revision = pending[record.id]?.1, frame?.revision == revision else { throw AppleSimulatorError.arguments }
                        try frame?.validate(action); frame = nil; nativeCallStarted = true
                        frame = try await driver.perform(id, action: action, revision: revision)
                    } else if record.kind == .install {
                        frame = nil; nativeCallStarted = true; try await driver.install(id); frame = try await driver.capture(id)
                    } else if record.kind == .refresh {
                        frame = nil; nativeCallStarted = true; frame = try await driver.capture(id)
                    } else {
                        nativeCallStarted = true; try await driver.close(id); await driver.disconnect(); clearSession()
                    }
                }
                update(record.id, status: .succeeded)
            } catch {
                if nativeCallStarted { frame = nil }
                update(record.id, status: nativeCallStarted ? .unknown : .failed, error: nativeCallStarted ? "connectionLost" : error is BuildError ? "context" : "requiresNativeAccess")
                if descriptor == nil { await driver?.disconnect(); driver = nil }
            }
            pending[record.id] = nil; activeID = nil; try? persist(); schedule()
            if stopped { await cleanupForExit() }
        }
    }
    private func sessionID(_ record: SimulatorActivity) throws -> UUID {
        guard let descriptor, descriptor.deviceID == record.deviceID, record.sessionID == nil || record.sessionID == descriptor.id else { throw AppleSimulatorError.noSession }; return descriptor.id
    }

    // MARK: - Private observation and lifecycle

    func observation(sessionID: UUID) throws -> BridgeValue {
        guard descriptor?.id == sessionID, let frame, !busy else { throw AppleSimulatorError.occupied }; heartbeatAt = Date(); return frame.payload
    }
    func heartbeat(_ id: UUID) throws { guard descriptor?.id == id else { throw AppleSimulatorError.noSession }; heartbeatAt = Date() }
    /// A human checks Xcode first, then explicitly releases an uncertain operation. No native mutation is replayed.
    func releaseUnknown(_ id: UUID) async throws {
        guard activeID == nil, let index = records.firstIndex(where: { $0.id == id && $0.status == .unknown && !$0.queueReleased }) else { throw AppleSimulatorError.arguments }
        if let descriptor, let driver { try await driver.close(descriptor.id) }
        await driver?.disconnect(); clearSession(); records[index].queueReleased = true; try persist(); schedule()
    }
    func stop() {
        stopped = true; leaseTimer?.cancel()
        for index in records.indices where records[index].status == .queued { records[index].status = .cancelled; pending[records[index].id] = nil }
        try? persist(); Task { await cleanupForExit() }
    }
    private func cleanupForExit() async {
        guard activeID == nil, !reading else { return }
        reading = true
        if !records.contains(where: { $0.kind == .close && $0.status == .unknown && !$0.queueReleased }), let descriptor, let driver, let project = ownerProject, let developer = ownerDeveloper {
            var closing = SimulatorActivity(id: UUID(), project: project, developer: developer, deviceID: descriptor.deviceID, sessionID: descriptor.id, kind: .close)
            closing.status = .running; records.append(closing)
            do { try persist(); try await driver.close(descriptor.id); update(closing.id, status: .succeeded) }
            catch { update(closing.id, status: .unknown, error: "connectionLost") }
        }
        await driver?.disconnect(); clearSession(); reading = false; schedule()
    }
    private func beginLease() {
        leaseTimer?.cancel()
        leaseTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, let descriptor = self.descriptor else { return }
                if Date().timeIntervalSince(self.heartbeatAt) > 60, !self.busy, let project = self.ownerProject {
                    _ = try? await self.submit(id: UUID(), kind: .close, project: project, device: descriptor.deviceID, sessionID: descriptor.id)
                    return
                }
            }
        }
    }
    private func clearSession() { descriptor = nil; frame = nil; driver = nil; ownerProject = nil; ownerDeveloper = nil; leaseTimer?.cancel(); leaseTimer = nil }
    private func update(_ id: UUID, status: BuildStatus, error: String? = nil) { if let index = records.firstIndex(where: { $0.id == id }) { records[index].status = status; records[index].errorCode = error; try? persist() } }
    private func persist() throws {
        guard !storageUnavailable else { throw BuildError.unavailable }
        var updated = ledger
        for record in records { updated[record.id] = record }
        let ordered = updated.values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Commit the complete replay ledger before evicting anything from the presentation.
        try JSONEncoder().encode(ordered).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        ledger = updated; records = Self.retained(ordered)
    }
    private func resolveDeveloper(_ project: ProjectContext) async throws -> String {
        if let developer = project.developerDirectory { return developer }
        let result = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]) }.value
        guard result.0 == 0, !result.1.isEmpty else { throw AppleSimulatorError.unsupported }; return result.1
    }
    private nonisolated static func version(_ developer: String) -> String {
        Bundle(url: URL(fileURLWithPath: developer).deletingLastPathComponent().deletingLastPathComponent())?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    private nonisolated static func supported(_ developer: String) -> Bool {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return AppleSimulatorAvailability.evaluate(selectedXcodeVersion: version(developer), macOSMajor: system.majorVersion, macOSMinor: system.minorVersion, nativeToolsAvailable: true) == .available
    }
}
