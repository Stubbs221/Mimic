//
//  SimulatorAgentIntegration.swift
//  Mimic
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import MimicCore

extension MimicIntegration {
    func simulatorAgentRequest(_ request: MimicBridgeRequest) async throws -> BridgeValue {
        let p = request.parameters, thread = request.threadID
        switch request.method {
        case "get_build_products":
            let record = try accessibleBuild(p["activityID"], thread: thread)
            let products = try await model.builds.productsFor(record.id)
            guard canAccess(record.project, threadID: thread) else { throw BuildError.context }
            return .object(["activityID": .string(record.id.uuidString), "products": try .encode(products)])
        case "select_build_product":
            let record = try accessibleBuild(p["activityID"], thread: thread)
            guard let product = p["productID"]?.string else { throw BuildError.arguments }
            try model.builds.chooseProduct(product, activityID: record.id); return BuildBridge.metadata(model.builds.activity(record.id) ?? record)
        case "prepare_simulator_scenario":
            _ = try expected(p["context"] ?? .null, threadID: thread)
            guard let scenario = model.activeProfile?.profile.simulatorScenarios?.first(where: { $0.id == p["scenarioID"]?.string }) else { throw BuildError.arguments }
            return try await local(["actionID": .string(scenario.actionID), "parameters": try .encode(scenario.parameters), "context": p["context"]!, "requestID": p["requestID"]!], threadID: thread)
        case "run_simulator_app", "open_simulator_deeplink":
            let project = try expected(p["context"] ?? .null, threadID: thread)
            guard let sessionID = p["sessionID"]?.string.flatMap(UUID.init(uuidString:)), let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)),
                  model.simulatorScreen.sessionAllowed(sessionID, thread: thread, project: project), let device = model.simulatorScreen.sessionOwner(sessionID)?.descriptor?.deviceID else { throw BuildError.context }
            let revision = try await sourceRevision(project)
            let app: SimulatorAppRequest, kind: SimulatorActivity.Kind
            var binding: SimulatorBuildBinding?
            if request.method == "run_simulator_app" {
                let record = try accessibleBuild(p["activityID"], thread: thread)
                guard record.project == project, !model.builds.artifactCleanupReserved(record.id), record.status == .succeeded, record.parameters.backend == .cli, record.parameters.destinationID == device.uuidString,
                      record.sourceProvenance?.finished == revision, record.sourceProvenance?.stability == "unchangedObserved", record.profileRevision == model.activeProfile?.revision else { throw BuildError.sourceChanged }
                let products = try await model.builds.productsFor(record.id)
                guard let product = products.first(where: { $0.id == p["productID"]?.string }) else { throw BuildError.arguments }
                let root = model.builds.artifactRoot
                let artifact = try await Task.detached { try ManagedArtifactReader.inspect(URL(fileURLWithPath: product.path), root: root) }.value
                guard !model.builds.artifactCleanupReserved(record.id) else { throw BuildError.context }
                app = .init(product: product, deeplink: nil, revision: revision, exclusions: model.activeProfile?.profile.sourceExclusions ?? [], artifact: artifact, artifactRoot: root.path)
                kind = .launch
                binding = .init(sessionID: sessionID, deviceID: device, activityID: record.id, productID: product.id, sourceRevision: revision, project: project)
            } else {
                guard let bound = simulatorBindings[sessionID], bound.sourceRevision == revision, bound.project == project,
                      let scenario = model.activeProfile?.profile.simulatorScenarios?.first(where: { $0.id == p["scenarioID"]?.string }),
                      let raw = p["url"]?.string, raw.utf8.count <= 2048, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      let url = URLComponents(string: raw), let scheme = url.scheme, scenario.deeplinkSchemes.contains(scheme), url.user == nil, url.password == nil else { throw BuildError.arguments }
                app = .init(product: nil, deeplink: raw, revision: revision, exclusions: model.activeProfile?.profile.sourceExclusions ?? []); kind = .deeplink
            }
            _ = try expected(p["context"]!, threadID: thread)
            let record = try await model.simulatorScreen.submit(id: id, kind: kind, project: project, device: device, sessionID: sessionID, appRequest: app)
            if let binding, record.status.isPending || record.status == .unknown {
                pendingSimulatorBindings[id] = binding; model.builds.artifactLeases.insert(binding.activityID)
            }
            return record.metadata
        case "start_simulator_check":
            guard let id = p["requestID"]?.string.flatMap(UUID.init(uuidString:)), let workflow = p["workflowID"]?.string.flatMap(UUID.init(uuidString:)), let session = p["sessionID"]?.string.flatMap(UUID.init(uuidString:)) else { throw BuildError.arguments }
            if let existing = simulatorChecks[id] {
                guard existing.binding.sessionID == session, existing.workflowID == workflow, existing.owner == thread, canAccess(existing.binding.project, threadID: thread) else { throw BuildError.duplicate }
                return try .encode(existing)
            }
            guard let binding = simulatorBindings[session], canAccess(binding.project, threadID: thread), model.simulatorScreen.sessionAllowed(session, thread: thread, project: project(thread)),
                  !simulatorChecks.values.contains(where: { $0.binding.sessionID == session && $0.status == "recording" }), simulatorChecks.count < 100 else { throw BuildError.context }
            guard try await sourceRevision(binding.project) == binding.sourceRevision else { throw BuildError.sourceChanged }
            let check = SimulatorCheckRecord(id: id, owner: thread, workflowID: workflow, binding: binding)
            simulatorChecks[id] = check; try saveSimulatorChecks(); return try .encode(check)
        case "get_simulator_check", "finish_simulator_check", "start_simulator_recording", "stop_simulator_recording":
            guard let id = p["checkID"]?.string.flatMap(UUID.init(uuidString:)), var check = simulatorChecks[id], canAccess(check.binding.project, threadID: thread) else { throw BuildError.notFound }
            if request.method == "get_simulator_check" { return try .encode(check) }
            guard check.owner == thread else { throw BuildError.context }
            if request.method == "start_simulator_recording" {
                guard let recordingID = p["requestID"]?.string.flatMap(UUID.init(uuidString:)), check.status == "recording" else { throw BuildError.arguments }
                if let existing = check.recordingID {
                    guard existing == recordingID else { throw BuildError.duplicate }; return try .encode(check)
                }
                let path = model.supportDirectory.appendingPathComponent("Agent/Checks/" + id.uuidString + "/" + recordingID.uuidString + ".mov")
                check.recordingID = recordingID; simulatorChecks[id] = check; try saveSimulatorChecks()
                // Persist intent before starting video: an uncertain response cannot create a second recording.
                try await model.simulatorScreen.beginAgentRecording(session: check.binding.sessionID, path: path)
                return try .encode(simulatorChecks[id])
            }
            if check.recordingID != nil, check.video == nil {
                let video = try await model.simulatorScreen.finishAgentRecording(session: check.binding.sessionID)
                simulatorChecks[id]?.video = video
                simulatorChecks[id]?.append(kind: "video", artifact: video.path)
            }
            if request.method == "finish_simulator_check" {
                simulatorChecks[id]?.finishedAt = Date(); simulatorChecks[id]?.status = "finished"
            }
            try saveSimulatorChecks(); return try .encode(simulatorChecks[id])
        default: throw BuildError.arguments
        }
    }
    func saveSimulatorChecks() throws {
        let directory = model.supportDirectory.appendingPathComponent("Agent")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("checks.json")
        try JSONEncoder().encode(simulatorChecks).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func recordSimulatorOperation(_ record: SimulatorActivity) {
        if let binding = pendingSimulatorBindings.removeValue(forKey: record.id) {
            if record.status == .succeeded { simulatorBindings[binding.sessionID] = binding }
            else if record.status == .unknown { pendingSimulatorBindings[record.id] = binding }
            else { releaseArtifactLease(binding.activityID) }
        }
        for id in simulatorChecks.keys where simulatorChecks[id]?.status == "recording" && simulatorChecks[id]?.binding.sessionID == record.sessionID {
            simulatorChecks[id]?.append(kind: record.kind.rawValue + ":" + record.status.rawValue, activityID: record.id, revision: record.observedRevision)
            if let revision = record.resultRevision { simulatorChecks[id]?.append(kind: "resultObservation", activityID: record.id, revision: revision) }
        }
        try? saveSimulatorChecks()
    }
    func recordSimulatorObservation(session: UUID, observation: BridgeValue) throws {
        for id in simulatorChecks.keys where simulatorChecks[id]?.status == "recording" && simulatorChecks[id]?.binding.sessionID == session {
            let directory = model.supportDirectory.appendingPathComponent("Agent/Checks/" + id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let revision = observation["revision"].integer.map(UInt64.init)
            var artifact: String?
            if let image = observation["image"].string, let bytes = Data(base64Encoded: image), bytes.count <= 10 * 1024 * 1024, (simulatorChecks[id]?.events.count ?? 500) < 500 {
                let file = directory.appendingPathComponent(UUID().uuidString + ".jpg")
                try bytes.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); artifact = file.path
            }
            simulatorChecks[id]?.append(kind: "observation", revision: revision, artifact: artifact)
        }
        try saveSimulatorChecks()
    }
    func simulatorSessionClosed(_ session: UUID) {
        let binding = simulatorBindings.removeValue(forKey: session)
        let pending = pendingSimulatorBindings.filter { $0.value.sessionID == session }
        for (id, _) in pending { pendingSimulatorBindings[id] = nil }
        for value in pending.values { releaseArtifactLease(value.activityID) }
        if let binding { releaseArtifactLease(binding.activityID) }
        for id in simulatorChecks.keys where simulatorChecks[id]?.binding.sessionID == session && simulatorChecks[id]?.status == "recording" {
            simulatorChecks[id]?.status = "interrupted"; simulatorChecks[id]?.finishedAt = Date(); simulatorChecks[id]?.append(kind: "sessionClosed")
        }
        try? saveSimulatorChecks()
    }
    func releaseArtifactLease(_ id: UUID) {
        if !simulatorBindings.values.contains(where: { $0.activityID == id }) && !pendingSimulatorBindings.values.contains(where: { $0.activityID == id }) { model.builds.artifactLeases.remove(id) }
    }
}
