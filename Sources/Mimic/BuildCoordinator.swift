//
//  BuildCoordinator.swift
//  Mimic
//
//  Created by Василий Маслов on 04.10.2026.
import AppKit
import Combine
import Foundation
import MimicCore
import os

/// Build execution outlives every observer. TaskCoordinator admits it to the same global queue.
@MainActor final class BuildCoordinator: ObservableObject {
    @Published private(set) var records: [BuildActivity] = []
    @Published var draft = BuildParameters()
    @Published private(set) var catalogue = BuildCatalogue()
    @Published private(set) var loading = false
    @Published var message = ""
    @Published var pinned = false
    @Published var selectedID: UUID?
    @Published private(set) var revision = UUID()
    @Published var xcodeSimulatorConfirmed = false
    let xcode = XcodeBuildConnection()
    private let store: BuildHistoryStore
    private let helper: URL
    private let defaults: UserDefaults
    private let inspect: @Sendable (ProjectContext) async throws -> ProjectContext
    private let resolveDeveloper: @Sendable (ProjectContext) async throws -> String
    private let makeCommand: @Sendable (BuildActivity, String?) throws -> CommandSpec
    private let discover: @Sendable (ProjectContext, String, Bool, String?, String?) async throws -> BuildCatalogue
    private var outputs: [UUID: BuildOutput] = [:]
    private var savedTails: [UUID: [String]] = [:]
    private var workers: [UUID: BuildOutputWorker] = [:]
    private var logTruncation = Set<UUID>()
    private var ledger: [String: Admission] = [:]
    private var session: PTYSession?
    private var preparation: Task<Void, Never>?
    private var updateTimer: Task<Void, Never>?
    private var launchID: UUID?
    private var catalogueRevision = UUID()
    private var catalogueContext: ProjectContext?
    private var catalogueScheme = ""
    private var stopped = false
    private var draftKey: String?
    private var renderBatch = Data()
    private let signposter = OSSignposter(subsystem: "local.vmaslov.Mimic", category: "BuildOutput")
    var schedule: () -> Void = { }
    var currentProject: () -> ProjectContext? = { nil }
    /// Additional registered chat contexts may enter the same FIFO without changing desktop selection.
    var currentProfile: () -> ProfileSnapshot? = { nil }
    var acceptsProject: (ProjectContext) -> Bool = { _ in false }
    private func accepts(_ project: ProjectContext) -> Bool { currentProject() == project || acceptsProject(project) }
    var mayAdmit: () -> Bool = { true }
    var showResult: (UUID) -> Void = { _ in }
    var terminalOutput: ((UUID, Data) -> Void)?
    private var terminalOwner: UUID?
    struct Admission: Codable { let project: ProjectContext; let parameters: BuildParameters; let source: String; var record: BuildActivity? = nil }

