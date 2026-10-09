//
//  CIState.swift
//  MimicCore
//
//  Created by Василий Маслов on 02.10.2026.
import Combine
import Foundation

/// Local checkout identity is separate from remote pipeline identity, including its SHA.
public struct CIContext: Equatable, Sendable {
    public let checkout: String
    public let branch: String
    public let commit: String
    public let connection: GitLabConnection
    public init(project: ProjectContext, connection: GitLabConnection) {
        self.checkout = project.path; self.branch = project.branch; self.commit = project.commit; self.connection = connection
    }
}

/// Owns the personal feed and shared request cache. Background interests poll only the compact personal selection.
@MainActor
public final class CIState: ObservableObject {
    @Published public private(set) var pipelines: [CIPipeline] = [] { didSet { self.invalidateFeed() } }
    @Published public private(set) var reasons: [Int: Set<CIOwnershipReason>] = [:] { didSet { self.invalidateFeed() } }
    @Published public private(set) var user: CIUser? { didSet { self.invalidateFeed() } }
    @Published public private(set) var trackedUsers: [CITrackedUser] = [] { didSet { self.invalidateFeed() } }
    @Published public private(set) var searchResults: [CIUser] = []
    @Published public private(set) var searching = false
    @Published public private(set) var searchError: CIError?
    @Published public private(set) var historyIncomplete = false { didSet { self.scheduleCompactPresentation() } }
    @Published public private(set) var loadedAt: Date? { didSet { self.invalidateFeed() } }
    @Published public private(set) var error: CIError? { didSet { self.scheduleCompactPresentation() } }
    @Published public private(set) var loading = false { didSet { self.scheduleCompactPresentation() } }
    @Published public private(set) var details: CIPipelineDetails?
    @Published public private(set) var detailError: CIError?
    @Published public private(set) var loadingDetails = false
    @Published public private(set) var selectedPipelineID: Int?
    @Published public private(set) var historyLimit = 3
    @Published public private(set) var summaries: [Int: CIProgressSummary] = [:] { didSet { self.scheduleCompactPresentation() } }
    @Published public private(set) var enrichmentErrors: [Int: CIError] = [:]
    @Published public private(set) var enrichedPipelines: [Int: CIPipeline] = [:] { didSet { self.invalidateFeed() } }
    @Published public private(set) var metadataStates: [Int: CILoadState] = [:] { didSet { self.scheduleCompactPresentation() } }
    @Published public private(set) var checkStates: [Int: CILoadState] = [:] { didSet { self.scheduleCompactPresentation() } }
    @Published public private(set) var commitTitles: [String: String] = [:]
    private var commitFailures: Set<String> = []
    private var metadataDates: [Int: Date] = [:] { didSet { self.invalidateFeed() } }
    private var expandedLoads: Set<Int> = []
    private var fullyLoadedChecks: Set<Int> = []
    private var childDetails: [String: CIPipelineDetails] = [:]
    public private(set) var feedPresented = false
    private var rootDetails: [Int: CIPipelineDetails] = [:]
    private struct Inspection {
        let entry: CIFeedEntry
        let date: Date
    }
    private var inspections: [String: Inspection] = [:]
    private var summaryDates: [Int: Date] = [:] { didSet { self.scheduleCompactPresentation() } }
    private var enrichmentTask: Task<Void, Never>?
    private var enrichmentTimer: Task<Void, Never>?
    private var enrichmentRevision = UUID()
    private var initiatedPipelines: [CIPipeline] = []
    private var initiatedNextPage: Int?
    private var trackedNextPages: [Int: Int] = [:]
    public private(set) var context: CIContext? { didSet { self.invalidateFeed() } }
    public private(set) var visible = false
    public private(set) var monitoring = false
    private var polling: Bool { self.visible || self.monitoring }
    private var enriching: Bool { self.monitoring || self.visible && self.feedPresented }
    private var compactFinalized: Set<Int> = []
    private var compactTracked: Set<Int> = []
    public private(set) var pollingPaused = false
    private let client: any GitLabService
    private let token: @MainActor (GitLabConnection) throws -> String
    private let trackingStore: any CITrackingStore
    private let interval: Duration
    private let enrichmentInterval: Duration
    private var enrichmentAge: TimeInterval {
        let value = self.enrichmentInterval.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    public var branchOwnerPattern: String?
    private var revision = UUID()
    private var detailRevision = UUID()
    private var searchRevision = UUID()
    private var task: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var retryAt: Date?
    private var nextHistoryPage: Int?
    private var branchPipelines: [CIPipeline] = []
    private var remoteRuns: [RemoteTestRun] = [] { didSet { self.invalidateFeed() } }
    private var jenkins: JenkinsConnection? { didSet { self.invalidateFeed() } }

    public init(client: any GitLabService = GitLabClient(), interval: Duration = .seconds(30), enrichmentInterval: Duration = .seconds(15), trackingStore: any CITrackingStore = DefaultsCITrackingStore(), token: @escaping @MainActor (GitLabConnection) throws -> String) {
        self.client = client; self.interval = interval; self.enrichmentInterval = enrichmentInterval; self.trackingStore = trackingStore; self.token = token
    }

    // MARK: - Committed presentation and feed cache

    public let compactPresentation = CICompactPresentation()
    private var cachedFeed: [CIFeedEntry]?
    private var cachedPersonal: [CIFeedEntry]?
    private var cachedCompact: [CIFeedEntry]?
    private var presentationTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?

    private func invalidateFeed() {
        self.cachedFeed = nil; self.cachedPersonal = nil; self.cachedCompact = nil
        self.scheduleCompactPresentation()
    }

    /// Published will-change callbacks run before assignment; defer until the response is committed.
    private func scheduleCompactPresentation() {
        guard self.presentationTask == nil else { return }
        self.presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.presentationTask = nil
            self.refreshCompactPresentation()
        }
    }

