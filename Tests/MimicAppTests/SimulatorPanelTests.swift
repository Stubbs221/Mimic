//
//  SimulatorPanelTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 07.10.2026.
import AppKit
import SwiftUI
import Testing
import Combine
import Observation
import MimicCore
@testable import Mimic

private actor PanelCatalogFixture {
    private(set) var projects: [ProjectContext] = []
    private var pending: [CheckedContinuation<SimulatorCatalogSnapshot, any Error>] = []
    func fetch(_ project: ProjectContext) async throws -> SimulatorCatalogSnapshot {
        self.projects.append(project)
        return try await withCheckedThrowingContinuation { self.pending.append($0) }
    }
    func finish(_ result: Result<SimulatorCatalogSnapshot, any Error>) { self.pending.removeFirst().resume(with: result) }
}

private actor PanelInspectionFixture {
    private var pending: CheckedContinuation<ProjectContext, any Error>?
    var started: Bool { pending != nil }
    func fetch(_ project: ProjectContext) async throws -> ProjectContext {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ project: ProjectContext) { pending?.resume(returning: project); pending = nil }
}

/// Observation's callback is Sendable even though this fixture mutates on the main actor.
private final class PanelObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Check the card's response to its real grid proposal before an outside frame can hide overflow.
private struct SimulatorCardProposal: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 238
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: 160))
        #expect(abs(size.width - width) < 0.5)
        #expect(abs(size.height - 160) < 0.5)
        return CGSize(width: width, height: 160)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

private struct SimulatorPanelGit: GitBranchService {
    func inspect(_ project: ProjectContext) async throws -> GitCheckoutState { .init(project: project, summary: GitSummary(porcelain: ""), hasOperation: false) }
    func branches(_ project: ProjectContext) async throws -> [LocalBranch] { [] }
    func switchBranch(_ name: String, project: ProjectContext) async throws -> GitCheckoutState { throw BranchError.missing }
}

@MainActor private final class PanelUsageFixture: SimulatorUsageStore {
    var usage = SimulatorUsage()
    func load() -> SimulatorUsage { self.usage }
    func save(_ usage: SimulatorUsage) { self.usage = usage }
}

@MainActor private final class PanelOpenerFixture {
    var opened: [UUID] = []
    var fails = false
    func open(_ device: SimulatorDevice, developer: String) throws {
        if self.fails { throw MimicError.invalidSimulator }
        self.opened.append(device.id)
    }
}

@MainActor private struct SimulatorPanelFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-simulator-panel-" + UUID().uuidString)
    let suite = "Mimic-simulator-panel-" + UUID().uuidString
    let defaults: UserDefaults
    let model: TaskCoordinator
    let catalog = PanelCatalogFixture()
    let opener = PanelOpenerFixture()
    let project = ProjectContext(path: "/private/tmp/Mimic-simulator-panel-fixture", branch: "fixture", commit: "fixture", developerDirectory: "/fixture/Xcode/Contents/Developer")
    init(usage: PanelUsageFixture? = nil, inspect: (@Sendable (ProjectContext) async throws -> ProjectContext)? = nil) throws {
        self.defaults = try #require(UserDefaults(suiteName: self.suite))
        let catalog = self.catalog, opener = self.opener
        var services = SimulatorPanelServices(catalog: { try await catalog.fetch($0) }, inspect: { $0 }, open: { try opener.open($0, developer: $1) })
        if let inspect { services.inspect = inspect }
        self.model = TaskCoordinator(directory: self.directory, simulatorServices: services, branchService: SimulatorPanelGit(), usageStore: usage, defaults: self.defaults)
        self.model.projects = [self.project]; self.model.selectedProjectPath = self.project.path
    }
    func install(_ devices: [SimulatorDevice]) { self.model.installSimulatorPreview(devices, developer: self.project.developerDirectory!); self.model.readiness[.simulatorBoot] = [] }
    func holdQueue() { var record = TaskRecord(action: .format, project: self.project); record.status = .running; self.model.records = [record] }
    func cleanUp() { self.model.panelVisibilityChanged(false); self.defaults.removePersistentDomain(forName: self.suite); try? FileManager.default.removeItem(at: self.directory) }
}