    init(directory: URL, helper: URL, defaults: UserDefaults, inspect: @escaping @Sendable (ProjectContext) async throws -> ProjectContext = { project in
        try await Task.detached { try EnvironmentInspector.project(path: project.path, developerDirectory: project.developerDirectory, appleTarget: project.appleTarget) }.value
    }, resolveDeveloper: @escaping @Sendable (ProjectContext) async throws -> String = { project in
        let directory: String
        if let selected = project.developerDirectory { directory = selected } else { directory = await Task.detached { EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1 }.value }
        guard !directory.isEmpty else { throw BuildError.configuration }; return directory
    }, makeCommand: @escaping @Sendable (BuildActivity, String?) throws -> CommandSpec = { record, resultPath in
        var project = record.project; project.developerDirectory = record.selectedDeveloperDirectory
        return try record.parameters.command(project: project, resultBundlePath: resultPath)
    }, discover: @escaping @Sendable (ProjectContext, String, Bool, String?, String?) async throws -> BuildCatalogue = { project, scheme, tests, profileID, profileRevision in
        try await BuildDiscovery.shared.catalogue(project: project, scheme: scheme, includeTestPlans: tests, profileID: profileID, profileRevision: profileRevision)
    }) {
        self.store = BuildHistoryStore(directory: directory); self.helper = helper; self.defaults = defaults; self.inspect = inspect; self.discover = discover; self.resolveDeveloper = resolveDeveloper; self.makeCommand = makeCommand
        do {
            records = try store.load(); try store.save(records)
            let path = store.directory.appendingPathComponent("requests.json")
            if FileManager.default.fileExists(atPath: path.path) { ledger = try JSONDecoder().decode([String: Admission].self, from: Data(contentsOf: path)) }
        } catch { message = text("history.error") }
    }
    /// Preflight awaits happen before a queued record exists; development replacement must wait for them too.
    @Published private(set) var admittingCount = 0
    var busy: Bool { launchID != nil || records.contains { $0.status == .unknown && $0.queueReleased != true } }
    var hasPending: Bool { busy || records.contains { $0.status.isPending } }
    var next: BuildActivity? { records.filter { $0.status == .queued }.min { $0.createdAt < $1.createdAt } }
    var active: BuildActivity? { records.first { $0.id == launchID } }
    var pendingCount: Int { records.filter { $0.status == .queued }.count }
    var overlayActivity: BuildActivity? { if let active, active.startedAt != nil { return active }; return records.last { $0.startedAt != nil } }
    var selected: BuildActivity? { records.first { $0.id == selectedID } }
    func lastLines(_ id: UUID) -> [String] {
        let interval = signposter.beginInterval("Tail")
        defer { signposter.endInterval("Tail", interval) }
        if let output = outputs[id] { return output.lastLines }
        if let tail = savedTails[id] { return tail }
        let tail = BuildOutput.savedTail(output(id))
        savedTails[id] = tail; return tail
    }
    func output(_ id: UUID) -> Data {
        if let output = outputs[id] { return output.bytes }
        guard let handle = FileHandle(forReadingAtPath: store.logURL(id).path) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        let bytes = (try? handle.readToEnd()) ?? Data()
        return Data(BuildOutput.slice(bytes, after: 0, limit: bytes.count).text.utf8)
    }

    // MARK: - Configuration and admission