    /// Direct bridge reads stay synchronous; native readers receive only changed display values.
    public func refreshCompactPresentation(now: Date = .now) {
        let summaries = self.compactEntries.compactMap { self.compactSummary(for: $0, now: now) }
        if self.compactPresentation.summaries != summaries { self.compactPresentation.summaries = summaries }
        var footer = CICompactFooter()
        footer.loading = self.loading; footer.error = self.error; footer.pipeline = self.pipelines.first
        footer.context = self.context; footer.loadedAt = self.loadedAt; footer.historyIncomplete = self.historyIncomplete
        if self.compactPresentation.footer != footer { self.compactPresentation.footer = footer }
        self.freshnessTask?.cancel(); self.freshnessTask = nil
        // A paused poll must still become stale at the original 45-second boundary.
        let deadline = summaries.filter { !$0.stale }.compactMap { $0.updatedAt?.addingTimeInterval(45) }.min()
        if let deadline {
            let delay = max(0.001, deadline.timeIntervalSince(now) + 0.001)
            self.freshnessTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.refreshCompactPresentation()
            }
        }
    }

    // MARK: - Context and lifetime

    public func select(_ context: CIContext?) {
        guard self.context != context else { return }
        let sameConnection = self.context?.connection == context?.connection
        self.cancelRequests(); self.stopEnrichment(); self.historyLimit = 3; self.summaries = [:]; self.rootDetails = [:]; self.summaryDates = [:]; self.resetEnrichmentCache(); self.enrichedPipelines = [:]; self.enrichmentErrors = [:]; self.context = context
        self.clearDetails()
        if !sameConnection { self.resetAccount() }
        self.pollingPaused = false; self.retryAt = nil
        if self.polling { self.refresh() }
    }

    public func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if !visible { self.clearDetails(); self.historyLimit = 3 }
        self.updateLifetime()
        if visible, self.monitoring { self.refresh() }
    }

    /// A floating card or checkout lease keeps discovery alive without opening the full feed.
    public func setMonitoring(_ monitoring: Bool) {
        guard self.monitoring != monitoring else { return }
        self.monitoring = monitoring
        self.updateLifetime()
    }

    private func updateLifetime() {
        guard self.polling else {
            self.timer?.cancel(); self.timer = nil; self.cancelRequests(); self.stopEnrichment(); return
        }
        if self.enriching { self.startEnrichmentTimer(); self.enrichVisible() }
        else { self.stopEnrichment() }
        guard self.timer == nil else { return }
        if !self.pollingPaused { self.refresh() }
        self.timer = Task { [weak self, interval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.polling else { return }
                if !self.pollingPaused { self.refresh() }
            }
        }
    }

    /// A replacement token may belong to another account even when the connection UUID is unchanged.
    public func credentialsChanged() {
        self.cancelRequests(); self.resetAccount(); self.pollingPaused = false; self.retryAt = nil
        if self.polling { self.refresh() }
    }

    private func resetAccount() {
        self.stopEnrichment(); self.historyLimit = 3; self.summaries = [:]; self.enrichmentErrors = [:]; self.enrichedPipelines = [:]; self.rootDetails = [:]; self.summaryDates = [:]; self.resetEnrichmentCache()
        self.initiatedPipelines = []; self.initiatedNextPage = nil; self.trackedNextPages = [:]
        self.pipelines = []; self.reasons = [:]; self.user = nil; self.trackedUsers = []
        self.loadedAt = nil; self.error = nil; self.branchPipelines = []; self.nextHistoryPage = nil; self.historyIncomplete = false
        self.clearDetails(); self.searchResults = []; self.searchError = nil
    }

    /// Uses only linked launches from the same project and the currently configured Jenkins account.
    public func setJenkinsRuns(_ runs: [RemoteTestRun], connection: JenkinsConnection?) {
        let old = self.linkedRuns.map(\.pipelineID)
        self.objectWillChange.send()
        self.remoteRuns = runs; self.jenkins = connection
        guard old != self.linkedRuns.map(\.pipelineID) else { return }
        // Remove results whose sole ownership evidence was a disconnected/replaced Jenkins account immediately.
        let linked = Set(self.linkedRuns.compactMap(\.pipelineID))
        for id in self.reasons.keys where !linked.contains(id) { self.reasons[id]?.remove(.jenkins) }
        self.pipelines.removeAll { self.reasons[$0.id]?.isEmpty != false }
        if let selected = self.selectedPipelineID, !self.visibleIDs.contains(selected) { self.clearDetails() }
        self.cancelRequests()
        if self.polling { self.refresh() }
    }

    private var scopedRuns: [RemoteTestRun] {
        guard let context, let jenkins, self.user != nil else { return [] }
        return self.remoteRuns.filter {
            $0.gitlab.baseURL == context.connection.baseURL && $0.gitlab.projectID == context.connection.projectID &&
            $0.jenkins.baseURL == jenkins.baseURL && $0.jenkins.username == jenkins.username
        }
    }
    private var linkedRuns: [RemoteTestRun] { self.scopedRuns.filter { $0.pipelineID != nil }.sorted { ($0.pipelineID ?? 0) > ($1.pipelineID ?? 0) } }

    /// History is combined independently of the personal pipeline array used by the footer.
    public var feedEntries: [CIFeedEntry] {
        if let cachedFeed { return cachedFeed }
        let value = self.makeFeedEntries()
        self.cachedFeed = value
        return value
    }

    private func makeFeedEntries() -> [CIFeedEntry] {
        var entries: [CIFeedEntry] = [], seen = Set<Int>(), runIDs = Set<UUID>()
        let runs = self.scopedRuns
        for value in self.pipelines + self.trackedUsers.flatMap(\.pipelines) {
            guard seen.insert(value.id).inserted else { continue }
            let cached = self.enrichedPipelines[value.id]
            let cachedAfterFeed = (self.metadataDates[value.id] ?? .distantPast) >= (self.loadedAt ?? .distantPast)
            let pipeline = cached.flatMap { cachedAfterFeed || $0.status == value.status ? $0 : nil } ?? value
            let run = runs.first { $0.pipelineID == value.id }
            if let run { runIDs.insert(run.id) }
            let participant = pipeline.user ?? self.trackedUsers.first { $0.pipelines.contains { $0.id == value.id } }?.user ?? (self.reasons[value.id]?.contains(.initiator) == true || run != nil ? self.user : nil)
            entries.append(CIFeedEntry(pipeline: pipeline, run: run, participant: participant))
        }
        for run in runs where !runIDs.contains(run.id) {
            if let id = run.pipelineID, !seen.insert(id).inserted { continue }
            entries.append(CIFeedEntry(pipeline: nil, run: run, participant: self.user))
        }
        return entries.sorted {
            if let left = $0.createdAt, let right = $1.createdAt, left != right { return left > right }
            let leftID = $0.pipeline?.id ?? $0.run?.pipelineID ?? Int.max
            let rightID = $1.pipeline?.id ?? $1.run?.pipelineID ?? Int.max
            return leftID == rightID ? $0.id > $1.id : leftID > rightID
        }
    }
    /// Subscription-only pipelines never enter compact or floating selections.
    public var personalEntries: [CIFeedEntry] {
        if let cachedPersonal { return cachedPersonal }
        let ownIDs = Set(self.pipelines.map(\.id))
        let value = self.feedEntries.filter { $0.run != nil || $0.pipeline.map { ownIDs.contains($0.id) } == true }
        self.cachedPersonal = value
        return value
    }
    /// Active runs precede terminal runs; unknown start times affect ordering only, never displayed timing.
    public var compactEntries: [CIFeedEntry] {
        if let cachedCompact { return cachedCompact }
        let value = Array(self.personalEntries.sorted {
            let leftActive = CICompactSummary.isActive($0.status), rightActive = CICompactSummary.isActive($1.status)
            if leftActive != rightActive { return leftActive }
            let left = $0.pipeline?.startedAt ?? $0.createdAt ?? .distantPast
            let right = $1.pipeline?.startedAt ?? $1.createdAt ?? .distantPast
            if left != right { return left > right }
            let leftID = $0.pipeline?.id ?? $0.run?.pipelineID ?? 0
            let rightID = $1.pipeline?.id ?? $1.run?.pipelineID ?? 0
            return leftID == rightID ? $0.id > $1.id : leftID > rightID
        }.prefix(2))
        self.cachedCompact = value
        return value
    }

    /// Compatibility projection for floating activity and older bridge clients.
    public var compactEntry: CIFeedEntry? {
        self.compactEntries.first
    }
    /// Up to two personal presentations in the same order used by native and Codex cards.
    public var compactSummaries: [CICompactSummary] {
        self.compactEntries.compactMap { self.compactSummary(for: $0) }
    }
    public var compactSummary: CICompactSummary? {
        guard let entry = self.compactEntry, let context else { return nil }
        return self.compactSummary(for: entry, context: context)
    }
    /// Reads an exact retained entry, including a completion temporarily held by the floating section.
    public func compactSummary(for entry: CIFeedEntry, context: CIContext? = nil, now: Date = .now) -> CICompactSummary? {
        guard let context = context ?? self.context else { return nil }
        let id = entry.pipeline?.id ?? entry.run?.pipelineID
        let updated = id.flatMap { self.summaryDates[$0] } ?? self.loadedAt
        let stale = self.error != nil || id.map { self.checkStates[$0] == .failed || self.metadataStates[$0] == .failed } == true || updated.map { now.timeIntervalSince($0) > 45 } == true
        return CICompactSummary(entry: entry, context: context, accountID: self.user?.id, checks: id.flatMap { self.summaries[$0] }, updatedAt: updated, stale: stale)
    }

    /// Retains one personal run per live panel without changing native detail selection.
    /// The caller must verify account scope and checkout before registering an interest.
    public func inspectPersonalEntry(_ entryID: String, viewer: String, refresh: Bool = false) -> CIFeedEntry? {
        self.inspections = self.inspections.filter { Date().timeIntervalSince($0.value.date) < 30 }
        guard let retained = self.personalEntries.first(where: { $0.id == entryID }) ?? self.inspections[viewer].flatMap({ $0.entry.id == entryID ? $0.entry : nil }) else { return nil }
        let id = retained.pipeline?.id ?? retained.run?.pipelineID
        let entry = CIFeedEntry(pipeline: id.flatMap { self.enrichedPipelines[$0] } ?? retained.pipeline, run: retained.run, participant: retained.participant)
        self.inspections[viewer] = Inspection(entry: entry, date: Date())
        if let id {
            self.expandedLoads.insert(id)
            if refresh, self.retryAt.map({ $0 <= Date() }) ?? true {
                self.invalidateDetails(id, sha: entry.sha)
            }
        }
        self.enrichVisible()
        return entry
    }

    /// Cached root and child checks are shared with panels, without selecting a native pipeline.
    public func rootChecks(for id: Int) -> CIPipelineDetails? { self.rootDetails[id] }

    public var visibleEntries: [CIFeedEntry] { Array(self.feedEntries.prefix(self.historyLimit)) }
    public var canShowMore: Bool {
        self.feedEntries.count > self.historyLimit || self.nextHistoryPage != nil || self.initiatedNextPage != nil || !self.trackedNextPages.isEmpty
    }
    /// Explicit run navigation reveals whole history pages before selecting its details.
    public func revealPipeline(_ id: Int) {
        if let index = self.feedEntries.firstIndex(where: { $0.pipeline?.id == id || $0.run?.pipelineID == id }) {
            self.historyLimit = max(self.historyLimit, ((index / 3) + 1) * 3)
        }
        self.loadDetails(id)
    }

    public func showMore() {
        guard !self.loading else { return }
        self.historyLimit += 3
        self.loadFeed(manual: true, continuing: true)
        self.enrichVisible()
    }
    /// Hidden pages pause full-feed enrichment; compact monitoring keeps its own lifetime.
    /// Ordinary disclosure collapse keeps its original reset behavior.
    public func setFeedPresented(_ presented: Bool, preserveSelection: Bool = false) {
        guard self.feedPresented != presented else {
            if !presented, !preserveSelection, self.selectedPipelineID != nil || self.historyLimit != 3 {
                self.historyLimit = 3; self.clearDetails()
            }
            return
        }
        self.feedPresented = presented
        if self.enriching { self.startEnrichmentTimer(); self.enrichVisible() }
        else { self.stopEnrichment() }
        if !presented {
            if preserveSelection {
                self.detailRevision = UUID(); self.detailTask?.cancel(); self.detailTask = nil; self.loadingDetails = false
            } else { self.historyLimit = 3; self.clearDetails() }
        }
    }

    // MARK: - Personal feed

    public func refresh(manual: Bool = false) {
        if manual {
            self.stopEnrichment(); self.summaryDates = [:]; self.metadataDates = [:]; self.enrichmentErrors = [:]
            self.metadataStates = [:]; self.checkStates = [:]; self.rootDetails = [:]; self.summaries = [:]
            self.commitTitles = [:]; self.commitFailures = []; self.fullyLoadedChecks = []; self.childDetails = [:]
        }
        self.loadFeed(manual: manual, continuing: false)
    }

    /// Advances a bounded history scan instead of silently treating its limit as an empty feed.
    public func continueHistorySearch() {
        guard self.nextHistoryPage != nil || self.initiatedNextPage != nil || !self.trackedNextPages.isEmpty else { return }
        self.loadFeed(manual: true, continuing: true)
    }

    private var visibleIDs: Set<Int> {
        Set(self.pipelines.map(\.id) + self.trackedUsers.flatMap { $0.pipelines.map(\.id) } + self.scopedRuns.compactMap(\.pipelineID))
    }

    private func loadFeed(manual: Bool, continuing: Bool) {
        guard self.polling, let context, !self.loading else { return }
        if manual { self.pollingPaused = false }
        guard !self.pollingPaused, self.retryAt.map({ $0 <= Date() }) ?? true else { return }
        let revision = UUID(); self.revision = revision; self.loading = true
        let startingPage = continuing ? self.nextHistoryPage ?? 1 : 1
        let previousBranches = self.branchPipelines
        let previousNextPage = self.nextHistoryPage
        let target = self.historyLimit + 1
        self.task = Task { [weak self, client, token] in
            do {
                let credential = try token(context.connection)
                guard let self else { return }
                let owner: CIUser
                if let cached = self.user { owner = cached }
                else { owner = try await client.currentUser(connection: context.connection, token: credential) }
                guard self.accepts(revision, context) else { return }
                if self.user == nil {
                    self.user = owner
                    var seen = Set<Int>()
                    self.trackedUsers = self.trackingStore.users(connection: context.connection, owner: owner)
                        .filter { $0.id != owner.id && seen.insert($0.id).inserted }.map { CITrackedUser(user: $0) }
                }
                let linked = Array(self.linkedRuns.prefix(target))
                var initiated = continuing ? self.initiatedPipelines : []
                var initiatedPage: Int? = continuing ? self.initiatedNextPage : 1
                var initiatedVisited = Set<Int>()
                while let page = initiatedPage, (!continuing && initiatedVisited.isEmpty || initiated.count < target), initiatedVisited.count < 20 {
                    try Task.checkCancellation()
                    guard initiatedVisited.insert(page).inserted else { throw CIError.invalidResponse }
                    let value = try await client.pipelinePage(connection: context.connection, username: owner.username, page: page, perPage: 100, token: credential)
                    initiated = CIPersonalSelection.latest(value.pipelines + initiated, projectID: context.connection.projectID)
                    initiatedPage = value.nextPage
                    if initiated.count >= target { break }
                }
                guard self.accepts(revision, context) else { return }
                let initiatedIncomplete = initiatedPage != nil && initiated.count < target
                if !continuing { initiated = CIPersonalSelection.latest(initiated + self.initiatedPipelines, projectID: context.connection.projectID) }
                self.initiatedPipelines = initiated
                if continuing || self.initiatedNextPage == nil { self.initiatedNextPage = initiatedPage }

                var branches = continuing ? previousBranches : []
                var page: Int? = self.branchOwnerPattern == nil ? nil : continuing ? self.nextHistoryPage : startingPage
                var visited = Set<Int>()
                while let current = page, (!continuing && visited.isEmpty || CIPersonalSelection.latest(branches, projectID: context.connection.projectID).count < target), visited.count < 20 {
                    try Task.checkCancellation()
                    guard visited.insert(current).inserted else { throw CIError.invalidResponse }
                    let value = try await client.pipelinePage(connection: context.connection, username: nil, page: current, perPage: 100, token: credential)
                    branches = value.pipelines.filter { CIPersonalSelection.owns(ref: $0.ref, username: owner.username, pattern: self.branchOwnerPattern) } + branches
                    page = value.nextPage
                }
                let incomplete = page != nil && CIPersonalSelection.latest(branches, projectID: context.connection.projectID).count < target
                if !continuing { branches += previousBranches }
                var launched: [CIPipeline] = []
                for run in linked {
                    try Task.checkCancellation()
                    guard let id = run.pipelineID else { continue }
                    do {
                        let pipeline: CIPipeline
                        if let cached = self.enrichedPipelines[id], ["success", "failed", "canceled", "skipped"].contains(cached.status) {
                            pipeline = cached
                        } else { pipeline = try await client.pipeline(connection: context.connection, id: id, token: credential) }
                        guard pipeline.ref == run.branch, pipeline.sha == run.sha,
                              pipeline.projectID == nil || pipeline.projectID == context.connection.projectID else { throw CIError.invalidResponse }
                        launched.append(pipeline)
                    } catch CIError.notFound { continue }
                }
                guard self.accepts(revision, context) else { return }
                var reasons: [Int: Set<CIOwnershipReason>] = [:]
                for value in initiated { reasons[value.id, default: []].insert(.initiator) }
                for value in branches { reasons[value.id, default: []].insert(.branch) }
                for value in launched { reasons[value.id, default: []].insert(.jenkins) }
                self.pipelines = CIPersonalSelection.latest(initiated + branches + launched, projectID: context.connection.projectID)
                self.reasons = reasons; self.branchPipelines = CIPersonalSelection.latest(branches, projectID: context.connection.projectID)
                if !continuing, let page, let previousNextPage { self.nextHistoryPage = max(page, previousNextPage) }
                else { self.nextHistoryPage = page }
                self.historyIncomplete = incomplete || initiatedIncomplete
                self.loadedAt = Date(); self.error = nil; self.retryAt = nil
                // A colleague's unavailable history must not replace the successful personal footer with an error.
                let subscriptions = self.visible ? self.trackedUsers : []
                for group in subscriptions {
                    do {
                        var values = continuing ? group.pipelines : []
                        var page: Int? = continuing ? self.trackedNextPages[group.id] : 1
                        var visited = Set<Int>()
                        while let current = page, (!continuing && visited.isEmpty || values.count < target), visited.count < 20 {
                            try Task.checkCancellation()
                            guard visited.insert(current).inserted else { throw CIError.invalidResponse }
                            let result = try await client.pipelinePage(connection: context.connection, username: group.user.username, page: current, perPage: 100, token: credential)
                            values = CIPersonalSelection.latest(result.pipelines + values, projectID: context.connection.projectID)
                            page = result.nextPage
                            if values.count >= target { break }
                        }
                        guard self.accepts(revision, context), let index = self.trackedUsers.firstIndex(where: { $0.id == group.id }) else { return }
                        let trackedIncomplete = page != nil && values.count < target
                        if !continuing { values = CIPersonalSelection.latest(values + group.pipelines, projectID: context.connection.projectID) }
                        self.trackedUsers[index].pipelines = values
                        if trackedIncomplete { self.historyIncomplete = true }
                        if continuing || self.trackedNextPages[group.id] == nil { self.trackedNextPages[group.id] = page }
                        self.trackedUsers[index].error = nil; self.trackedUsers[index].loadedAt = Date()
                    } catch {
                        guard self.accepts(revision, context), let index = self.trackedUsers.firstIndex(where: { $0.id == group.id }) else { return }
                        let failure = error as? CIError ?? .network
                        self.trackedUsers[index].error = failure; self.applyRetry(failure)
                        if failure.pausesPolling || self.retryAt != nil { break }
                    }
                }
                guard self.accepts(revision, context) else { return }
                self.loading = false; self.task = nil
                self.enrichVisible()
                if let selected = self.selectedPipelineID, self.visibleIDs.contains(selected) { self.loadDetails(selected) }
                else if self.selectedPipelineID != nil { self.clearDetails() }
            } catch {
                guard let self, self.accepts(revision, context) else { return }
                let failure = error as? CIError ?? .network
                self.error = failure; self.applyRetry(failure); self.loading = false; self.task = nil
            }
        }
    }

    private func accepts(_ revision: UUID, _ context: CIContext) -> Bool {
        self.revision == revision && self.context == context && self.polling && !Task.isCancelled
    }

    private func applyRetry(_ failure: CIError) {
        if failure == .credential || failure == .authentication || failure == .forbidden { self.error = failure }
        if failure.pausesPolling { self.pollingPaused = true }
        if case let .rateLimited(delay) = failure { self.retryAt = Date().addingTimeInterval(delay) }
    }

    // MARK: - Subscriptions

    public func track(_ user: CIUser) {
        guard let owner = self.user, let context, user.id != owner.id, !self.trackedUsers.contains(where: { $0.id == user.id }) else { return }
        self.trackedUsers.append(CITrackedUser(user: user)); self.persistSubscriptions(owner, context)
        self.cancelRequests(); if self.polling { self.refresh() }
    }

    public func untrack(_ id: Int) {
        guard let owner = self.user, let context else { return }
        self.trackedNextPages[id] = nil
        self.trackedUsers.removeAll { $0.id == id }; self.persistSubscriptions(owner, context)
        if let selected = self.selectedPipelineID, !self.visibleIDs.contains(selected) { self.clearDetails() }
        self.cancelRequests(); if self.polling { self.refresh() }
    }

    private func persistSubscriptions(_ owner: CIUser, _ context: CIContext) {
        self.trackingStore.save(self.trackedUsers.map(\.user), connection: context.connection, owner: owner)
    }

    /// Debounced native member search; stale answers cannot cross contexts or account changes.
    public func searchUsers(_ query: String) {
        self.searchTask?.cancel(); self.searchRevision = UUID(); self.searchResults = []; self.searchError = nil; self.searching = false
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.visible, let context, self.user != nil, !query.isEmpty, !self.pollingPaused,
              self.retryAt.map({ $0 <= Date() }) ?? true else { return }
        let revision = self.searchRevision; self.searching = true
        self.searchTask = Task { [weak self, client, token] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                let users = try await client.users(connection: context.connection, search: query, token: token(context.connection))
                guard let self, self.searchRevision == revision, self.context == context, self.visible, !Task.isCancelled else { return }
                self.searchResults = users.filter { value in value.id != self.user?.id && !self.trackedUsers.contains { $0.id == value.id } }
                self.searching = false; self.searchTask = nil
            } catch {
                guard let self, self.searchRevision == revision, self.context == context, self.visible, !Task.isCancelled else { return }
                let failure = error as? CIError ?? .network
                self.searchError = failure; self.applyRetry(failure); self.searching = false; self.searchTask = nil
            }
        }
    }

    // MARK: - Pipeline details

    public func loadDetails(_ id: Int) {
        guard self.visible, let context, self.visibleIDs.contains(id) else { return }
        if self.feedPresented {
            self.selectedPipelineID = id; self.expandedLoads.insert(id)
            self.details = self.rootDetails[id]; self.detailError = self.enrichmentErrors[id]
            self.loadingDetails = self.checkStates[id] == .loading
            self.enrichVisible(); return
        }
        if let retryAt, retryAt > Date() { return }
        self.detailTask?.cancel(); let revision = UUID(); detailRevision = revision
        if self.selectedPipelineID != id { self.details = nil }
        self.selectedPipelineID = id; self.detailError = nil; self.loadingDetails = true
        self.detailTask = Task { [weak self, client, token] in
            do {
                let value = try await client.details(connection: context.connection, pipelineID: id, token: token(context.connection))
                guard let self, self.detailRevision == revision, self.context == context, self.visible, !Task.isCancelled else { return }
                self.details = value; self.loadingDetails = false; self.detailTask = nil
                if let error = value.bridgeError, error.pausesPolling { self.pollingPaused = true }
                if case let .rateLimited(delay) = value.bridgeError { self.retryAt = Date().addingTimeInterval(delay) }
            } catch {
                guard let self, self.detailRevision == revision, self.context == context, self.visible, !Task.isCancelled else { return }
                let failure = error as? CIError ?? .network
                self.detailError = failure; self.loadingDetails = false; self.detailTask = nil
                if failure.pausesPolling { self.pollingPaused = true }
                if case let .rateLimited(delay) = failure { self.retryAt = Date().addingTimeInterval(delay) }
            }
        }
    }

    public func clearDetails() {
        self.detailRevision = UUID(); self.detailTask?.cancel(); self.detailTask = nil
        self.selectedPipelineID = nil; self.details = nil; self.detailError = nil; self.loadingDetails = false
    }

    // MARK: - Visible-card enrichment

    private func startEnrichmentTimer() {
        guard self.enrichmentTimer == nil else { return }
        self.enrichmentTimer = Task { [weak self, enrichmentInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: enrichmentInterval) } catch { return }
                self?.enrichVisible()
            }
        }
    }
    private func stopEnrichment() {
        self.enrichmentRevision = UUID(); self.enrichmentTask?.cancel(); self.enrichmentTask = nil
        self.enrichmentTimer?.cancel(); self.enrichmentTimer = nil
    }
    private func resetEnrichmentCache() {
        self.inspections = [:]
        self.compactTracked = []; self.compactFinalized = []; self.metadataStates = [:]; self.checkStates = [:]; self.metadataDates = [:]
        self.commitTitles = [:]; self.commitFailures = []; self.expandedLoads = []; self.fullyLoadedChecks = []; self.childDetails = [:]
    }

    public func retryDetails(_ id: Int) {
        guard self.retryAt.map({ $0 <= Date() }) ?? true else { return }
        self.invalidateDetails(id, sha: self.visibleEntries.first(where: { $0.pipeline?.id == id })?.sha)
        self.loadDetails(id)
    }

    private func invalidateDetails(_ id: Int, sha: String?) {
        self.compactFinalized.remove(id); self.metadataDates[id] = nil; self.summaryDates[id] = nil; self.enrichmentErrors[id] = nil
        self.metadataStates[id] = nil; self.checkStates[id] = nil; self.rootDetails[id] = nil; self.fullyLoadedChecks.remove(id); self.childDetails = [:]
        if let sha { self.commitFailures.remove(sha) }
    }

    /// One worker coalesces feed, timer and disclosure requests for the current connection generation.
    private func enrichVisible() {
        guard self.polling, self.enriching, let context, self.enrichmentTask == nil, !self.pollingPaused,
              self.retryAt.map({ $0 <= Date() }) ?? true else { return }
        self.startEnrichmentTimer()
        var entries = self.visible && self.feedPresented ? self.visibleEntries : []
        self.inspections = self.inspections.filter { Date().timeIntervalSince($0.value.date) < 30 }
        let compact = self.monitoring ? self.compactEntries : []
        for entry in compact + self.inspections.values.map(\.entry) {
            if !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
        }
        for entry in compact {
            if let id = entry.pipeline?.id ?? entry.run?.pipelineID { self.compactTracked.insert(id) }
        }
        if self.monitoring {
            for entry in self.personalEntries {
                guard let id = entry.pipeline?.id ?? entry.run?.pipelineID, self.compactTracked.contains(id), !self.compactFinalized.contains(id),
                      !CICompactSummary.isActive(entry.status), !entries.contains(where: { $0.id == entry.id }) else { continue }
                entries.append(entry)
            }
        }
        let revision = self.enrichmentRevision
        self.enrichmentTask = Task { [weak self, client, token] in
            guard let self else { return }
            defer {
                if self.enrichmentRevision == revision {
                    self.enrichmentTask = nil
                    let pending = (self.monitoring ? self.compactEntries : []) + self.inspections.values.map(\.entry)
                    if pending.contains(where: { entry in
                        guard let id = entry.pipeline?.id ?? entry.run?.pipelineID else { return false }
                        return self.checkStates[id] == nil && !entries.contains(where: { $0.id == entry.id })
                    }) || self.selectedPipelineID.map({ id in self.checkStates[id] == nil && entries.contains(where: { $0.pipeline?.id == id || $0.run?.pipelineID == id }) }) == true { self.enrichVisible() }
                }
            }
            for entry in entries {
                guard self.acceptsEnrichment(revision, context) else { return }
                guard let id = entry.pipeline?.id ?? entry.run?.pipelineID else { continue }
                let terminal = ["success", "failed", "canceled", "skipped"].contains(entry.status)
                let needsMetadata = self.metadataDates[id] == nil || terminal && self.enrichedPipelines[id]?.status != entry.status || !terminal && Date().timeIntervalSince(self.metadataDates[id]!) >= self.enrichmentAge
                let expanded = self.expandedLoads.contains(id)
                let compactChecks = self.monitoring && self.compactTracked.contains(id) && !self.compactFinalized.contains(id)
                let needsChecks = !terminal || entry.status == "failed" || expanded || compactChecks
                let checksDue = (!terminal || self.checkStates[id] != .failed) && (compactChecks && terminal || self.summaryDates[id] == nil || expanded && !self.fullyLoadedChecks.contains(id) || !terminal && Date().timeIntervalSince(self.summaryDates[id]!) >= self.enrichmentAge)
                guard needsMetadata || needsChecks && checksDue else { continue }
                do {
                    let credential = try token(context.connection)
                    if needsMetadata {
                        self.metadataStates[id] = .loading
                        let pipeline = try await client.pipeline(connection: context.connection, id: id, token: credential)
                        guard pipeline.id == id, pipeline.ref == entry.branch,
                              entry.sha == nil || pipeline.sha == entry.sha,
                              pipeline.projectID == nil || pipeline.projectID == context.connection.projectID,
                              JenkinsClient.sameOrigin(pipeline.webURL, context.connection.baseURL) else { throw CIError.invalidResponse }
                        guard self.acceptsEnrichment(revision, context) else { return }
                        self.enrichedPipelines[id] = pipeline; self.metadataDates[id] = Date()
                        if self.commitTitles[pipeline.sha] == nil, !self.commitFailures.contains(pipeline.sha) {
                            do {
                                let commit = try await client.commit(connection: context.connection, sha: pipeline.sha, token: credential)
                                guard self.acceptsEnrichment(revision, context) else { return }
                                guard commit.id == pipeline.sha else { throw CIError.invalidResponse }
                                self.commitTitles[pipeline.sha] = commit.title
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                guard self.acceptsEnrichment(revision, context) else { return }
                                self.commitFailures.insert(pipeline.sha); self.metadataStates[id] = .partial
                                self.enrichmentErrors[id] = error as? CIError ?? .network
                                let failure = error as? CIError ?? .network
                                if failure == .authentication || failure == .credential { self.applyRetry(failure) }
                                if case .rateLimited = failure { self.applyRetry(failure) }
                            }
                        } else if self.commitFailures.contains(pipeline.sha) { self.metadataStates[id] = .partial }
                        if self.metadataStates[id] == .loading { self.metadataStates[id] = .loaded }
                    }
                    // The metadata response may already be terminal even if the preceding feed was running.
                    let status = self.enrichedPipelines[id]?.status ?? entry.status
                    let nowTerminal = ["success", "failed", "canceled", "skipped"].contains(status)
                    let finalCompact = nowTerminal && self.monitoring && self.compactTracked.contains(id) && !self.compactFinalized.contains(id)
                    guard (!nowTerminal || status == "failed" || self.expandedLoads.contains(id) || finalCompact) && (checksDue || finalCompact && self.checkStates[id] != .failed) else { continue }
                    if finalCompact { self.childDetails = [:] }
                    self.checkStates[id] = .loading
                    if self.selectedPipelineID == id { self.loadingDetails = true }
                    let root: CIPipelineDetails
                    if nowTerminal, !finalCompact, let cached = self.rootDetails[id] { root = cached }
                    else { root = try await client.details(connection: context.connection, pipelineID: id, token: credential) }
                    guard self.acceptsEnrichment(revision, context) else { return }
                    self.rootDetails[id] = root
                    let causeOnly = nowTerminal && status == "failed" && !self.expandedLoads.contains(id) && !self.compactTracked.contains(id)
                    let progress: CIProgressSummary
                    if causeOnly, root.jobs.contains(where: { $0.status == "failed" && !$0.allowFailure }) {
                        progress = CIProgressSummary(jobs: root.jobs, bridges: root.bridges, complete: root.bridgeError == nil)
                    } else {
                        progress = try await client.progress(connection: context.connection, pipelineID: id, token: credential, root: root, failedOnly: causeOnly) { [weak self] childConnection, childID in
                            guard let self else { throw CancellationError() }
                            return try await self.loadChild(childConnection, id: childID, credential: credential, cache: nowTerminal, revision: revision, context: context)
                        }
                    }
                    guard self.acceptsEnrichment(revision, context) else { return }
                    if finalCompact { self.compactFinalized.insert(id) }
                    self.summaries[id] = progress; self.summaryDates[id] = Date()
                    if !causeOnly { self.fullyLoadedChecks.insert(id) }
                    self.checkStates[id] = progress.complete ? .loaded : .partial
                    if self.metadataStates[id] != .partial { self.enrichmentErrors[id] = nil }
                    if self.selectedPipelineID == id { self.details = root; self.loadingDetails = false; self.detailError = nil }
                } catch {
                    guard self.acceptsEnrichment(revision, context) else { return }
                    let failure = error as? CIError ?? .network
                    if self.metadataStates[id] == .loading { self.metadataStates[id] = .failed; self.metadataDates[id] = Date() }
                    if self.checkStates[id] == .loading { self.checkStates[id] = .failed; self.summaryDates[id] = Date() }
                    self.enrichmentErrors[id] = failure; self.applyRetry(failure)
                    if self.selectedPipelineID == id { self.detailError = failure; self.loadingDetails = false }
                    if failure.pausesPolling || self.retryAt != nil { return }
                }
            }
        }
    }

    private func loadChild(_ connection: GitLabConnection, id: Int, credential: String, cache: Bool, revision: UUID, context: CIContext) async throws -> CIPipelineDetails {
        let key = "\(connection.projectID):\(id)"
        if cache, let value = self.childDetails[key] { return value }
        let value = try await self.client.details(connection: connection, pipelineID: id, token: credential)
        guard self.acceptsEnrichment(revision, context) else { throw CancellationError() }
        if cache { self.childDetails[key] = value }
        return value
    }

    private func acceptsEnrichment(_ revision: UUID, _ context: CIContext) -> Bool {
        self.enrichmentRevision == revision && self.context == context && self.polling && self.enriching && !Task.isCancelled
    }

    private func cancelRequests() {
        self.revision = UUID(); self.detailRevision = UUID(); self.task?.cancel(); self.task = nil; self.detailTask?.cancel(); self.detailTask = nil
        self.searchRevision = UUID(); self.searchTask?.cancel(); self.searchTask = nil; self.searching = false; self.searchResults = []
        self.loading = false; self.loadingDetails = false
    }
}
