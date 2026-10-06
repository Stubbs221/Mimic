// Created by Василий Маслов on 06.10.2026.
import Foundation
import MimicCore

extension MimicIntegration {
    /// A panel may inspect only a personal entry in its current credential scope.
    /// The shared cache is read without touching desktop navigation or another chat's selection.
    func panelCIDetails(threadID: String, parameters: [String: BridgeValue]) throws -> BridgeValue {
        guard let identity = parameters["identity"]?.string, identity.utf8.count <= 256,
              case let .bool(refresh)? = parameters["refresh"],
              let project = self.project(threadID),
              let connection = self.model.ciSettings.connection(forCheckout: project.path, services: self.model.activeProfile?.profile.services) else { throw self.failure("context") }
        let context = CIContext(project: project, connection: connection)
        guard let anchor = self.model.ciMonitor.heartbeat(threadID: threadID, context: context),
              identity.hasPrefix(anchor.scopeID + ":"),
              let state = self.model.ciMonitor.state(for: anchor) else { throw self.failure("notFound") }
        let entryID = String(identity.dropFirst(anchor.scopeID.count + 1))
        guard let entry = state.inspectPersonalEntry(entryID, viewer: threadID, refresh: refresh),
              var summary = state.compactSummary(for: entry), summary.identity == identity else { throw self.failure("notFound") }
        summary.checkout = project.path
        let id = summary.pipelineID
        let checks = id.flatMap { state.summaries[$0] }
        let root = id.flatMap { state.rootChecks(for: $0) }
        let rootIDs = Set(root?.jobs.map(\.id) ?? [])
        let jobs = (checks?.jobs ?? root?.jobs ?? []).map { job -> BridgeValue in
            .object(["id": .number(Double(job.id)), "name": .string(job.name), "stage": .string(job.stage),
                     "status": .string(job.status), "url": .string(job.webURL.absoluteString),
                     "allowFailure": .bool(job.allowFailure), "child": .bool(!rootIDs.contains(job.id))])
        }
        var seen = Set<Int>()
        let bridges = ((root?.bridges ?? []) + (checks?.bridges ?? [])).filter { seen.insert($0.id).inserted }.map { bridge -> BridgeValue in
            .object(["id": .number(Double(bridge.id)), "name": .string(bridge.name),
                     "status": .string(bridge.downstreamPipeline?.status ?? bridge.status),
                     "url": .string((bridge.downstreamPipeline?.webURL ?? bridge.webURL).absoluteString),
                     "allowFailure": .bool(bridge.allowFailure == true)])
        }
        let failure = id.flatMap { state.enrichmentErrors[$0] } ?? state.error
        let requesting = id.map { state.metadataStates[$0] == .loading || state.checkStates[$0] == .loading || state.checkStates[$0] == nil } ?? false
        let loadState = failure != nil ? "failed" : requesting ? "loading" : checks?.complete == false ? "partial" : "loaded"
        return .object([
            "summary": Self.compactCI(summary), "loadState": .string(loadState),
            "error": failure.map { .string(text($0.localizationKey)) } ?? .null,
            "commitTitle": entry.sha.flatMap { state.commitTitles[$0] }.map(BridgeValue.string) ?? checks?.commitTitle.map(BridgeValue.string) ?? .null,
            "sha": entry.sha.map(BridgeValue.string) ?? .null,
            "initiator": entry.participant.map { .string("@" + $0.username) } ?? .null,
            "jobs": .array(jobs), "bridges": .array(bridges),
            "gitlabURL": (entry.pipeline?.webURL ?? entry.run?.pipelineURL).map { .string($0.absoluteString) } ?? .null,
            "jenkinsURL": (entry.run?.buildURL ?? entry.run?.queueURL).map { .string($0.absoluteString) } ?? .null,
            "allureURL": entry.run?.allureURL.map { .string($0.absoluteString) } ?? .null
        ])
    }
}