    func refreshCatalogue(project: ProjectContext, scheme: String? = nil) async {
        let token = UUID(), profile = currentProfile(); catalogueRevision = token; loading = true; message = ""
        defer { if catalogueRevision == token { loading = false } }
        do {
            let developer = try await resolveDeveloper(project)
            let key = "build.configuration." + project.path + "|" + developer
            guard catalogueRevision == token, currentProject() == project, currentProfile() == profile else { return }
            if draftKey != key {
                draftKey = key
                draft = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BuildParameters.self, from: $0) } ?? .init()
            }
            let chosen = scheme ?? draft.scheme
            var captured = project; captured.developerDirectory = developer
            let result = try await discover(captured, chosen, draft.operation == .test, profile?.id, profile?.revision)
            guard catalogueRevision == token, currentProject() == project, currentProfile() == profile else { return }
            catalogue = result; catalogueContext = project; catalogueScheme = chosen
            if !result.schemes.contains(draft.scheme) { draft.scheme = "" }
            if !result.configurations.contains(draft.configuration) { draft.configuration = result.configurations.contains("Debug") ? "Debug" : "" }
            if !result.destinations.contains(where: { $0.id == draft.destinationID }) { draft.destinationID = "" }
            if !result.testPlans.contains(draft.testPlan) { draft.testPlan = "" }
        } catch { if catalogueRevision == token { message = text("build.error." + ((error as? BuildError)?.rawValue ?? "catalogue")); catalogue = .init(); catalogueContext = nil } }
        if catalogueRevision == token { loading = false }
    }
    func restoreDraft(project: ProjectContext) async {
        catalogueRevision = UUID(); loading = false; catalogueContext = nil; catalogue = .init(); xcodeSimulatorConfirmed = false
        guard let developer = try? await resolveDeveloper(project), currentProject() == project else { return }
        let key = "build.configuration." + project.path + "|" + developer; draftKey = key
        draft = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BuildParameters.self, from: $0) } ?? .init()
    }
    func saveDraft(project: ProjectContext) {
        guard currentProject() == project, let key = draftKey else { return }
        defaults.set(try? JSONEncoder().encode(draft), forKey: key)
    }
    func submitDraft() {
        guard let project = currentProject() else { return }
        var parameters = draft
        parameters.platform = catalogue.destinations.first(where: { $0.id == parameters.destinationID })?.platform
        if parameters.backend == .xcodeMCP { parameters.scheme = ""; parameters.configuration = ""; parameters.destinationID = ""; parameters.testPlan = "" }
        if parameters.operation == .build { parameters.testIdentifiers = []; parameters.testPlan = "" }
        saveDraft(project: project)
        Task {
            do { let record = try await submit(id: UUID(), project: project, parameters: parameters, source: "Mimic", simulatorConfirmed: xcodeSimulatorConfirmed); showResult(record.id) }
            catch { message = text("build.error." + ((error as? BuildError)?.rawValue ?? "unavailable")) }
        }
    }
    /// Ledger survives history eviction. A known ID can never start a second operation.
    func submit(id: UUID, project: ProjectContext, parameters: BuildParameters, source: String, simulatorConfirmed: Bool = false) async throws -> BuildActivity {
        let admittedProfile = currentProfile()
        self.admittingCount += 1
        defer { self.admittingCount -= 1 }
        try parameters.validate()
        guard parameters.backend != .cli || !simulatorConfirmed else { throw BuildError.arguments }
        if let admission = ledger[id.uuidString] {
            guard admission.project == project, admission.parameters == parameters else { throw BuildError.duplicate }
            guard let record = records.first(where: { $0.id == id }) ?? admission.record else { throw BuildError.stopped }; return record
        }
        guard !stopped, mayAdmit(), accepts(project) else { throw BuildError.context }
        let actual = try await inspect(project)
        let developer = try await resolveDeveloper(project)
        guard actual == project, accepts(project), mayAdmit(), !stopped else { throw BuildError.context }
        // Re-check after suspension: simultaneous callers may already have admitted this ID.
        if ledger[id.uuidString] != nil { return try await submit(id: id, project: project, parameters: parameters, source: source, simulatorConfirmed: simulatorConfirmed) }
        guard ledger.count < 10_000, pendingCount < 100 else { throw BuildError.capacity }
        if parameters.backend == .xcodeMCP {
            guard simulatorConfirmed, xcode.supports(parameters.operation), xcode.hasWorkspace(parameters.workspaceTab, path: project.workspace), xcode.project == project else { throw BuildError.configuration }
        }
        var record = BuildActivity(id: id, project: project, parameters: parameters, source: source)
        record.selectedDeveloperDirectory = developer; record.profileID = admittedProfile?.id; record.profileRevision = admittedProfile?.revision
        ledger[id.uuidString] = Admission(project: project, parameters: parameters, source: source, record: record)
        do {
            let path = store.directory.appendingPathComponent("requests.json")
            try JSONEncoder().encode(ledger).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch { ledger[id.uuidString] = nil; throw error }
        records.append(record)
        do { try store.save(records) } catch {
            records.removeAll { $0.id == id }; ledger[id.uuidString] = nil
            try? JSONEncoder().encode(ledger).write(to: store.directory.appendingPathComponent("requests.json"), options: .atomic)
            throw error
        }
        schedule(); return records.first { $0.id == id } ?? record
    }

    // MARK: - Execution

    func start(_ record: BuildActivity) {
        guard !busy, !stopped, record.status == .queued else { return }
        launchID = record.id; update(record.id) { $0.status = .preparing; $0.phase = "build.phase.preparing" }; persist()
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let actual = try await inspect(record.project)
                let developer = try await resolveDeveloper(record.project)
                guard !Task.isCancelled, launchID == record.id else { return }
                guard actual == record.project, accepts(record.project), developer == record.selectedDeveloperDirectory else { throw BuildError.context }
                if record.parameters.backend == .cli {
                    var captured = record.project; captured.developerDirectory = record.selectedDeveloperDirectory
                    let catalog = try await discover(captured, record.parameters.scheme, record.parameters.operation == .test, record.profileID, record.profileRevision)
                    guard !Task.isCancelled, launchID == record.id else { return }
                    try catalog.validate(record.parameters)
                    try await verifyStartContext(record)
                    try await launchCLI(record)
                } else { try await launchXcode(record) }
            } catch {
                guard launchID == record.id else { return }
                let started = records.first { $0.id == record.id }?.startedAt != nil
                let status: BuildStatus = Task.isCancelled && !started ? .cancelled : started && record.parameters.backend == .xcodeMCP ? .unknown : .failed
                await finish(record.id, status: status, error: status == .cancelled ? nil : (error as? BuildError)?.rawValue ?? "unavailable")
            }
        }
    }
    private func verifyStartContext(_ record: BuildActivity) async throws {
        let actual = try await inspect(record.project)
        let developer = try await resolveDeveloper(record.project)
        guard !Task.isCancelled, launchID == record.id, actual == record.project, accepts(record.project), developer == record.selectedDeveloperDirectory else { throw BuildError.context }
    }
    private func begin(_ record: BuildActivity) async throws {
        outputs[record.id] = BuildOutput()
        let worker = BuildOutputWorker()
        try await worker.open(store.logURL(record.id))
        guard launchID == record.id, !Task.isCancelled else { throw CancellationError() }
        workers[record.id] = worker
        update(record.id) { $0.status = .running; $0.startedAt = Date(); $0.phase = "build.phase.running" }; persist()
    }
    private func launchCLI(_ record: BuildActivity) async throws {
        let resultPath = record.parameters.operation == .test ? store.directory.appendingPathComponent(record.id.uuidString + ".xcresult").path : nil
        let command = try makeCommand(record, resultPath)
        try await begin(record)
        let runner = PTYSession(); session = runner
        runner.onOutputAsync = { [weak self] in await self?.consume(record.id, bytes: $0) }
        runner.onCompletion = { [weak self] event in
            guard let self else { return }
            Task {
            update(record.id) { $0.exitCode = event?.code; $0.signal = event?.signal; if let resultPath, FileManager.default.fileExists(atPath: resultPath) { $0.resultBundlePath = resultPath } }
            let status: BuildStatus = event?.cancelled == true ? .cancelled : event?.code == 0 && event?.signal == 0 && event?.launchError == 0 ? .succeeded : .failed
            await finish(record.id, status: status)
            }
        }
        try runner.start(helper: helper, command: command)
    }
    private func launchXcode(_ record: BuildActivity) async throws {
        try await xcode.refreshWindows()
        try await verifyStartContext(record)
        guard xcode.project == record.project, xcode.developerDirectory == record.selectedDeveloperDirectory, xcode.hasWorkspace(record.parameters.workspaceTab, path: record.project.workspace), xcode.supports(record.parameters.operation) else { throw BuildError.configuration }
        try await begin(record)
        update(record.id) { $0.tracking = .unavailable }
        let result = try await xcode.run(record, requestStarted: { [weak self] requestID in self?.update(record.id) { $0.xcodeRequestID = requestID }; self?.persist() }, progress: { [weak self] message in
            guard let self, self.launchID == record.id else { return }
            if self.active?.tracking != .live { update(record.id) { $0.tracking = .live } }
            await consume(record.id, bytes: Data((message + "\n").utf8))
        })
        await consume(record.id, bytes: Data((result.text + "\n").utf8))
        update(record.id) { $0.errorCount = result.errors; $0.warningCount = result.warnings; $0.resultSummaryPath = result.summaryPath; $0.truncated = result.truncated }
        await finish(record.id, status: result.status)
    }
    private func consume(_ id: UUID, bytes: Data, final: Bool = false) async {
        guard let worker = workers[id] else { return }
        let prompt = String(decoding: bytes.suffix(4096), as: UTF8.self)
        if prompt.range(of: #"(?i)(?:password|passphrase|verification code|enter[^\n]{0,80}|\[y/n\]|\(y/n\))[:? >]\s*$"#, options: .regularExpression) != nil { update(id) { $0.needsInput = true } }
        // Pipe chunks are <=64 KiB. Large MCP results are sliced before UI delivery.
        var offset = 0
        repeat {
            let end = min(bytes.count, offset + 64 * 1024)
            let batch = await worker.append(Data(bytes[offset..<end]), final: final && end == bytes.count)
            guard launchID == id else { return }
            outputs[id] = batch.output
            if batch.logTruncated { logTruncation.insert(id) }
            if batch.logFailed { message = text("log.error") }
            renderBatch.append(batch.emitted)
            if renderBatch.count > 512 * 1024 {
                let tail = BuildOutput.slice(renderBatch, after: renderBatch.count - 512 * 1024, limit: 512 * 1024)
                renderBatch = Data(tail.text.utf8); logTruncation.insert(id)
            }
            if updateTimer == nil {
                updateTimer = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.launchID == id else { return }
                    self.deliverOutput(id)
                    if let phase = self.outputs[id]?.phase, self.active?.phase != "build.phase." + phase {
                        self.signposter.emitEvent("PhaseChanged")
                        self.update(id) { $0.phase = "build.phase." + phase }
                    }
                    self.revision = UUID(); self.updateTimer = nil
                }
            }
            offset = end
        } while offset < bytes.count
    }
    private func deliverOutput(_ id: UUID) {
        let interval = signposter.beginInterval("UIBatch")
        defer { signposter.endInterval("UIBatch", interval) }
        var cursor = 0
        while cursor < renderBatch.count {
            let slice = BuildOutput.slice(renderBatch, after: cursor)
            terminalOutput?(id, Data(slice.text.utf8)); cursor = slice.nextCursor
        }
        renderBatch.removeAll(keepingCapacity: true)
    }
    private func finish(_ id: UUID, status: BuildStatus, error: String? = nil) async {
        guard launchID == id else { return }
        await consume(id, bytes: Data(), final: true)
        guard launchID == id else { return }
        updateTimer?.cancel(); updateTimer = nil
        deliverOutput(id)
        let truncated = logTruncation.contains(id) || outputs[id]?.truncated == true || records.first { $0.id == id }?.truncated == true
        workers[id] = nil; logTruncation.remove(id); session = nil; launchID = nil; preparation = nil
        update(id) {
            $0.status = status; $0.finishedAt = Date(); $0.errorCode = error; $0.truncated = truncated; $0.needsInput = false
            $0.phase = "build.phase." + status.rawValue
            if status == .unknown { $0.tracking = .lost }
        }
        let ids = Set(records.suffix(8).map(\.id)); outputs = outputs.filter { ids.contains($0.key) }
        if records.first(where: { $0.id == id })?.hasPrivateInput == true { outputs[id] = nil; savedTails[id] = nil }
        revision = UUID(); persist(); schedule()
    }
    func cancel(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }), record.canCancel else { return }
        if record.status == .queued { update(id) { $0.status = .cancelled; $0.finishedAt = Date() }; persist(); schedule() }
        else if record.status == .preparing {
            preparation?.cancel(); Task { await finish(id, status: .cancelled) }
        } else { session?.cancel() }
    }
    /// Explicit acknowledgement releases an uncertain operation; it never asserts that Xcode stopped.
    func acknowledgeUnknown(_ id: UUID) {
        guard records.first(where: { $0.id == id })?.status == .unknown else { return }
        update(id) { $0.queueReleased = true }; persist(); schedule()
    }
    func stop() {
        stopped = true
        for record in records where record.status == .queued { cancel(record.id) }
        if let active, active.canCancel { cancel(active.id) }
    }
    private func update(_ id: UUID, _ mutate: (inout BuildActivity) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }; mutate(&records[index])
    }
    private func persist() {
        savedTails = savedTails.filter { id, _ in records.contains { $0.id == id } }
        let live = records.filter { $0.status.isPending || $0.status == .unknown }
        let completed = records.filter { !$0.status.isPending && $0.status != .unknown }.suffix(100)
        records = (Array(completed) + live).sorted { $0.createdAt < $1.createdAt }
        for record in records { ledger[record.id.uuidString]?.record = record }
        do {
            try store.save(records)
            try JSONEncoder().encode(ledger).write(to: store.directory.appendingPathComponent("requests.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.directory.appendingPathComponent("requests.json").path)
        } catch { message = text("history.error") }
    }

    // MARK: - Independent observers and diagnostic review

    func canInput(_ id: UUID) -> Bool { launchID == id && session != nil && active?.status == .running }
    func privateInput(_ id: UUID, bytes: Data) async throws {
        guard canInput(id), let worker = workers[id] else { throw BuildError.notFound }
        try await worker.makePrivate()
        guard canInput(id) else { throw BuildError.stopped }
        update(id) { $0.hasPrivateInput = true; $0.needsInput = false }; persist()
        session?.send(bytes)
    }
    func resize(_ id: UUID, columns: Int, rows: Int) { if canInput(id) { session?.resize(columns: columns, rows: rows) } }

    func attachTerminal(owner: UUID, output: @escaping (UUID, Data) -> Void) { terminalOwner = owner; terminalOutput = output }
    func detachTerminal(owner: UUID) { if terminalOwner == owner { terminalOwner = nil; terminalOutput = nil } }
    func savedLogURL(_ id: UUID) -> URL? {
        guard records.contains(where: { $0.id == id }), FileManager.default.fileExists(atPath: store.logURL(id).path) else { return nil }
        return store.logURL(id)
    }
    func readLog(_ id: UUID, after cursor: Int, privateChannel: Bool = false) throws -> BuildLogSlice {
        guard records.contains(where: { $0.id == id }) else { throw BuildError.notFound }
        if records.first(where: { $0.id == id })?.hasPrivateInput == true && !privateChannel { return .init(text: "", nextCursor: cursor, gap: false) }
        if records.first(where: { $0.id == id })?.status.isPending == true, let output = outputs[id] { return output.read(after: cursor) }
        guard let handle = FileHandle(forReadingAtPath: store.logURL(id).path) else { return .init(text: "", nextCursor: cursor, gap: false) }
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd()); let offset = min(cursor, size)
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: 64 * 1024 + 4) ?? Data()
        return BuildOutput.slice(bytes, base: offset, after: cursor)
    }
    func diagnostic(_ id: UUID) throws -> String { try diagnosticPayload(id).prompt }
    /// The complete numbered prompt is bounded, including configuration; framing and identity remain intact.
    func diagnosticPayload(_ id: UUID) throws -> (prompt: String, truncated: Bool) {
        guard let record = records.first(where: { $0.id == id }), record.diagnosticAvailable else { throw BuildError.diagnostic }
        let configuration = DiagnosticText.bounded(record.parameters.scheme + " | " + record.parameters.configuration + " | " + record.parameters.destinationID + " | " + record.parameters.testPlan + " | " + record.parameters.workspaceTab + " | " + record.parameters.testIdentifiers.joined(separator: ", "), limit: 8192)
        let header = """
        \(text("build.diagnostic.instructions"))
        ID: \(record.id.uuidString)
        Checkout: \(record.project.path)
        Branch: \(record.project.branch); SHA: \(record.project.commit)
        Backend: \(record.parameters.backend.rawValue); operation: \(record.parameters.operation.rawValue)
        Xcode: \(record.selectedDeveloperDirectory ?? "unknown")
        Parameters: \(configuration.text)
        Preparation: \(record.errorCode ?? "none")
        Status: \(record.status.rawValue); exit: \(record.exitCode.map(String.init) ?? "unknown")
        """
        let raw = DiagnosticText.bounded(String(decoding: output(id), as: UTF8.self))
        let boundedHeader = DiagnosticText.bounded(header, limit: 16 * 1024)
        let fragment = DiagnosticText.bounded(DiagnosticText.numbered(raw.text), limit: DiagnosticText.maximumBytes - boundedHeader.text.utf8.count - 256)
        let truncated = configuration.truncated || boundedHeader.truncated || raw.truncated || fragment.truncated
        return (boundedHeader.text + (truncated ? "\n[TRUNCATED DIAGNOSTIC]" : "") + "\n<diagnostic-data>\n" + fragment.text + "\n</diagnostic-data>", truncated)
    }
}
