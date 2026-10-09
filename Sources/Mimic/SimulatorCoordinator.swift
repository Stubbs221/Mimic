//
//  SimulatorCoordinator.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
import AppKit
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
    @Published private(set) var localRecords: [SimulatorActivity] = []
    @Published private(set) var descriptor: AppleSimulatorDescriptor?
    private(set) var frame: SimulatorFrame?
    private(set) var ownerProject: ProjectContext?
    private var ownerDeveloper: String?
    private var driver: (any SimulatorNativeDriver)?
    var onAgentOperation: (SimulatorActivity) -> Void = { _ in }
    var onAgentSessionClosed: (UUID) -> Void = { _ in }
    private var appRequests: [UUID: SimulatorAppRequest] = [:]
    private var completedRecordings: [UUID: SimulatorRecordingResult] = [:]
    private var pending: [UUID: (AppleSimulatorAction?, UInt64?)] = [:]
    // Process-local key prevents fingerprints of low-entropy typed secrets becoming a dictionary oracle.
    private let fingerprintKey = SymmetricKey(size: .bits256)
    private var fingerprints: [UUID: Data] = [:]
    // Same persisted array remains the replay ledger; only the UI/queue projection is retained.
    private var ledger: [UUID: SimulatorActivity] = [:]
    private var storageUnavailable = false
    private var activeID: UUID?
    private var stopped = false
    @Published private var reading = false
    private var passiveCapture: Task<SimulatorFrame, Error>?
    private var heartbeatAt = Date()
    private var leaseTimer: Task<Void, Never>?
    private let path: URL
    private let isChild: Bool
    private var children: [String: SimulatorCoordinator] = [:]
    private var childSubscriptions: [AnyCancellable] = []
    private var viewers: [UUID: Viewer] = [:]
    private var videoViewers: Set<UUID> = []
    private var video: SimulatorVideo?
    private var input: (any SimulatorInputDriver)?
    private var inputStarting = false
    private var inputRetiring = false
    private var inputSending = false
    private var inputGeneration = UUID()
    @Published private var touchLease: TouchLease?
    private struct TouchLease {
        let viewer: UUID
        let gesture: UUID
        let width: Double
        let height: Double
        let orientation: String
        var sequence: UInt64
        var closing = false
    }
    private let makeInput: () -> any SimulatorInputDriver
    /// Manual continuous input never jumps ahead of an admitted local operation.
    var mayStartInput: () -> Bool = { true }
    private var sharedView = false
    private var publicRevision: UInt64 = 1
    private var orientation = "portrait"
    private var authorizationWorkspace: URL?
    private var viewerTimer: Task<Void, Never>?
    private var accessPicker: NSOpenPanel?
    private var accessError: String?
    private struct Viewer { let thread: String; let owner: SimulatorCoordinator; var visible: Bool; var at: Date }
    var records: [SimulatorActivity] { localRecords + children.values.flatMap(\.records) }
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
    var recentIDs: (String) -> [UUID] = { _ in [] }
    var didUseDevice: (UUID, String) -> Void = { _, _ in }
    var now: () -> Date = Date.init
    init(directory: URL, isChild: Bool = false, supports: @escaping @Sendable (String) -> Bool = { SimulatorCoordinator.supported($0) }, makeDriver: @escaping () -> any SimulatorNativeDriver = { Xcode27SimulatorConnection() }, inspect: @escaping @Sendable (ProjectContext) async throws -> ProjectContext = { project in
        try await Task.detached { try EnvironmentInspector.project(path: project.path, developerDirectory: project.developerDirectory, appleTarget: project.appleTarget) }.value
    }, catalogue: @escaping @Sendable (String) async throws -> [SimulatorDevice] = { developer in
        try await Task.detached {
            var environment = ProcessInfo.processInfo.environment; environment["DEVELOPER_DIR"] = developer
            let result = EnvironmentInspector.capture("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], environment: environment)
            guard result.0 == 0 else { throw AppleSimulatorError.unsupported }; return try SimulatorCatalog.parse(Data(result.1.utf8))
        }.value
    }, makeInput: @escaping () -> any SimulatorInputDriver = { SimulatorInput() }) {
        self.makeInput = makeInput
        self.isChild = isChild; path = directory.appendingPathComponent("SimulatorActivities.json"); self.makeDriver = makeDriver; self.supports = supports; self.inspect = inspect; self.catalogue = catalogue
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                let saved = try JSONDecoder().decode([SimulatorActivity].self, from: Data(contentsOf: path))
                for var record in saved {
                    guard ledger[record.id] == nil else { throw BuildError.duplicate }
                    if record.status == .running || record.status == .preparing { record.status = .unknown; record.errorCode = "connectionLost" }
                    if record.status == .queued { record.status = .cancelled }
                    ledger[record.id] = record
                }
                localRecords = Self.retained(Array(ledger.values))
            } catch { ledger = [:]; storageUnavailable = true }
        }
        if !isChild, let directories = try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Devices"), includingPropertiesForKeys: nil) {
            for directory in directories where directory.lastPathComponent.count == 64 { _ = makeChild(key: directory.lastPathComponent) }
        }
    }
    var busy: Bool { activeID != nil || reading || inputStarting || inputRetiring || touchLease != nil || localRecords.contains(where: \.holdsQueue) || children.values.contains(where: \.busy) }
    var hasPending: Bool { busy || records.contains { $0.status == .queued } }
    var canExit: Bool { SimulatorVideo.canExit && SimulatorInput.canExit && touchLease == nil && !inputStarting && !inputRetiring && activeID == nil && !reading && descriptor == nil && children.values.allSatisfy(\.canExit) }
    var metadata: BridgeValue {
        .object(["session": descriptor.map { .object(["id": .string($0.id.uuidString), "deviceID": .string($0.deviceID.uuidString), "context": ownerProject.map { MimicIntegration.context($0, profile: currentProfile()) } ?? .null, "revision": frame.map { _ in .number(Double(publicRevision)) } ?? .null, "ready": .bool(frame != nil && !busy)]) } ?? .null, "activities": .array(localRecords.map(\.metadata)), "busy": .bool(busy)])
    }


    // MARK: - Independent Codex viewers

    private func accessWorkspace(developer: String) -> URL? {
        guard let data = try? Data(contentsOf: path.deletingLastPathComponent().appendingPathComponent("SimulatorAccess.json")),
              let values = try? JSONDecoder().decode([String: String].self, from: data), let path = values[developer],
              FileManager.default.fileExists(atPath: path), ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: path).pathExtension) else { return nil }
        return URL(fileURLWithPath: path)
    }
    func chooseAccess(project: ProjectContext?) async throws {
        let developer = try await resolveDeveloper(project)
        guard !stopped, project.map(accepts) ?? true else { throw BuildError.context }
        guard supports(developer) else { throw AppleSimulatorError.unsupported }
        guard accessPicker == nil else { return }
        let picker = NSOpenPanel(); accessPicker = picker; accessError = nil
        picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.title = text("simulator.workspace.title"); picker.prompt = text("simulator.workspace.choose")
        picker.begin { [weak self] response in
            guard let self else { return }
            defer { self.accessPicker = nil; self.objectWillChange.send() }
            guard response == .OK, let workspace = picker.url else { return }
            do { try self.rememberAccess(workspace: workspace, developer: developer) }
            catch { self.accessError = text("simulator.workspace.invalid") }
        }
    }

    /// Persists only an explicitly selected real workspace, never a generated authorization project.
    func rememberAccess(workspace: URL, developer: String) throws {
        guard workspace.isFileURL, ["xcodeproj", "xcworkspace"].contains(workspace.pathExtension), FileManager.default.fileExists(atPath: workspace.path) else { throw AppleSimulatorError.arguments }
        let url = path.deletingLastPathComponent().appendingPathComponent("SimulatorAccess.json")
        var values = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        values[developer] = workspace.resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(values).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func makeChild(key: String) -> SimulatorCoordinator {
        if let child = children[key] { return child }
        let child = SimulatorCoordinator(directory: path.deletingLastPathComponent().appendingPathComponent("Devices/" + key), isChild: true, supports: supports, makeDriver: makeDriver, inspect: inspect, catalogue: catalogue, makeInput: makeInput)
        child.sharedView = true
        child.currentProject = { [weak self] in self?.currentProject() }
        child.currentProfile = { [weak self] in self?.currentProfile() }
        child.acceptsProject = { [weak self] in self?.accepts($0) == true }
        child.mayAdmit = { [weak self] in self?.mayAdmit() == true }
        child.mayStartInput = { [weak self] in self?.mayStartInput() == true }
        child.schedule = { [weak self] in self?.schedule() }
        child.onAgentOperation = { [weak self] in self?.onAgentOperation($0) }
        child.onAgentSessionClosed = { [weak self] in self?.onAgentSessionClosed($0) }
        child.didUseDevice = { [weak self] in self?.didUseDevice($0, $1) }
        child.now = { [weak self] in self?.now() ?? Date() }
        childSubscriptions.append(child.objectWillChange.sink { [weak self] in self?.objectWillChange.send() })
        children[key] = child; return child
    }
    private func childOwner(device: UUID, developer: String) -> SimulatorCoordinator {
        if descriptor?.deviceID == device, ownerDeveloper == developer { return self }
        if let child = children.values.first(where: { $0.ownerDeveloper == developer && $0.descriptor?.deviceID == device || $0.localRecords.contains { $0.deviceID == device && $0.developer == developer && $0.kind == .start && $0.status.isPending } }) { return child }
        let key = SHA256.hash(data: Data((developer + "|" + device.uuidString).utf8)).map { String(format: "%02x", $0) }.joined()
        return makeChild(key: key)
    }
    func sessionOwner(_ id: UUID) -> SimulatorCoordinator? { descriptor?.id == id ? self : children.values.first { $0.descriptor?.id == id } }
    func sessionAllowed(_ id: UUID, thread: String?, project: ProjectContext?) -> Bool {
        guard let owner = sessionOwner(id) else { return false }
        if thread == nil { return true }
        return viewers.values.contains { $0.thread == thread && $0.owner === owner } || owner.ownerProject == project && project != nil
    }
    func viewerMetadata(thread: String?, project: ProjectContext?, viewer: UUID? = nil) -> BridgeValue {
        var value = metadata.object ?? [:]
        let owner = viewer.flatMap { viewers[$0]?.thread == thread ? viewers[$0]?.owner : nil } ?? thread.flatMap { thread in viewers.values.first { $0.thread == thread }?.owner } ?? (thread == nil ? self : nil)
        var session = owner?.metadata["session"].object
        if let project { session?["context"] = MimicIntegration.context(project, profile: currentProfile()) }
        value["session"] = session.map(BridgeValue.object) ?? .null
        value["activities"] = .array(records.map(\.metadata)); value["busy"] = .bool(busy); value["protocolVersion"] = .number(3)
        let developer = project?.developerDirectory ?? EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
        let version = Self.version(developer)
        value["inputOwner"] = owner?.touchLease.map { .string($0.viewer.uuidString) } ?? .null
        value["visible"] = .bool((Int(version.split(separator: ".").first ?? "0") ?? 0) >= 27)
        value["version"] = .string(version)
        return .object(value)
    }
    func attachViewer(_ viewer: UUID, thread: String, project: ProjectContext?, device: UUID, request: UUID) async throws -> BridgeValue {
        guard !stopped, project.map(accepts) ?? true else { throw BuildError.context }
        let developer = try await resolveDeveloper(project)
        guard !stopped, project.map(accepts) ?? true else { throw BuildError.context }
        guard supports(developer) else { throw AppleSimulatorError.unsupported }
        guard let workspace = accessWorkspace(developer: developer) else { throw AppleSimulatorError.unsupported }
        if let existing = viewers[viewer], existing.thread != thread { throw BuildError.context }
        detachViewer(viewer, thread: thread)
        let child = childOwner(device: device, developer: developer); child.authorizationWorkspace = workspace
        var activity: SimulatorActivity?
        if child.descriptor == nil {
            activity = child.localRecords.first { $0.kind == .start && $0.status.isPending }
            if activity == nil { activity = try child.submitDevice(id: request, kind: .start, device: device, developer: developer, workspace: workspace) }
        }
        viewers[viewer] = Viewer(thread: thread, owner: child, visible: true, at: now()); child.heartbeatAt = now()
        startViewerTimer()
        return .object(["activity": activity?.metadata ?? .null, "state": viewerMetadata(thread: thread, project: project, viewer: viewer)])
    }
    func detachViewer(_ viewer: UUID, thread: String) {
        guard let value = viewers[viewer], value.thread == thread else { return }
        if value.owner.touchLease?.viewer == viewer { value.owner.retireInput() }
        viewers[viewer] = nil; videoViewers.remove(viewer); value.owner.video?.revoke(viewer); value.owner.heartbeatAt = now()
        updateVideoVisibility(value.owner)
    }
    func viewerHeartbeat(_ viewer: UUID, thread: String, visible: Bool) throws -> BridgeValue {
        guard var value = viewers[viewer], value.thread == thread else { throw AppleSimulatorError.noSession }
        if !visible, value.owner.touchLease?.viewer == viewer { value.owner.retireInput() }
        value.at = now(); value.visible = visible; viewers[viewer] = value; value.owner.heartbeatAt = now(); value.owner.video?.renew(viewer)
        updateVideoVisibility(value.owner)
        return viewerMetadata(thread: thread, project: nil, viewer: viewer)
    }
    private func updateVideoVisibility(_ owner: SimulatorCoordinator) {
        for (id, value) in viewers where value.owner === owner { owner.video?.viewerVisible(id, value.visible && videoViewers.contains(id)) }
        owner.video?.visibility(owner.video?.recording != nil || viewers.contains { videoViewers.contains($0.key) && $0.value.owner === owner && $0.value.visible }) }
    private func startViewerTimer() {
        guard viewerTimer == nil else { return }
        viewerTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10)); guard let self, !Task.isCancelled else { return }
                self.expireViewers()
            }
        }
    }
    /// Expired views release only their own subscription; device sessions have a separate 60-second lease.
    func expireViewers() {
        for (id, viewer) in viewers where now().timeIntervalSince(viewer.at) > 30 { detachViewer(id, thread: viewer.thread) }
    }
    func expireIdleSessions() async {
        for child in children.values { await child.expireIdleSessions() }
        guard let descriptor, now().timeIntervalSince(heartbeatAt) >= 60, !busy, let project = ownerProject else { return }
        _ = try? await submit(id: UUID(), kind: .close, project: project, device: descriptor.deviceID, sessionID: descriptor.id)
    }
    func videoAccess(_ viewer: UUID, thread: String) async throws -> BridgeValue {
        guard let value = viewers[viewer], value.thread == thread, value.visible, value.owner.descriptor != nil else { throw AppleSimulatorError.noSession }
        let owner = value.owner
        if owner.video == nil { owner.video = SimulatorVideo(); owner.video?.onExit = { [weak self] in self?.schedule() } }
        videoViewers.insert(viewer)
        await owner.video?.start(device: owner.descriptor!.deviceID, developer: owner.ownerDeveloper!)
        guard viewers[viewer]?.owner === owner, viewers[viewer]?.visible == true else { throw AppleSimulatorError.noSession }
        owner.video?.orientation(owner.orientation); updateVideoVisibility(owner)
        return owner.video?.grant(viewer) ?? .object(["mode": .string("snapshots")])
    }
    func stopVideo(_ viewer: UUID, thread: String) {
        guard let value = viewers[viewer], value.thread == thread else { return }
        videoViewers.remove(viewer); value.owner.video?.revoke(viewer); updateVideoVisibility(value.owner)
        if value.owner.video?.recording == nil && !viewers.contains(where: { videoViewers.contains($0.key) && $0.value.owner === value.owner }) { value.owner.video?.stop(); value.owner.video = nil }
    }
    func videoSize(_ viewer: UUID, thread: String, width: Int, height: Int) throws {
        guard let value = viewers[viewer], value.thread == thread, value.visible, (2...4096).contains(width), (2...4096).contains(height) else { throw AppleSimulatorError.arguments }
        value.owner.video?.size(viewer, width: width, height: height)
    }
    func viewerMasks(_ viewer: UUID, thread: String) async throws -> BridgeValue {
        guard let value = viewers[viewer], value.thread == thread, let descriptor = value.owner.descriptor, let developer = value.owner.ownerDeveloper else { throw AppleSimulatorError.noSession }
        let devices = try await catalogue(developer)
        guard viewers[viewer]?.owner === value.owner, value.owner.descriptor?.id == descriptor.id else { throw AppleSimulatorError.noSession }
        guard let identifier = devices.first(where: { $0.id == descriptor.deviceID })?.deviceTypeIdentifier else { return .null }
        return SimulatorDeviceGeometry.masks(identifier: identifier, developer: developer)
    }
    func videoPoll(_ viewer: UUID, thread: String, after: UInt64, token: String? = nil) throws -> BridgeValue {
        guard let value = viewers[viewer], value.thread == thread, value.visible else { throw AppleSimulatorError.noSession }
        guard let video = value.owner.video else { throw AppleSimulatorError.noSession }
        return try video.poll(viewer: viewer, after: after, token: token)
    }
    func viewerObservation(_ viewer: UUID, thread: String, refresh: Bool) async throws -> BridgeValue {
        guard let value = viewers[viewer], value.thread == thread, value.visible, let id = value.owner.descriptor?.id else { throw AppleSimulatorError.noSession }
        let owner = value.owner
        if let capture = owner.passiveCapture {
            _ = try await capture.value
        } else if refresh, !busy, !records.contains(where: { $0.status == .queued }), let driver = owner.driver {
            owner.reading = true
            // Concurrent panels share the same Apple capture and queue reservation.
            // Publish its frame before waking subscribers, so none sees a false busy error.
            let capture = Task { @MainActor in
                defer {
                    owner.passiveCapture = nil; owner.reading = false; self.schedule()
                    if owner.stopped { Task { await owner.cleanupForExit() } }
                }
                do {
                    let result = try await driver.capture(id)
                    guard owner.descriptor?.id == id, !owner.stopped else { throw AppleSimulatorError.noSession }
                    owner.frame = result
                    return result
                } catch {
                    // A failed passive read has no command to replay. Retire the dead
                    // Apple connection so the next explicit attach creates a new session.
                    if owner.descriptor?.id == id,
                       let failure = error as? AppleSimulatorError,
                       [.connectionLost, .noSession, .invalidResponse].contains(failure) {
                        owner.clearSession()
                        await driver.disconnect()
                    }
                    throw error
                }
            }
            owner.passiveCapture = capture
            _ = try await capture.value
        }
        guard viewers[viewer]?.owner === owner, viewers[viewer]?.visible == true else { throw AppleSimulatorError.noSession }
        return try owner.observation(sessionID: id)
    }

    /// A device scope is independent of the chat checkout. The queue adapter names the explicitly selected real workspace.
    private func submitDevice(id: UUID, kind: SimulatorActivity.Kind, device: UUID, developer: String, workspace: URL, action: AppleSimulatorAction? = nil, revision: UInt64? = nil) throws -> SimulatorActivity {
        guard !stopped, mayAdmit(), supports(developer), kind == .start || kind == .action else { throw AppleSimulatorError.unsupported }
        let fingerprint = try requestFingerprint(action: action, revision: revision)
        if let existing = activity(id) {
            guard existing.deviceOnly == true, existing.kind == kind, existing.deviceID == device, existing.developer == developer, kind != .action || fingerprints[id] == fingerprint else { throw BuildError.duplicate }
            return existing
        }
        guard !storageUnavailable else { throw BuildError.unavailable }
        try checkCapacity()
        if kind == .start { guard descriptor == nil, !localRecords.contains(where: { $0.kind == .start && $0.status.isPending }) else { throw AppleSimulatorError.occupied } }
        else { guard descriptor?.deviceID == device, ownerDeveloper == developer, let frame, revision == publicRevision, let action else { throw AppleSimulatorError.noSession }; try frame.validate(action) }
        let scope = ProjectContext(path: workspace.deletingLastPathComponent().path, branch: "", commit: "", developerDirectory: developer)
        var record = SimulatorActivity(id: id, project: scope, developer: developer, deviceID: device, sessionID: descriptor?.id, kind: kind)
        record.deviceOnly = true
        localRecords.append(record); pending[id] = (action, revision); fingerprints[id] = fingerprint
        do { try persist() } catch { localRecords.removeAll { $0.id == id }; pending[id] = nil; fingerprints[id] = nil; throw error }
        schedule(); return record
    }
    func viewerAction(_ viewer: UUID, thread: String, request: UUID, action: AppleSimulatorAction, revision: UInt64) throws -> BridgeValue {
        guard let value = viewers[viewer], value.thread == thread, value.visible, let descriptor = value.owner.descriptor, let developer = value.owner.ownerDeveloper, let workspace = value.owner.authorizationWorkspace, !busy else { throw AppleSimulatorError.occupied }
        return try value.owner.submitDevice(id: request, kind: .action, device: descriptor.deviceID, developer: developer, workspace: workspace, action: action, revision: revision).metadata
    }


    // MARK: - App-only continuous input

    private var hasContinuousInput: Bool { touchLease != nil || inputStarting || inputRetiring || children.values.contains(where: \.hasContinuousInput) }

    func inputAccess(_ viewer: UUID, thread: String) async throws -> BridgeValue {
        guard let value = viewers[viewer], value.thread == thread, value.visible,
              let descriptor = value.owner.descriptor, let developer = value.owner.ownerDeveloper,
              value.owner.frame != nil, !busy, !hasPending, mayAdmit(), mayStartInput() else { throw AppleSimulatorError.occupied }
        let owner = value.owner
        owner.inputStarting = true
        defer { owner.inputStarting = false; schedule(); if owner.stopped { Task { await owner.cleanupForExit() } } }
        if owner.input == nil {
            let input = owner.makeInput(); owner.input = input
            input.onFailure = { [weak owner] in owner?.retireInput() }
            do { try await input.start(device: descriptor.deviceID, developer: developer) }
            catch { await input.stop(); if input.stopped { owner.input = nil }; throw error }
        }
        guard !stopped, !owner.stopped, viewers[viewer]?.owner === owner, viewers[viewer]?.visible == true,
              owner.descriptor?.id == descriptor.id, let frame = owner.frame else { owner.retireInput(); throw AppleSimulatorError.noSession }
        return .object(["sessionID": .string(descriptor.id.uuidString), "generation": .string(owner.inputGeneration.uuidString),
                        "width": .number(Double(frame.width)), "height": .number(Double(frame.height)), "orientation": .string(owner.orientation)])
    }

    func inputEvent(_ viewer: UUID, thread: String, event: SimulatorTouchEvent) async throws -> BridgeValue {
        guard let value = viewers[viewer], value.thread == thread, value.visible else { throw AppleSimulatorError.noSession }
        let owner = value.owner
        guard !stopped, !owner.stopped, event.sessionID == owner.descriptor?.id, event.generation == owner.inputGeneration,
              let input = owner.input, !owner.inputSending else { throw AppleSimulatorError.noSession }
        if event.phase == .down {
            guard !busy, !hasPending, mayAdmit(), mayStartInput(), event.sequence == 1, let frame = owner.frame else { throw AppleSimulatorError.occupied }
            _ = try event.physicalPoint(width: Double(frame.width), height: Double(frame.height), orientation: owner.orientation)
            owner.touchLease = TouchLease(viewer: viewer, gesture: event.gestureID, width: Double(frame.width), height: Double(frame.height), orientation: owner.orientation, sequence: 0)
        }
        guard var lease = owner.touchLease, !lease.closing, lease.viewer == viewer, lease.gesture == event.gestureID,
              event.sequence == lease.sequence + 1 else { throw AppleSimulatorError.arguments }
        let point = try event.physicalPoint(width: lease.width, height: lease.height, orientation: lease.orientation)
        lease.sequence = event.sequence; owner.touchLease = lease
        owner.inputSending = true
        defer { owner.inputSending = false }
        do { try await input.send(phase: event.phase, gesture: event.gestureID, x: point.x, y: point.y, timestamp: event.timestamp) }
        catch { owner.retireInput(); throw AppleSimulatorError.connectionLost }
        guard owner.touchLease?.gesture == event.gestureID, owner.touchLease?.closing == false,
              owner.inputGeneration == event.generation else { throw AppleSimulatorError.connectionLost }
        if event.phase == .up || event.phase == .cancel {
            owner.touchLease = nil; owner.frame = nil; owner.publicRevision += 1; schedule()
        }
        return .object(["accepted": .bool(true), "sequence": .number(Double(event.sequence))])
    }

    func cancelInput(_ viewer: UUID, thread: String) async throws {
        guard let value = viewers[viewer], value.thread == thread else { throw AppleSimulatorError.noSession }
        guard value.owner.touchLease == nil || value.owner.touchLease?.viewer == viewer else { throw AppleSimulatorError.occupied }
        let owner = value.owner
        owner.retireInput()
        // The endpoint acknowledges cancellation only after actual process exit.
        for _ in 0..<120 {
            if owner.input == nil && owner.touchLease == nil { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw AppleSimulatorError.connectionLost
    }

    private func retireInput() {
        guard let input else { return }
        guard !inputRetiring else { return }
        inputRetiring = true
        inputGeneration = UUID()
        if touchLease != nil { touchLease?.closing = true }
        Task { [self] in
            await input.stop()
            guard input.stopped else { return } // An uncertain owner keeps the FIFO reserved.
            self.input = nil; inputRetiring = false
            if touchLease != nil { frame = nil; publicRevision += 1 }
            touchLease = nil; schedule()
            if stopped { await cleanupForExit() }
        }
    }

    // MARK: - Admission and shared execution

    func configuration(project: ProjectContext?) async throws -> BridgeValue {
        let developer = try await resolveDeveloper(project)
        guard project.map(accepts) ?? true else { throw BuildError.context }
        let version = Self.version(developer)
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let availability = AppleSimulatorAvailability.evaluate(selectedXcodeVersion: version, macOSMajor: system.majorVersion, macOSMinor: system.minorVersion, nativeToolsAvailable: driver != nil && ownerProject == project)
        let devices = Int(version.split(separator: ".").first ?? "0") ?? 0 >= 27 ? try await catalogue(developer) : []
        guard project.map(accepts) ?? true else { throw BuildError.context }
        return .object(["context": project.map { MimicIntegration.context($0, profile: currentProfile()) } ?? .null, "developer": .string(developer), "version": .string(version), "availability": .string(availability.rawValue), "devices": try BridgeValue.encode(devices.filter { $0.runtime.hasPrefix("iOS ") }), "deviceProfiles": SimulatorDeviceGeometry.profiles(devices: devices, developer: developer), "protocolVersion": .number(3), "capabilities": .object(["version": .number(3), "keys": .array([.string("backspace"), .string("return")]), "forwardDelete": .bool(false), "directInputReady": .bool(false), "geometry": .string("logical-points"), "adaptiveVideo": .bool(true)]), "recentIDs": .array(recentIDs(developer).map { .string($0.uuidString) }), "authorizationPending": .bool(accessPicker != nil), "authorizationError": accessError.map(BridgeValue.string) ?? .null, "workspaceAuthorized": .bool(accessWorkspace(developer: developer) != nil), "visible": .bool(Int(version.split(separator: ".").first ?? "0") ?? 0 >= 27), "state": metadata])
    }
    func submit(id: UUID, kind: SimulatorActivity.Kind, project: ProjectContext, device: UUID, sessionID: UUID? = nil, action: AppleSimulatorAction? = nil, revision: UInt64? = nil, appRequest: SimulatorAppRequest? = nil) async throws -> SimulatorActivity {
        guard !hasContinuousInput else { throw AppleSimulatorError.occupied }
        if !isChild {
            if let existing = children.values.first(where: { $0.activity(id) != nil }) { return try await existing.submit(id: id, kind: kind, project: project, device: device, sessionID: sessionID, action: action, revision: revision, appRequest: appRequest) }
            if let sessionID, let child = children.values.first(where: { $0.descriptor?.id == sessionID }) { return try await child.submit(id: id, kind: kind, project: project, device: device, sessionID: sessionID, action: action, revision: revision, appRequest: appRequest) }
            if kind == .start, descriptor != nil, descriptor?.deviceID != device {
                let child = childOwner(device: device, developer: try await resolveDeveloper(project))
                return try await child.submit(id: id, kind: kind, project: project, device: device)
            }
        }
        let admittedProfile = currentProfile()
        guard kind == .action ? action != nil && revision != nil : action == nil && revision == nil else { throw AppleSimulatorError.arguments }
        let isApp = kind == .launch || kind == .deeplink
        guard isApp == (appRequest != nil) else { throw BuildError.arguments }
        let fingerprint = isApp ? Data(HMAC<SHA256>.authenticationCode(for: try JSONEncoder().encode(appRequest), using: fingerprintKey)) : try requestFingerprint(action: action, revision: revision)
        if let existing = activity(id) {
            guard existing.kind == kind, existing.project == project, existing.deviceID == device, existing.sessionID == sessionID else { throw BuildError.duplicate }
            if kind == .action || isApp {
                // Legacy/restarted requests have no trusted payload identity: never assert success.
                guard fingerprints[id] == fingerprint else { throw BuildError.duplicate }
            }
            return existing
        }
        guard !storageUnavailable else { throw BuildError.unavailable }
        guard !stopped, mayAdmit(), (kind == .close ? (ownerProject == project || sharedView && accepts(project)) : accepts(project)) else { throw BuildError.context }
        try checkCapacity()
        if kind == .start {
            guard descriptor == nil, !localRecords.contains(where: { $0.kind == .start && $0.status.isPending }) else { throw AppleSimulatorError.occupied }
        } else {
            guard descriptor?.id == sessionID, descriptor?.deviceID == device, (ownerProject == project || sharedView && accepts(project)) else { throw AppleSimulatorError.noSession }
            if kind != .close { guard frame != nil, !localRecords.contains(where: { $0.status == .unknown && !$0.queueReleased }) else { throw AppleSimulatorError.connectionLost } }
        }
        if kind == .action { guard let action, revision == publicRevision else { throw AppleSimulatorError.arguments }; try frame?.validate(action) }
        let developer = kind == .close ? ownerDeveloper ?? (project.developerDirectory ?? "") : try await resolveDeveloper(project)
        if kind != .close { guard accepts(project), try await inspect(project) == project, mayAdmit(), !stopped else { throw BuildError.context } }
        guard kind == .close || supports(developer) else { throw AppleSimulatorError.unsupported }
        // Recheck after admission suspensions; another caller may have reserved this request or session.
        if activity(id) != nil { return try await submit(id: id, kind: kind, project: project, device: device, sessionID: sessionID, action: action, revision: revision, appRequest: appRequest) }
        if kind == .start { guard descriptor == nil, !localRecords.contains(where: { $0.kind == .start && $0.status.isPending }) else { throw AppleSimulatorError.occupied } }
        else { guard descriptor?.id == sessionID, ownerDeveloper == developer else { throw BuildError.context } }
        try checkCapacity()
        var record = SimulatorActivity(id: id, project: project, developer: developer, deviceID: device, sessionID: sessionID, kind: kind)
        record.profileID = admittedProfile?.id; record.profileRevision = admittedProfile?.revision
        record.observedRevision = revision
        localRecords.append(record); pending[id] = (action, revision); appRequests[id] = appRequest; fingerprints[id] = fingerprint
        do { try persist() } catch { localRecords.removeAll { $0.id == id }; ledger[id] = nil; pending[id] = nil; appRequests[id] = nil; fingerprints[id] = nil; throw error }
        schedule(); return localRecords.first { $0.id == id } ?? record
    }
    /// Includes evicted completed IDs so public lookup and duplicate admission stay idempotent.
    func activity(_ id: UUID) -> SimulatorActivity? { localRecords.first { $0.id == id } ?? ledger[id] ?? children.values.lazy.compactMap { $0.activity(id) }.first }
    private func checkCapacity() throws {
        guard localRecords.filter({ $0.status.isPending || $0.holdsQueue }).count < 100 else { throw BuildError.capacity }
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
        case let .key(value): components += ["key", value.rawValue]
        case .home: components += ["home"]
        case let .orientation(value): components += ["orientation", value.rawValue]
        case nil: components += ["none"]
        }
        return Data(HMAC<SHA256>.authenticationCode(for: try JSONEncoder().encode(components), using: fingerprintKey))
    }
    func start(_ record: SimulatorActivity) {
        if let child = children.values.first(where: { $0.localRecords.contains { $0.id == record.id } }) { child.start(record); return }
        guard !busy, !stopped, localRecords.first(where: { $0.id == record.id })?.status == .queued else { return }
        activeID = record.id; update(record.id, status: .preparing)
        Task {
            var nativeCallStarted = false
            do {
                if record.kind != .close && record.deviceOnly != true {
                    guard record.profileID == currentProfile()?.id, record.profileRevision == currentProfile()?.revision else { throw BuildError.context }
                    guard try await inspect(record.project) == record.project, accepts(record.project), try await resolveDeveloper(record.project) == record.developer else { throw BuildError.context }
                    let devices = try await catalogue(record.developer)
                    guard devices.contains(where: { $0.id == record.deviceID }), accepts(record.project), !stopped else { throw BuildError.context }
                }
                update(record.id, status: .running)
                try persist()
                if record.kind == .start {
                    let connection = makeDriver(); driver = connection
                    try await connection.connect(developerDirectory: record.developer)
                    let access = authorizationWorkspace ?? URL(fileURLWithPath: record.project.workspace)
                    try await connection.authorize(workspace: access)
                    guard record.deviceOnly == true || accepts(record.project), !stopped else { throw BuildError.context }
                    nativeCallStarted = true
                    descriptor = try await connection.startSession(deviceID: record.deviceID, workspace: sharedView ? nil : URL(fileURLWithPath: record.project.workspace))
                    publicRevision = 1
                    ownerProject = record.project; ownerDeveloper = record.developer
                    frame = try await connection.capture(try sessionID(record))
                    orientation = frame!.width > frame!.height ? "landscapeLeft" : "portrait"
                    heartbeatAt = now(); beginLease(); didUseDevice(record.deviceID, record.developer)
                } else {
                    let id = try sessionID(record)
                    guard let driver else { throw AppleSimulatorError.noSession }
                    if record.kind == .action {
                        guard let action = pending[record.id]?.0, let revision = pending[record.id]?.1, publicRevision == revision else { throw AppleSimulatorError.arguments }
                        try frame?.validate(action); let nativeRevision = frame!.revision; frame = nil; nativeCallStarted = true
                        if case .orientation = action {
                            inputGeneration = UUID()
                            if let input { await input.stop(); guard input.stopped else { throw AppleSimulatorError.connectionLost }; self.input = nil }
                        }
                        frame = try await driver.perform(id, action: action, revision: nativeRevision); publicRevision += 1
                        if case let .orientation(value) = action { orientation = value.rawValue; video?.orientation(value.rawValue) }
                    } else if record.kind == .launch || record.kind == .deeplink {
                        guard let app = appRequests[record.id] else { throw BuildError.context }
                        let revision = try await Task.detached { try SourceRevisionReader.capture(path: record.project.path, exclusions: app.exclusions) }.value
                        guard revision == app.revision, accepts(record.project), !stopped else { throw BuildError.sourceChanged }
                        var arguments: [[String]] = []
                        if record.kind == .launch {
                            guard let artifact = app.artifact, let root = app.artifactRoot else { throw BuildError.context }
                            let currentArtifact = try await Task.detached { try ManagedArtifactReader.inspect(URL(fileURLWithPath: artifact.path), root: URL(fileURLWithPath: root)) }.value
                            guard currentArtifact == artifact, !stopped, accepts(record.project) else { throw BuildError.sourceChanged }
                            guard let product = app.product, product.path == artifact.path, app.deeplink == nil,
                                  let data = try? Data(contentsOf: URL(fileURLWithPath: product.path).appendingPathComponent("Info.plist")),
                                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], plist["CFBundleIdentifier"] as? String == product.bundleIdentifier else { throw BuildError.configuration }
                            arguments = [["simctl", "install", record.deviceID.uuidString, product.path], ["simctl", "launch", record.deviceID.uuidString, product.bundleIdentifier]]
                        } else {
                            guard app.product == nil, let url = app.deeplink else { throw BuildError.arguments }
                            arguments = [["simctl", "openurl", record.deviceID.uuidString, url]]
                        }
                        frame = nil; nativeCallStarted = true
                        let developer = record.developer
                        for command in arguments {
                            let result = await Task.detached { EnvironmentInspector.boundedCapture("/usr/bin/xcrun", command, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer, "LANG": "en_US.UTF-8"], timeout: 30, maximumBytes: 64 * 1024) }.value
                            guard result.0 == 0 else { throw AppleSimulatorError.connectionLost }
                        }
                        frame = try await driver.capture(id); publicRevision += 1
                    } else if record.kind == .install {
                        try await validateInstallContext(record)
                        let workspace = URL(fileURLWithPath: record.project.workspace)
                        if descriptor?.workspace?.resolvingSymlinksInPath() != workspace.resolvingSymlinksInPath() {
                            try await driver.authorize(workspace: workspace)
                            try await validateInstallContext(record)
                            frame = nil; nativeCallStarted = true
                            try await driver.close(id)
                            descriptor = try await driver.startSession(deviceID: record.deviceID, workspace: workspace)
                        }
                        try await validateInstallContext(record)
                        let installID = try sessionID(record, allowReplacement: true)
                        frame = nil; nativeCallStarted = true
                        try await driver.install(installID); frame = try await driver.capture(installID); publicRevision += 1
                    } else if record.kind == .refresh {
                        frame = nil; nativeCallStarted = true; frame = try await driver.capture(id)
                    } else {
                        nativeCallStarted = true; try await driver.close(id); await driver.disconnect(); clearSession()
                    }
                }
                update(record.id, status: .succeeded)
            } catch {
                if nativeCallStarted { frame = nil }
                if record.kind == .close {
                    // Closing only retires this connection. Once disconnected, it cannot
                    // own the FIFO; an uncertain device command still requires release.
                    await driver?.disconnect(); clearSession()
                    update(record.id, status: .failed, error: "connectionLost")
                } else {
                    update(record.id, status: nativeCallStarted ? .unknown : .failed, error: nativeCallStarted ? "connectionLost" : error is BuildError ? "context" : "requiresNativeAccess")
                }
                if descriptor == nil { await driver?.disconnect(); driver = nil }
            }
            if let index = localRecords.firstIndex(where: { $0.id == record.id }), frame != nil { localRecords[index].resultRevision = publicRevision }
            if let completed = activity(record.id) { onAgentOperation(completed) }
            appRequests[record.id] = nil
            pending[record.id] = nil; activeID = nil; try? persist(); schedule()
            if stopped { await cleanupForExit() }
        }
    }
    /// Authorization and replacement of an Apple session can suspend while the chat/profile changes.
    private func validateInstallContext(_ record: SimulatorActivity) async throws {
        guard try await inspect(record.project) == record.project,
              try await resolveDeveloper(record.project) == record.developer,
              record.profileID == currentProfile()?.id, record.profileRevision == currentProfile()?.revision,
              accepts(record.project), !stopped else { throw BuildError.context }
    }
    private func sessionID(_ record: SimulatorActivity, allowReplacement: Bool = false) throws -> UUID {
        guard let descriptor, descriptor.deviceID == record.deviceID, allowReplacement || record.sessionID == nil || record.sessionID == descriptor.id else { throw AppleSimulatorError.noSession }; return descriptor.id
    }

    // MARK: - Private observation and lifecycle

    func observation(sessionID: UUID) throws -> BridgeValue {
        if let child = children.values.first(where: { $0.descriptor?.id == sessionID }) { return try child.observation(sessionID: sessionID) }
        guard descriptor?.id == sessionID, let frame, !busy else { throw AppleSimulatorError.occupied }; heartbeatAt = now(); var payload = frame.payload.object ?? [:]; payload["revision"] = .number(Double(publicRevision)); return .object(payload)
    }
    func heartbeat(_ id: UUID) throws { if let child = children.values.first(where: { $0.descriptor?.id == id }) { try child.heartbeat(id); return }; guard descriptor?.id == id else { throw AppleSimulatorError.noSession }; heartbeatAt = now() }
    /// A human checks Xcode first, then explicitly releases an uncertain operation. No native mutation is replayed.
    func releaseUnknown(_ id: UUID) async throws {
        if let child = children.values.first(where: { $0.activity(id) != nil }) { try await child.releaseUnknown(id); return }
        guard activeID == nil, let index = localRecords.firstIndex(where: { $0.id == id && $0.status == .unknown && !$0.queueReleased }) else { throw AppleSimulatorError.arguments }
        if let descriptor, let driver { try await driver.close(descriptor.id) }
        await driver?.disconnect(); clearSession(); localRecords[index].queueReleased = true; try persist(); schedule()
    }
    func stop() {
        retireInput()
        stopped = true; accessPicker?.cancel(nil); accessPicker = nil; leaseTimer?.cancel(); viewerTimer?.cancel(); video?.stop(); for child in children.values { child.stop() }
        for index in localRecords.indices where localRecords[index].status == .queued { localRecords[index].status = .cancelled; pending[localRecords[index].id] = nil }
        try? persist(); Task { await cleanupForExit() }
    }
    private func cleanupForExit() async {
        guard activeID == nil, !reading, touchLease == nil, !inputStarting else { return }
        reading = true
        if !localRecords.contains(where: { $0.kind == .close && $0.status == .unknown && !$0.queueReleased }), let descriptor, let driver, let project = ownerProject, let developer = ownerDeveloper {
            var closing = SimulatorActivity(id: UUID(), project: project, developer: developer, deviceID: descriptor.deviceID, sessionID: descriptor.id, kind: .close)
            closing.status = .running; localRecords.append(closing)
            do { try persist(); try await driver.close(descriptor.id); update(closing.id, status: .succeeded) }
            catch { update(closing.id, status: .failed, error: "connectionLost") }
        }
        await driver?.disconnect(); clearSession(); reading = false; schedule()
    }
    private func beginLease() {
        leaseTimer?.cancel()
        leaseTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, let descriptor = self.descriptor else { return }
                _ = descriptor
                await self.expireIdleSessions()
                if self.localRecords.contains(where: { $0.kind == .close && $0.status.isPending }) { return }
            }
        }
    }
    /// Recording shares the existing native video ingress and keeps it visible without a panel.
    func beginAgentRecording(session: UUID, path: URL) async throws {
        guard let owner = sessionOwner(session), let descriptor = owner.descriptor, let developer = owner.ownerDeveloper, owner.video?.recording == nil else { throw AppleSimulatorError.noSession }
        if owner.video == nil { owner.video = SimulatorVideo() }
        await owner.video?.start(device: descriptor.deviceID, developer: developer)
        guard owner.descriptor?.id == session, owner.video?.isRunning == true else { throw AppleSimulatorError.connectionLost }
        owner.video?.recording = SimulatorRecording(path: path); owner.video?.requestRecordingKeyframe(); owner.video?.visibility(true)
    }
    func finishAgentRecording(session: UUID) async throws -> SimulatorRecordingResult {
        if let owner = sessionOwner(session), let recording = owner.video?.recording {
            owner.video?.recording = nil
            let result = await recording.finish(); owner.completedRecordings[session] = result
            updateVideoVisibility(owner); return result
        }
        if let result = completedRecordings[session] ?? children.values.compactMap({ $0.completedRecordings[session] }).first { return result }
        throw AppleSimulatorError.noSession
    }
    private func clearSession() {
        if let id = descriptor?.id {
            onAgentSessionClosed(id)
            if let recording = video?.recording {
                video?.recording = nil
                Task { completedRecordings[id] = await recording.finish(interrupted: true) }
            }
        }
        retireInput(); video?.stop(); video = nil; descriptor = nil; frame = nil; driver = nil; ownerProject = nil; ownerDeveloper = nil; leaseTimer?.cancel(); leaseTimer = nil
    }
    private func update(_ id: UUID, status: BuildStatus, error: String? = nil) { if let index = localRecords.firstIndex(where: { $0.id == id }) { localRecords[index].status = status; localRecords[index].errorCode = error; try? persist() } }
    private func persist() throws {
        guard !storageUnavailable else { throw BuildError.unavailable }
        var updated = ledger
        for record in localRecords { updated[record.id] = record }
        let ordered = updated.values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Commit the complete replay ledger before evicting anything from the presentation.
        try JSONEncoder().encode(ordered).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        ledger = updated; localRecords = Self.retained(ordered)
    }
    private func resolveDeveloper(_ project: ProjectContext?) async throws -> String {
        if let developer = project?.developerDirectory { return developer }
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
