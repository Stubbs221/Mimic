//
//  MimicUpdater.swift
//  Mimic
//
//  Created by Василий Маслов on 06.10.2026.
import AppKit
import Combine
import Foundation
import MimicCore
import Sparkle

/// Sparkle transports and verifies releases; the native owner decides when replacing the app is safe.
/// The user driver presents status inline and never opens a scheduled-update window.
@MainActor
final class MimicUpdater: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    enum State: String { case unavailable, idle, checking, current, available, downloading, extracting, waiting, preparing, installing, failed }
    @Published private(set) var state: State = .unavailable
    @Published private(set) var availableVersion = ""
    @Published private(set) var progress: Double?
    @Published var automatic: Bool {
        didSet {
            self.defaults.set(self.automatic, forKey: "mimic.automaticUpdates")
            self.sparkle?.automaticallyChecksForUpdates = self.automatic
            if !self.automatic { self.cancelDownload?() }
            else if let choice = self.pendingChoice { self.pendingChoice = nil; self.beginDownload(choice) }
        }
    }
    private var reservationID = UUID()
    private let defaults: UserDefaults
    private let integration: MimicIntegration
    private let lifecycle: MimicUpdateLifecycle
    private var sparkle: SPUUpdater?
    private var availabilityObservation: AnyCancellable?
    @Published private var updaterCanCheck = false
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var preparationChoice: ((SPUUserUpdateChoice) -> Void)?
    private var installationChoice: ((SPUUserUpdateChoice) -> Void)?
    private var cancelDownload: (() -> Void)?
    private var waitingTask: Task<Void, Never>?
    private var generation = 0
    private(set) var failureCode: Int?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var explicitlyInstalling = false
    var showSettings: (() -> Void)?
    var willRelaunch: (() -> Void)?
    var hasPendingInstallation: Bool { [.waiting, .preparing, .installing].contains(self.state) }
    var canCheck: Bool { self.updaterCanCheck && !self.hasPendingInstallation }
    var status: String {
        let base = text(self.state == .idle && !self.automatic ? "update.state.disabled" : "update.state." + self.state.rawValue)
        return self.availableVersion.isEmpty ? base : base + " · " + self.availableVersion
    }

    init(integration: MimicIntegration, lifecycle: MimicUpdateLifecycle, defaults: UserDefaults = .standard) {
        self.integration = integration; self.lifecycle = lifecycle; self.defaults = defaults
        self.automatic = defaults.object(forKey: "mimic.automaticUpdates") as? Bool ?? true
        super.init()
    }

    func start(bundle: Bundle = .main) {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), self.acceptsFeed(url, bundle: bundle), url.user == nil, url.password == nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, Data(base64Encoded: key)?.count == 32 else { return }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.sparkle = updater
        self.availabilityObservation = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).sink { [weak self] value in self?.updaterCanCheck = value }
        do {
            try updater.start()
            updater.automaticallyChecksForUpdates = self.automatic
            // Our driver accepts downloads automatically, but controls the installation boundary itself.
            // Sparkle's separate silent installer would also install on quit before our final backup/gate.
            updater.automaticallyDownloadsUpdates = false
            self.state = .idle
            if self.automatic { updater.checkForUpdatesInBackground() }
        } catch { self.fail() }
    }
    private func acceptsFeed(_ url: URL, bundle: Bundle) -> Bool {
        #if DEBUG
        if bundle.bundleIdentifier == "local.vmaslov.MimicUpdateFixture", url.scheme == "http", url.host == "127.0.0.1" { return true }
        #endif
        return url.scheme == "https" && url.host != nil
    }
    func check() {
        guard self.canCheck else { return }
        self.state = .checking; self.sparkle?.checkForUpdates()
    }
    func installAvailable() {
        guard let choice = self.pendingChoice else { return }
        self.pendingChoice = nil; self.explicitlyInstalling = true
        self.beginDownload(choice)
    }
    /// Cancel only the update. Local work is left to the ordinary user-initiated quit flow.
    func deferInstallation() {
        self.generation += 1
        self.waitingTask?.cancel(); self.waitingTask = nil
        let choice = self.installationChoice
        let preparation = self.preparationChoice
        self.installationChoice = nil; self.preparationChoice = nil
        self.integration.releaseUpdate(owner: self.reservationID)
        choice?(.skip); preparation?(.dismiss)
        self.state = .idle
    }
    private func beginDownload(_ choice: @escaping (SPUUserUpdateChoice) -> Void) {
        // Avoid an authorization dialog from a scheduled background update.
        let app = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: app.path),
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            self.fail(); choice(.dismiss); return
        }
        self.generation += 1
        let generation = self.generation
        self.preparationChoice = choice
        self.state = .preparing
        self.waitingTask = Task { [weak self] in
            guard let self else { choice(.dismiss); return }
            do {
                // Keep rollback material even if the user normally quits during extraction.
                try await self.lifecycle.prepareBackup()
                guard self.generation == generation else { return }
                self.waitingTask = nil; self.preparationChoice = nil
                guard !Task.isCancelled, self.automatic || self.explicitlyInstalling else { choice(.dismiss); return }
                self.state = .downloading; choice(.install)
            } catch {
                guard self.generation == generation else { return }
                self.waitingTask = nil; self.preparationChoice = nil; self.fail(); choice(.dismiss)
            }
        }
    }
    private func fail() {
        self.integration.releaseUpdate(owner: self.reservationID); self.state = .failed; self.progress = nil
    }

    // MARK: - Inline Sparkle user driver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: self.automatic, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { self.state = .checking }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.availableVersion = item.displayVersionString
        guard !item.isInformationOnlyUpdate else { self.state = .available; reply(.dismiss); return }
        if state.stage == .installing { self.showReady(toInstallAndRelaunch: reply); return }
        if self.automatic { self.beginDownload(reply) }
        else { self.state = .available; self.pendingChoice = reply }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) { }
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        self.state = .current; self.availableVersion = ""; acknowledgement()
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { self.handleAbort(error); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.state = .downloading; self.cancelDownload = cancellation; self.receivedLength = 0; self.progress = nil
    }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) { self.expectedLength = length }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        self.receivedLength = self.receivedLength.addingReportingOverflow(length).partialValue
        self.progress = self.expectedLength > 0 ? min(1, Double(self.receivedLength) / Double(self.expectedLength)) : nil
    }
    func showDownloadDidStartExtractingUpdate() { self.cancelDownload = nil; self.state = .extracting; self.progress = nil }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = min(1, max(0, progress)) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.state = .waiting; self.progress = nil
        self.installationChoice = reply
        self.reservationID = UUID()
        let reservationID = self.reservationID
        self.generation += 1
        let generation = self.generation
        self.waitingTask = Task { [weak self] in
            guard let self else { reply(.skip); return }
            do {
                while !Task.isCancelled && self.generation == generation {
                    guard self.automatic || self.explicitlyInstalling else {
                        self.installationChoice = nil; self.state = .idle; self.waitingTask = nil; reply(.skip); return
                    }
                    if self.integration.developmentUpdateReady {
                        self.state = .preparing
                        let prepared = try await self.integration.prepareUpdate(owner: reservationID)
                        guard self.generation == generation, !Task.isCancelled else {
                            self.integration.releaseUpdate(owner: reservationID); return
                        }
                        if prepared {
                            self.installationChoice = nil; self.waitingTask = nil
                            self.state = .installing; self.willRelaunch?(); reply(.install)
                            return
                        }
                        self.state = .waiting
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch {
                guard self.generation == generation else { return }
                self.fail()
            }
            guard self.generation == generation else { return }
            self.waitingTask = nil
            // Skip at the installing stage cancels replacement, without permanently skipping the version.
            self.integration.releaseUpdate(owner: reservationID)
            if self.installationChoice != nil { self.installationChoice = nil; reply(.skip) }
        }
    }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication retry: @escaping () -> Void) {
        guard !terminated else { return }
        self.waitingTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.state == .installing {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if self.state == .installing, self.integration.model.updateOwner == self.reservationID, self.integration.developmentUpdateReady { retry() }
            }
        }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        self.generation += 1
        self.waitingTask?.cancel(); self.waitingTask = nil; self.pendingChoice = nil; self.preparationChoice = nil; self.installationChoice = nil; self.cancelDownload = nil
        self.explicitlyInstalling = false
        if self.state != .failed && self.state != .current { self.state = .idle }
        self.integration.releaseUpdate(owner: self.reservationID)
    }
    func showUpdateInFocus() { self.showSettings?() }

    // MARK: - Sparkle delegate

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate update: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) { self.handleAbort(error) }
    private func handleAbort(_ error: any Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
            self.state = .current; self.availableVersion = ""
        } else if error.domain == SUSparkleErrorDomain && error.code == SUError.installationCanceledError.rawValue {
            if self.state != .failed { self.state = .idle }
        } else { self.failureCode = error.code; self.fail() }
    }
}