@Suite(.serialized) @MainActor
struct SimulatorPanelTests {
    @Test func backgroundRefreshDoesNotInvalidateInitialLoadingReaders() {
        let panel = SimulatorPanelState()
        let initial = PanelObservationCounter()
        withObservationTracking { _ = panel.initialLoading } onChange: { initial.increment() }
        panel.loading = true
        #expect(initial.value == 1)
        panel.apply(devices: [self.device()], usage: SimulatorUsage(), developer: "/Xcode")
        let background = PanelObservationCounter()
        withObservationTracking { _ = panel.initialLoading } onChange: { background.increment() }
        panel.loading = false; panel.loading = true
        #expect(!panel.initialLoading && background.value == 0)
    }
    @Test func heartbeatDoesNotPublishOrPersistUnchangedCheckout() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        var publications = 0
        let subscription = fixture.model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<3 { await fixture.model.refreshPanelContext(fixture.project.path) }
        #expect(publications == 0)
        #expect(fixture.defaults.data(forKey: "projects") == nil)
    }

    @Test func heartbeatCommitsChangedCheckout() async throws {
        var checked = ProjectContext(path: "/private/tmp/Mimic-simulator-panel-fixture", branch: "next", commit: "next")
        let replacement = checked
        let fixture = try SimulatorPanelFixture(inspect: { _ in replacement }); defer { fixture.cleanUp() }
        await fixture.model.refreshPanelContext(fixture.project.path)
        #expect(fixture.model.projects == [replacement])
        #expect(fixture.defaults.data(forKey: "projects") != nil)
        checked.commit = "newer"
        fixture.model.projects = [checked]
        await fixture.model.refreshPanelContext("/different-checkout")
        #expect(fixture.model.projects == [checked])
    }

    @Test func heartbeatDiscardsLateInspectionAfterContextReplacement() async throws {
        let inspection = PanelInspectionFixture()
        let fixture = try SimulatorPanelFixture(inspect: { try await inspection.fetch($0) }); defer { fixture.cleanUp() }
        let refresh = Task { await fixture.model.refreshPanelContext(fixture.project.path) }
        for _ in 0..<1000 {
            if await inspection.started { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(await inspection.started)
        var replacement = fixture.project; replacement.commit = "newer"
        fixture.model.projects = [replacement]
        var late = fixture.project; late.commit = "late"
        await inspection.finish(late)
        await refresh.value
        #expect(fixture.model.projects == [replacement])
        #expect(fixture.defaults.data(forKey: "projects") == nil)
    }

    @Test func unchangedCatalogueAndAIUpdatesStayOutOfTaskOwner() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        let devices = (0..<87).map { self.device("Device \($0)", booted: $0 < 3) }
        fixture.install(devices)
        var publications = 0
        let subscription = fixture.model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        fixture.model.refreshSimulators(); try await self.waitForCatalog(fixture, count: 1)
        await fixture.catalog.finish(.success(.init(devices: devices, developer: fixture.project.developerDirectory!)))
        try await self.wait { !fixture.model.loadingSimulators }
        fixture.model.aiUsage.objectWillChange.send()
        fixture.model.ciMonitor.objectWillChange.send()
        #expect(publications == 0)
        #expect(fixture.model.simulatorPresentation.ordered.count == 87)
    }

    @Test func preparedCatalogueIgnoresIdenticalSnapshot() throws {
        let panel = SimulatorPanelState()
        let devices = [self.device(), self.device()]
        panel.apply(devices: devices, usage: SimulatorUsage(), developer: "/Xcode")
        let changes = PanelObservationCounter()
        withObservationTracking { _ = panel.presentation } onChange: { changes.increment() }
        panel.apply(devices: devices, usage: SimulatorUsage(), developer: "/Xcode")
        #expect(changes.value == 0)
        #expect(panel.presentation.shortID(devices[0]) != panel.presentation.shortID(devices[1]))
    }
    private func device(_ name: String = "iPhone 17 Pro", runtime: String = "iOS 27.0", booted: Bool = false, id: UUID = UUID()) -> SimulatorDevice {
        .init(id: id, name: name, runtime: runtime, state: booted ? "Booted" : "Shutdown")
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(2)) }
        Issue.record("Timed out waiting for simulator fixture")
    }
    private func waitForCatalog(_ fixture: SimulatorPanelFixture, count: Int) async throws {
        for _ in 0..<1000 { if await fixture.catalog.projects.count == count { return }; try await Task.sleep(for: .milliseconds(2)) }
        Issue.record("Timed out waiting for catalogue request")
    }

    @Test(arguments: [1, 2])
    func compactSlotsFillTheirContainer(columns: Int) {
        let bounds = CGRect(x: 12, y: 20, width: 240, height: 104)
        for count in 1...(columns * 2) {
            let frames = SimulatorCompactLayout(columns: columns).frames(in: bounds, count: count)
            #expect(frames.count == count)
            #expect(frames.reduce(CGRect.null) { $0.union($1) } == bounds)
            for (index, frame) in frames.enumerated() {
                #expect(bounds.contains(frame))
                #expect(frame.height == frames[0].height)
                for other in frames.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
            }
            if columns == 2 && count == 3 {
                #expect(frames[2].width == bounds.width)
                #expect(frames[1].minX - frames[0].maxX == 8)
                #expect(frames[2].minY - frames[0].maxY == 8)
            }
            if count == 1 { #expect(frames == [bounds]) }
        }
        #expect(SimulatorCompactLayout(columns: columns).frames(in: bounds, count: 0).isEmpty)
    }

    // MARK: - Selection and identity

    @Test func compactOnlyContainsBootedAndSuccessfulHistoryWithTwoOrFourSlots() {
        let devices = (0..<9).map { self.device("Device \($0)", booted: $0 < 2) }
        var usage = SimulatorUsage()
        usage.record(devices[3].id, developer: "A", at: Date(timeIntervalSince1970: 10))
        usage.record(devices[4].id, developer: "A", at: Date(timeIntervalSince1970: 20))
        usage.record(devices[0].id, developer: "A", at: Date(timeIntervalSince1970: 30))
        let value = SimulatorPresentation(devices: devices + [devices[0]], usage: usage, developer: "A")
        #expect(value.compact(full: false).map(\.id) == [devices[0].id, devices[1].id])
        #expect(value.compact(full: true).map(\.id) == [devices[0].id, devices[1].id, devices[4].id, devices[3].id])
        #expect(SimulatorPresentation(devices: [devices[8]], usage: usage, developer: "A").compact(full: true).isEmpty)
        #expect(SimulatorPresentation(devices: devices, usage: usage, developer: "B").compact(full: true).count == 2)
    }

    @Test func filtersSearchAndDuplicateIdentityUseTheWholeCatalogue() throws {
        let first = self.device("Mimic Apple Probe", booted: true, id: try #require(UUID(uuidString: "12340000-0000-0000-0000-000000000001")))
        let second = self.device("Mimic Apple Probe", booted: true, id: try #require(UUID(uuidString: "12350000-0000-0000-0000-000000000002")))
        let tv = self.device("Apple TV 4K (3rd generation) (at 1080p)", runtime: "tvOS 27.0")
        var usage = SimulatorUsage(); usage.record(tv.id, developer: "A")
        let value = SimulatorPresentation(devices: [second, tv, first], usage: usage, developer: "A")
        #expect(value.shortID(first) == "1234" && value.shortID(second) == "1235" && value.shortID(tv) == nil)
        #expect(value.catalog(filter: .recent, search: "  tvOS  ").map(\.id) == [tv.id])
        #expect(value.catalog(filter: .booted, search: "tvOS").isEmpty)
        #expect(value.catalog(filter: .all, search: first.id.uuidString).map(\.id) == [first.id])
        #expect(SimulatorPresentation.symbol(tv) == "appletv")
        #expect(SimulatorPresentation.symbol(self.device("iPad Air")) == "ipad")
    }

    @Test func forgettingIsPersistentAndIsolatedByXcodeWhileRunningDeviceRemains() throws {
        let usage = PanelUsageFixture(), running = self.device(booted: true), off = self.device("iPad")
        let developer = "/fixture/Xcode/Contents/Developer"
        usage.usage.record(running.id, developer: developer); usage.usage.record(off.id, developer: developer); usage.usage.record(off.id, developer: "B")
        let fixture = try SimulatorPanelFixture(usage: usage); defer { fixture.cleanUp() }; fixture.install([running, off])
        fixture.model.forgetSimulator(off); fixture.model.forgetSimulator(running)
        #expect(fixture.model.simulatorPresentation.compact(full: true).map(\.id) == [running.id])
        #expect(usage.usage.dates[developer]?.isEmpty == true && usage.usage.dates["B"]?[off.id] != nil)
    }

    // MARK: - Discovery, context and visibility

    @Test func refreshRetainsCardsCoalescesRequestsAndMarksFailuresStale() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        let device = self.device(booted: true); fixture.install([device])
        fixture.model.refreshSimulators(); fixture.model.refreshSimulators()
        try await self.waitForCatalog(fixture, count: 1)
        #expect(fixture.model.simulators == [device] && fixture.model.loadingSimulators)
        await fixture.catalog.finish(.failure(MimicError.invalidSimulator))
        try await self.wait { !fixture.model.loadingSimulators }
        #expect(fixture.model.simulatorStale && fixture.model.simulators == [device] && !fixture.model.canActivateSimulator(device))
        fixture.model.refreshSimulators(); try await self.waitForCatalog(fixture, count: 2)
        #expect(fixture.model.simulatorStale)
        await fixture.catalog.finish(.success(.init(devices: [device], developer: fixture.project.developerDirectory!)))
        try await self.wait { !fixture.model.loadingSimulators }
        #expect(!fixture.model.simulatorStale && fixture.model.canActivateSimulator(device))
    }

    @Test(arguments: [true, false])
    func oldContextResponseIsDiscardedAndNextContextWaitsForInFlightQuery(sameCheckout: Bool) async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }; fixture.install([self.device(booted: true)])
        fixture.model.refreshSimulators(); try await self.waitForCatalog(fixture, count: 1)
        let next = ProjectContext(path: sameCheckout ? fixture.project.path : "/private/tmp/other-fixture", branch: "fixture", commit: "fixture", developerDirectory: "/fixture/Xcode-B/Contents/Developer")
        if sameCheckout { fixture.model.projects = [next] } else { fixture.model.projects.append(next) }
        fixture.model.selectedProjectPath = next.path; fixture.model.refreshSimulators()
        #expect(fixture.model.simulators.isEmpty && fixture.model.simulatorDeveloper.isEmpty)
        #expect(await fixture.catalog.projects.count == 1)
        await fixture.catalog.finish(.success(.init(devices: [self.device("Old")], developer: fixture.project.developerDirectory!)))
        try await self.waitForCatalog(fixture, count: 2)
        #expect(fixture.model.simulators.isEmpty)
        let newDevice = self.device("New")
        await fixture.catalog.finish(.success(.init(devices: [newDevice], developer: next.developerDirectory!)))
        try await self.wait { !fixture.model.loadingSimulators }
        #expect(fixture.model.simulators == [newDevice] && fixture.model.simulatorDeveloper == next.developerDirectory)
    }

    @Test func pollingStopsOnHiddenPanelSettingsAndHiddenBlock() throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        #expect(!fixture.model.shouldPollSimulators(blockVisible: true))
        fixture.model.panelVisibilityChanged(true)
        #expect(fixture.model.shouldPollSimulators(blockVisible: true))
        #expect(!fixture.model.shouldPollSimulators(blockVisible: false))
        fixture.model.openSettings()
        #expect(!fixture.model.shouldPollSimulators(blockVisible: true))
        fixture.model.returnHome(); fixture.model.panelVisibilityChanged(false)
        #expect(!fixture.model.shouldPollSimulators(blockVisible: true))
    }

    // MARK: - Admission and request-bound automatic opening

    @Test func simulatorReadinessDoesNotRequireAProfileBinding() throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        let device = self.device(); fixture.install([device])
        fixture.model.checkReadiness()
        #expect(fixture.model.readiness[.simulatorBoot] == [])
        #expect(fixture.model.readiness[.simulatorShutdown] == [])
        #expect(fixture.model.canActivateSimulator(device))
    }

    @Test func doubleClickReservesBeforeAdmissionAndKeepsCurrentScreen() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }; let device = self.device(); fixture.install([device]); fixture.holdQueue()
        fixture.model.activateSimulator(device); fixture.model.activateSimulator(device)
        #expect(fixture.model.simulatorAdmissions.count == 1 && fixture.model.simulatorBusy(device))
        try await self.wait { fixture.model.records.count == 2 }
        #expect(fixture.model.records.filter { $0.simulator?.id == device.id }.count == 1)
        #expect(fixture.model.expandedSection == nil && fixture.model.selectedTaskID == nil)
        #expect(fixture.model.simulatorPendingRecord(device)?.status == .queued)
        let record = try #require(fixture.model.records.last)
        fixture.model.cancel(id: record.id)
        #expect(!fixture.model.simulatorBusy(device) && fixture.opener.opened.isEmpty)
    }

    @Test(arguments: [TaskStatus.succeeded, .failed, .cancelled])
    func onlySuccessfulBootOpensExactlyOnce(status: TaskStatus) async throws {
        let usage = PanelUsageFixture(), fixture = try SimulatorPanelFixture(usage: usage); defer { fixture.cleanUp() }
        let device = self.device(); fixture.install([device]); fixture.holdQueue(); fixture.model.activateSimulator(device)
        try await self.wait { fixture.model.records.count == 2 && fixture.model.simulatorAdmissions.isEmpty }
        var record = try #require(fixture.model.records.last); record.status = status
        fixture.model.completeSimulatorOperation(record, developer: fixture.project.developerDirectory)
        fixture.model.completeSimulatorOperation(record, developer: fixture.project.developerDirectory)
        if status == .succeeded { try await self.wait { fixture.opener.opened.count == 1 } }
        #expect(fixture.opener.opened.count == (status == .succeeded ? 1 : 0))
        #expect((usage.usage.dates[fixture.project.developerDirectory!]?[device.id] != nil) == (status == .succeeded))
    }

    @Test func changedContextAndCancelledRequestNeverOpenOnLateSuccess() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }; let device = self.device(); fixture.install([device]); fixture.holdQueue()
        fixture.model.activateSimulator(device); try await self.wait { fixture.model.records.count == 2 && fixture.model.simulatorAdmissions.isEmpty }
        var record = try #require(fixture.model.records.last)
        fixture.model.cancel(id: record.id); record.status = .succeeded
        fixture.model.completeSimulatorOperation(record, developer: fixture.project.developerDirectory)
        #expect(fixture.opener.opened.isEmpty)
        fixture.model.activateSimulator(device); try await self.wait { fixture.model.records.count == 3 && fixture.model.simulatorAdmissions.isEmpty }
        record = try #require(fixture.model.records.last); record.status = .succeeded
        fixture.model.selectedProjectPath = ""
        fixture.model.completeSimulatorOperation(record, developer: fixture.project.developerDirectory)
        #expect(fixture.opener.opened.isEmpty)
    }

    @Test func admissionFailureAndWindowFailureStayOnDevice() async throws {
        let fixture = try SimulatorPanelFixture(inspect: { _ in throw MimicError.invalidSimulator }); defer { fixture.cleanUp() }
        let off = self.device(), running = self.device("iPad", booted: true); fixture.install([off, running])
        fixture.model.activateSimulator(off); try await self.wait { fixture.model.simulatorAdmissions.isEmpty }
        #expect(fixture.model.simulatorFailure(off) != nil && fixture.model.records.isEmpty)
        fixture.opener.fails = true; fixture.model.activateSimulator(running); try await self.wait { fixture.model.simulatorOpening.isEmpty }
        #expect(fixture.model.simulatorFailure(running)?.message.hasPrefix(text("simulators.open.error")) == true)
        #expect(fixture.model.simulatorFailure(running)?.message.contains(MimicError.invalidSimulator.localizedDescription) == true)
    }


    @Test func shutdownUsesTheSameReservationAndFailureLinksToItsTask() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }; let device = self.device(booted: true)
        fixture.install([device]); fixture.holdQueue()
        fixture.model.requestSimulator(.simulatorShutdown, device: device); fixture.model.requestSimulator(.simulatorShutdown, device: device)
        try await self.wait { fixture.model.records.count == 2 && fixture.model.simulatorAdmissions.isEmpty }
        #expect(fixture.model.records.last?.action == .simulatorShutdown && fixture.model.simulatorPendingRecord(device) != nil)
        fixture.model.records[1].status = .failed; fixture.model.records[1].error = "Fixture shutdown failure"
        #expect(fixture.model.simulatorFailure(device)?.taskID == fixture.model.records[1].id)
        fixture.model.activateSimulator(device); try await self.wait { fixture.opener.opened == [device.id] }
        #expect(fixture.model.simulatorFailure(device) == nil)
    }

    /// Requires a launched AppKit test host; the command-line SwiftPM helper exposes no AX tree.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_SIMULATOR_AX_FIXTURE"] == "1"))
    func accessibilityPressOpensDeviceAndPollingRetainsItsIdentity() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }; let device = self.device(booted: true); fixture.install([device])
        let view = NSHostingView(rootView: self.card(fixture.model, full: false))
        let window = NSWindow(contentRect: NSRect(x: 250, y: 300, width: 238, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(50)); view.layoutSubtreeIfNeeded()
        let identifier = "simulator.activate." + device.id.uuidString
        let button = try #require(self.find(view, identifier))
        #expect(button.accessibilityRole() == .button)
        #expect((button.accessibilityValue() as? String)?.contains("iOS 27.0") == true)
        #expect(self.find(view, "simulator.actions." + device.id.uuidString) != nil)
        #expect(button.accessibilityPerformPress())
        try await self.wait { fixture.opener.opened == [device.id] && fixture.model.simulatorOpening.isEmpty }
        fixture.model.refreshSimulators(); try await self.waitForCatalog(fixture, count: 1)
        await fixture.catalog.finish(.success(.init(devices: [device], developer: fixture.project.developerDirectory!)))
        try await self.wait { !fixture.model.loadingSimulators }; view.layoutSubtreeIfNeeded()
        let refreshed = try #require(self.find(view, identifier))
        let preservesIdentity = (button as AnyObject) === (refreshed as AnyObject)
        #expect(preservesIdentity)
    }

    // MARK: - Catalogue pagination

    @Test(arguments: [0, 1, 8, 9, 16, 17])
    func cataloguePagesKeepOrderingWithoutDuplicates(count: Int) throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        fixture.install((0..<count).map { self.device("iPhone \($0)") })
        let ordered = fixture.model.simulatorPresentation.catalog(filter: .all, search: "").map(\.id)
        var visited: [UUID] = []
        let pages = max(1, (count + 7) / 8)
        #expect(fixture.model.simulatorCatalogPage.count == pages)
        for index in 0..<pages {
            let page = fixture.model.simulatorCatalogPage
            #expect(page.index == index)
            #expect(page.devices.count == min(8, count - index * 8))
            visited.append(contentsOf: page.devices.map(\.id))
            fixture.model.moveSimulatorPage(by: 1)
        }
        #expect(visited == ordered && Set(visited).count == count)
        #expect(fixture.model.simulatorCatalogPage.index == pages - 1)
        for index in (0..<pages).reversed() {
            #expect(fixture.model.simulatorCatalogPage.devices.map(\.id) == Array(ordered.dropFirst(index * 8).prefix(8)))
            fixture.model.moveSimulatorPage(by: -1)
        }
        #expect(fixture.model.simulatorPageIndex == 0)
    }

    @Test func cataloguePageResetsForSearchFilterProjectAndReopening() throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        let model = fixture.model
        fixture.install((0..<17).map { self.device("iPhone \($0)", booted: $0 < 9) })
        model.expandedSection = .simulators
        model.moveSimulatorPage(by: 2)
        let target = try #require(model.simulatorCatalogPage.devices.first)
        model.simulatorSearch = target.id.uuidString
        #expect(model.simulatorPageIndex == 0 && model.simulatorCatalogPage.devices.map(\.id) == [target.id])
        model.simulatorSearch = ""; model.moveSimulatorPage(by: 2)
        model.simulatorFilter = .booted
        #expect(model.simulatorPageIndex == 0 && model.simulatorCatalogPage.devices.count == 8 && model.simulatorCatalogPage.count == 2)
        model.moveSimulatorPage(by: 1)
        #expect(model.simulatorCatalogPage.devices.count == 1)
        model.simulatorFilter = .all; model.moveSimulatorPage(by: 2)
        model.expandedSection = nil; model.expandedSection = .simulators
        #expect(model.simulatorPageIndex == 0)
        model.moveSimulatorPage(by: 2)
        model.selectedProjectPath = "/private/tmp/other-pagination-fixture"
        #expect(model.simulatorPageIndex == 0)
    }

    @Test func catalogueRefreshKeepsPageAndClampsAfterRemoval() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        let devices = (0..<17).map { self.device("iPhone \($0)") }; fixture.install(devices)
        fixture.model.moveSimulatorPage(by: 2)
        fixture.model.refreshSimulators(); try await self.waitForCatalog(fixture, count: 1)
        await fixture.catalog.finish(.success(.init(devices: devices, developer: fixture.project.developerDirectory!)))
        try await self.wait { !fixture.model.loadingSimulators }
        #expect(fixture.model.simulatorPageIndex == 2 && fixture.model.simulatorCatalogPage.devices.count == 1)
        fixture.model.refreshSimulators(); try await self.waitForCatalog(fixture, count: 2)
        await fixture.catalog.finish(.success(.init(devices: Array(devices.prefix(9)), developer: fixture.project.developerDirectory!)))
        try await self.wait { !fixture.model.loadingSimulators }
        #expect(fixture.model.simulatorPageIndex == 1 && fixture.model.simulatorCatalogPage.devices.count == 1)
        fixture.install(devices)
        #expect(fixture.model.simulatorPageIndex == 1)
        fixture.install([])
        #expect(fixture.model.simulatorPageIndex == 0 && fixture.model.simulatorCatalogPage.devices.isEmpty)
    }

    @Test(arguments: [0, 1, 8, 9, 16, 17])
    func cataloguePaginationRendersPages(count: Int) async throws {
        _ = NSApplication.shared
        // SwiftPM has no AX children; enable button presses only in a launched AppKit fixture.
        let accessibilityHost = ProcessInfo.processInfo.environment["MIMIC_SIMULATOR_AX_FIXTURE"] == "1"
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        let devices = (0..<count).map { self.device($0 == 0 ? "iPad Pro 13-inch Mobile Platform Infrastructure Development" : "iPhone \($0)", booted: true) }
        fixture.install(devices)
        for dark in [false, true] {
            let width: CGFloat = dark ? 400 : 528
            let root = SimulatorCatalogContent(model: fixture.model).padding(12).frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.mimicPanelAppearance, .tileGrid).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: CGRect(x: 250, y: 300, width: width, height: max(100, host.fittingSize.height)), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width == width)
            for index in 0..<fixture.model.simulatorCatalogPage.count {
                let page = fixture.model.simulatorCatalogPage
                #expect(page.index == index)
                if accessibilityHost {
                    if count <= 8 { #expect(self.find(host, "simulators.pagination") == nil) }
                    else {
                        let previous = try #require(self.find(host, "simulators.page.previous"))
                        let next = try #require(self.find(host, "simulators.page.next"))
                        #expect(previous.isAccessibilityEnabled() == (index > 0))
                        #expect(next.isAccessibilityEnabled() == (index < page.count - 1))
                        let position = try #require(self.find(host, "simulators.page.position"))
                        #expect(abs(position.accessibilityFrame().midX - (previous.accessibilityFrame().minX + next.accessibilityFrame().maxX) / 2) < 2)
                    }
                    for device in devices {
                        let card = self.find(host, "simulator.activate." + device.id.uuidString)
                        #expect((card != nil) == page.devices.contains(where: { $0.id == device.id }))
                        if card != nil { #expect(self.find(host, "simulator.actions." + device.id.uuidString) != nil) }
                    }
                }
                if let path = ProcessInfo.processInfo.environment["MIMIC_SIMULATOR_PREVIEW_DIR"] {
                    let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("pagination-\(count)-\(index)-\(dark).png"))
                }
                if index < page.count - 1 {
                    if accessibilityHost {
                        let next = try #require(self.find(host, "simulators.page.next"))
                        #expect(next.accessibilityPerformPress())
                    } else { fixture.model.moveSimulatorPage(by: 1) }
                    try await self.wait { fixture.model.simulatorPageIndex == index + 1 }
                    try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
                }
            }
            if count > 8 {
                if accessibilityHost {
                    let previous = try #require(self.find(host, "simulators.page.previous"))
                    #expect(previous.accessibilityPerformPress())
                } else { fixture.model.moveSimulatorPage(by: -1) }
                try await self.wait { fixture.model.simulatorPageIndex == fixture.model.simulatorCatalogPage.count - 2 }
            }
            fixture.model.expandedSection = nil; fixture.model.expandedSection = .simulators
        }
    }

    private func find(_ node: any NSAccessibilityProtocol, _ identifier: String, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
        guard depth < 30 else { return nil }
        if node.accessibilityIdentifier() == identifier { return node }
        for child in node.accessibilityChildren() ?? [] {
            if let element = child as? any NSAccessibilityProtocol, let match = self.find(element, identifier, depth: depth + 1) { return match }
        }
        return nil
    }

    // MARK: - Production geometry and accessibility

    @Test func simulatorWindowResolvesSelectedXcodeLayoutsAndTargetsExactDevice() throws {
        let developer = "/Applications/Xcode Example.app/Contents/Developer"
        let legacy = developer + "/Applications/Simulator.app"
        let modern = "/Applications/Xcode Example.app/Contents/Applications/DeviceHub.app"
        #expect(try SimulatorWindowTarget.application(developer: developer, exists: { $0 == legacy }).path == legacy)
        #expect(try SimulatorWindowTarget.application(developer: developer, exists: { $0 == modern }).path == modern)
        #expect(throws: MimicError.self) { try SimulatorWindowTarget.application(developer: developer, exists: { _ in false }) }
        let id = UUID(), url = try #require(URLComponents(url: SimulatorWindowTarget.deviceURL(id), resolvingAgainstBaseURL: false))
        #expect(url.scheme == "devices" && url.host == "device" && url.path == "/open")
        #expect(url.queryItems == [URLQueryItem(name: "id", value: id.uuidString)])
    }

    @Test func productionCardFitsMiniSlotWithRetainedCatalogueAndOpeningFailures() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        let devices = [self.device("Mimic Apple Probe", booted: true), self.device("Mimic Apple Probe", booted: true),
                       self.device("iPad Pro 13-inch Mobile Platform Infrastructure Development", booted: true)]
        fixture.install(devices)
        fixture.opener.fails = true; fixture.model.activateSimulator(devices[0])
        try await self.wait { fixture.model.simulatorFailure(devices[0]) != nil }
        fixture.model.motionSettings.reduceMotionOverride = true
        for full in [false, true] {
            fixture.model.panelLayout.begin()
            fixture.model.panelLayout.edit { try $0.resize(.simulators, to: full ? .full : .mini) }
            fixture.model.panelLayout.finish()
            for panelWidth in [360.0, 440.0, 480.0, 520.0, 560.0] {
                let width = full ? panelWidth - 32 : (panelWidth - 44) / 2
                let root = SimulatorCardProposal {
                    PanelGrid(model: fixture.model, layout: fixture.model.panelLayout).card(.simulators, row: UUID())
                }.frame(width: width)
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded()
                var activationFrames: [CGRect] = []
                func checkControls(_ view: NSView) {
                    if view is PanelControlRegion.MarkerView, !view.visibleRect.isEmpty {
                        let bounds = host.convert(view.bounds, from: view)
                        #expect(bounds.minX >= -0.5 && bounds.maxX <= width + 0.5)
                        if bounds.width > 40 {
                            activationFrames.append(bounds)
                            #expect(bounds.minY >= -0.5 && bounds.maxY <= 160.5)
                        }
                    }
                    view.subviews.forEach(checkControls)
                }
                checkControls(host)
                #expect(activationFrames.count == (full ? 3 : 2))
                for (index, frame) in activationFrames.enumerated() {
                    for other in activationFrames.dropFirst(index + 1) {
                        #expect(!frame.insetBy(dx: 0.5, dy: 0.5).intersects(other))
                    }
                }
                if panelWidth == 560, let path = ProcessInfo.processInfo.environment["MIMIC_SIMULATOR_PREVIEW_DIR"] {
                    let output = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("production-\(full).png"))
                }
                window.close()
            }
        }
    }

    @Test(arguments: [(0, 0.0), (1, 64.0), (2, 64.0), (4, 136.0), (8, 280.0), (9, 280.0)])
    func catalogShowsAtMostFourCompleteRows(count: Int, height: Double) {
        #expect(SimulatorCatalogContent.viewportHeight(count: count) == CGFloat(height))
    }

    private func card(_ model: TaskCoordinator, full: Bool, width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text("panel.block.simulators"), systemImage: "iphone").font(.system(size: 14, weight: .semibold))
            SimulatorCompactDevices(model: model, full: full, open: {})
        }.padding(SimulatorCompactLayout.tileInsets).frame(width: width ?? (full ? 488 : 238), height: 160).modifier(PanelCardBackground(block: .simulators))
    }

    @Test func compactCardPaddingIsExcludedFromPanelDragging() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        fixture.install([self.device("First", booted: true), self.device("Second", booted: true)])
        let host = NSHostingView(rootView: SimulatorCompactDevices(model: fixture.model, full: false, open: {}).frame(width: 238, height: 112))
        let window = NSWindow(contentRect: NSRect(x: 250, y: 300, width: 238, height: 112), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded()
        for frame in SimulatorCompactLayout(columns: 1).frames(in: host.bounds, count: 2) {
            for x in [frame.minX + 4, frame.maxX - 4] {
                let point = host.convert(CGPoint(x: x, y: frame.midY), to: nil)
                #expect(PanelControlRegion.MarkerView.contains(point, in: host))
            }
        }
        var regions: [CGRect] = []
        func collect(_ view: NSView) {
            if view is PanelControlRegion.MarkerView { regions.append(host.convert(view.bounds, from: view)) }
            view.subviews.forEach(collect)
        }
        collect(host)
        let activation = regions.filter { $0.width > 200 }
        let menus = regions.filter { $0.width < 200 && $0.height >= 28 }
        #expect(activation.count == 2 && menus.count == 2, "Control bounds: \(regions)")
        for menu in menus { #expect(activation.contains { $0.contains(menu) }) }
    }

    @Test(arguments: [1.0, 2.0])
    func compactCardsSupportLargeText(scale: Double) async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        fixture.install([self.device("Mimic Apple Probe", booted: true), self.device("Mimic Apple Probe", booted: true)])
        let output = ProcessInfo.processInfo.environment["MIMIC_SIMULATOR_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for full in [false, true] {
            let width: CGFloat = full ? 528 : 258
            let height = 160 * scale
            let root = VStack(alignment: .leading, spacing: 8) {
                Label(text("panel.block.simulators"), systemImage: "iphone").font(.system(size: 14 * scale, weight: .semibold))
                SimulatorCompactDevices(model: fixture.model, full: full, open: {})
            }.padding(SimulatorCompactLayout.tileInsets).frame(width: width, height: height)
                .modifier(PanelCardBackground(block: .simulators))
                .environment(\.mimicPanelAppearance, .tileGrid).environment(\.mimicTextScale, scale)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: CGRect(x: 250, y: 300, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize == CGSize(width: width, height: height))
            if let output {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("large-text-\(full)-\(scale).png"))
            }
            window.close()
        }
    }

    @Test func rendersRealSizesCountsThemesAndReducedMotion() async throws {
        let fixture = try SimulatorPanelFixture(); defer { fixture.cleanUp() }
        let output = ProcessInfo.processInfo.environment["MIMIC_SIMULATOR_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for count in [0, 1, 2, 3, 4, 8, 9] {
            let devices = (0..<count).map { index in
                self.device(index < 2 ? "Mimic Apple Probe" : index == 2 ? "iPad Pro 13-inch Mobile Platform Infrastructure Development" : "Apple TV 4K (3rd generation) (at 1080p)", runtime: index > 2 ? "tvOS 27.0" : "iOS 27.0", booted: true)
            }
            fixture.install(devices)
            for dark in [false, true] {
                for mode in ["mini", "full", "catalog"] {
                    let style = PanelAppearance(rawValue: ProcessInfo.processInfo.environment["MIMIC_PANEL_APPEARANCE"] ?? "legacy") ?? .legacy
                    let width: CGFloat = mode == "mini" ? (style == .tileGrid ? 258 : 238) : (style == .tileGrid ? 528 : 488)
                    let root = Group {
                        if mode == "catalog" { SimulatorCatalogContent(model: fixture.model).padding(12).frame(width: width).background(Color(nsColor: .windowBackgroundColor)) }
                        else { self.card(fixture.model, full: mode == "full", width: width) }
                    }.environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.mimicPanelAppearance, style)
                        .environment(MimicAppearancePreview(reduceMotion: true, increasedContrast: false))
                    let view = NSHostingView(rootView: root)
                    let height = mode == "catalog" ? max(100, view.fittingSize.height) : 160
                    let window = NSWindow(contentRect: NSRect(x: 250, y: 300, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = view; window.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded()
                    #expect(view.fittingSize.width == width)
                    if mode != "catalog" { #expect(view.fittingSize.height == 160) }
                    if let output {
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("simulators-\(mode)-\(count)-\(dark).png"))
                    }
                    window.close()
                }
            }
        }
    }
}
