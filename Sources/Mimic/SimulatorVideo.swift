//
//  SimulatorVideo.swift
//  Mimic
//
//  Created by Василий Маслов on 07.10.2026.
import Foundation
import MimicCore

/// Owns only a capture helper. Frames and capability tokens are never persisted or sent to model context.
@MainActor final class SimulatorVideo {
    private static var stopping: [ObjectIdentifier: Process] = [:]
    static var canExit: Bool { stopping.values.allSatisfy { !$0.isRunning } }
    var onExit: @MainActor @Sendable () -> Void = {}
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var buffer = Data(), diagnosticBuffer = Data()
    private var packets = SimulatorVideoPackets()
    private var grants: [UUID: String] = [:]
    private var sizes: [UUID: (width: Int, height: Int)] = [:]
    private var visibleViewers = Set<UUID>()
    private var resizeTask: Task<Void, Never>?
    func size(_ viewer: UUID, width: Int, height: Int) {
        sizes[viewer] = (width, height); scheduleSize()
    }
    func viewerVisible(_ viewer: UUID, _ visible: Bool) {
        if visible { visibleViewers.insert(viewer) } else { visibleViewers.remove(viewer) }
        scheduleSize()
    }
    /// Debounce shared-view resize storms. The helper caps this request to its source framebuffer.
    private func scheduleSize() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let values = self.sizes.filter { self.visibleViewers.contains($0.key) }.values
            if let width = values.map(\.width).max(), let height = values.map(\.height).max() { self.send(["width": width, "height": height]) }
        }
    }
    private(set) var port: UInt16?
    private(set) var error: String?
    private var starting = false
    private var generation = UUID()
    var isRunning: Bool { process?.isRunning == true && port != nil && error == nil }

    func start(device: UUID, developer: String) async {
        // Concurrent viewers await one startup rather than misreading a not-yet-ready port as failure.
        if starting {
            let generation = generation
            for _ in 0..<150 {
                if !starting || generation != self.generation { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return
        }
        guard process == nil else { return }
        starting = true; defer { starting = false }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SimulatorVideoHost")
        #if DEBUG
        let executable = FileManager.default.isExecutableFile(atPath: helper.path) ? helper : URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("SimulatorVideoHost")
        #else
        let executable = helper
        #endif
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { error = "videoHelperUnavailable"; return }
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable; process.arguments = [device.uuidString, developer]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let generation = UUID(); self.generation = generation
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; diagnostics = stderr.fileHandleForReading; error = nil
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in guard let self, self.generation == generation else { return }; self.receive(data) }
        }
        diagnostics?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in guard let self, self.generation == generation else { return }; self.receiveDiagnostic(data) }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in guard let self, self.generation == generation else { return }; self.error = self.error ?? "videoDisconnected"; self.port = nil } }
        do { try process.run() } catch { self.error = "videoHelperUnavailable"; stop(); return }
        for _ in 0..<150 {
            if port != nil || error != nil || !process.isRunning { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        error = "videoStartupTimeout"; stop()
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { output?.readabilityHandler = nil; return }
        guard buffer.count + data.count <= 2_000_000 else { error = "videoPacketInvalid"; stop(); return }
        buffer.append(data)
        while buffer.count >= 4 {
            let count = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard count >= 27, count <= 512_000 else { error = "videoPacketInvalid"; stop(); return }
            guard buffer.count >= count + 4 else { return }
            let packet = Data(buffer.dropFirst(4).prefix(count)); buffer.removeFirst(count + 4)
            let sequence = packet[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            packets.append(sequence: sequence, data: packet, keyframe: packet[0] == 1)
        }
    }
    private func receiveDiagnostic(_ data: Data) {
        guard !data.isEmpty else { diagnostics?.readabilityHandler = nil; return }
        guard diagnosticBuffer.count + data.count <= 16_384 else { error = "videoPacketInvalid"; stop(); return }
        diagnosticBuffer.append(data)
        while let index = diagnosticBuffer.firstIndex(of: 10) {
            let line = diagnosticBuffer.prefix(upTo: index); diagnosticBuffer.removeSubrange(...index)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if value["ready"] as? Bool == true, let port = value["port"] as? UInt16 { self.port = port }
            if let code = value["error"] as? String { error = String(code.prefix(64)) }
        }
    }
    private func send(_ value: [String: Any]) { guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }; try? input?.write(contentsOf: data + Data([10])) }
    func visibility(_ visible: Bool) { send(["enabled": visible]) }
    func orientation(_ value: String) { send(["orientation": value]) }
    func grant(_ viewer: UUID) -> BridgeValue {
        guard isRunning, let port else { return .object(["mode": .string("snapshots"), "reason": .string(error ?? "videoUnavailable")]) }
        // Replacing a grant invalidates both late polls and sockets from the previous stream.
        if let old = grants[viewer] { packets.removeReservation(old); send(["revoke": old]) }
        let token = (0..<32).map { _ in UInt8.random(in: .min ... .max) }.map { String(format: "%02x", $0) }.joined()
        grants[viewer] = token; packets.beginReservation(token); send(["grant": token]); send(["keyframe": true])
        return .object(["mode": .string("video"), "url": .string("ws://127.0.0.1:\(port)"), "token": .string(token), "protocolVersion": .number(1)])
    }
    func renew(_ viewer: UUID) { if let token = grants[viewer] { send(["grant": token]) } }
    func revoke(_ viewer: UUID) { sizes[viewer] = nil; visibleViewers.remove(viewer); scheduleSize(); if let token = grants.removeValue(forKey: viewer) { packets.removeReservation(token); send(["revoke": token]) } }
    /// Bounded alternate transport for the live comparison. A missing GOP always resumes from an IDR.
    func poll(viewer: UUID, after: UInt64, token: String?) throws -> BridgeValue {
        guard let grant = grants[viewer], token == nil || token == grant else { throw AppleSimulatorError.noSession }
        let batch = packets.read(after: after, reservation: token)
        if batch.needsKeyframe { send(["keyframe": true]) }
        return .object(["packets": .array(batch.packets.map(BridgeValue.string)), "serverMicros": .number(Double(DispatchTime.now().uptimeNanoseconds / 1000))])
    }
    func stop() {
        resizeTask?.cancel(); resizeTask = nil; sizes = [:]; visibleViewers = []; generation = UUID(); output?.readabilityHandler = nil; diagnostics?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? diagnostics?.close()
        if let process, process.isRunning {
            let id = ObjectIdentifier(process), onExit = onExit
            Self.stopping[id] = process
            process.terminationHandler = { _ in Task { @MainActor in Self.stopping[id] = nil; onExit() } }
            process.terminate()
        }
        process = nil; input = nil; output = nil; diagnostics = nil; port = nil; buffer = Data(); diagnosticBuffer = Data(); packets = SimulatorVideoPackets(); grants = [:]
    }
}
