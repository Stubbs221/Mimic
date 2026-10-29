//
//  XcodeBranchWorkspaces.swift
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import AppKit
import MimicCore

/// Suspends only workspaces belonging to the switching checkout. The journal precedes every close,
/// so cancellation, partial closure and a later Mimic restart can restore the original windows.
@MainActor final class XcodeBranchWorkspaces {
    struct Workspace: Codable, Equatable, Sendable {
        let application: String
        let path: String
    }
    private let defaults: UserDefaults
    private let automation: XcodeBranchWorkspaceAutomation
    private let applications: () -> [String]
    private let open: (Workspace) async throws -> Void
    private var leases: [String: [Workspace]]
    private static let key = "branchSwitchXcodeWorkspaces"
    var hasPending: Bool { !self.leases.isEmpty }

    init(defaults: UserDefaults = .standard, automation: XcodeBranchWorkspaceAutomation = .init(),
         applications: @escaping () -> [String] = {
             NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
                 .filter { !$0.isTerminated }.compactMap { $0.bundleURL?.path }
         }, open: @escaping (Workspace) async throws -> Void = { workspace in
             let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
             _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: workspace.path)],
                 withApplicationAt: URL(fileURLWithPath: workspace.application), configuration: configuration)
         }) {
        self.defaults = defaults; self.automation = automation; self.applications = applications; self.open = open
        self.leases = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: [Workspace]].self, from: $0) } ?? [:]
    }

    // MARK: - Checkout ownership

    func prepare(_ operation: BranchSwitchOperation) async throws {
        let key = operation.id.uuidString
        do {
            try Task.checkCancellation()
            if self.leases[key] == nil {
                let applications = self.applications()
                // Apple Events address an application bundle, not an individual duplicate instance.
                guard Set(applications).count == applications.count else { throw BranchSwitchError.xcodeClose }
                var targets: [Workspace] = []
                for application in applications {
                    let paths = try await self.automation.paths(application: application, checkout: operation.source.path)
                    targets += paths.map { Workspace(application: application, path: $0) }
                }
                self.leases[key] = targets
                try self.persist()
            }
            for workspace in self.leases[key] ?? [] {
                try Task.checkCancellation()
                try await self.automation.close(workspace)
            }
            // No Git write is allowed until every relevant workspace is confirmed closed.
            for application in Set((self.leases[key] ?? []).map(\.application)) {
                guard try await self.automation.paths(application: application, checkout: operation.source.path).isEmpty else {
                    throw BranchSwitchError.xcodeClose
                }
            }
            try Task.checkCancellation()
        } catch is CancellationError { throw CancellationError() }
        catch let error as XcodeRunAutomation.ScriptError where error.number == -1743 || error.number == -10004 { throw BranchSwitchError.xcodeAccess }
        catch { throw BranchSwitchError.xcodeClose }
    }

    func restore(_ operation: BranchSwitchOperation) async throws {
        guard !operation.phase.holdsCheckout else { return }
        let key = operation.id.uuidString
        guard let targets = self.leases[key] else { return }
        do {
            for workspace in targets {
                try await self.open(workspace)
                guard try await self.automation.paths(application: workspace.application, checkout: operation.source.path).contains(workspace.path) else {
                    throw BranchSwitchError.xcodeReopen
                }
            }
            self.leases[key] = nil
            try self.persist()
        } catch { throw BranchSwitchError.xcodeReopen }
    }

    /// Interrupted Git operations keep their workspaces closed until explicit review/cancellation.
    func restoreCompleted(_ operations: [BranchSwitchOperation]) async throws {
        for operation in operations where !operation.phase.holdsCheckout { try await self.restore(operation) }
    }

    private func persist() throws { self.defaults.set(try JSONEncoder().encode(self.leases), forKey: Self.key) }
}

/// Uses Xcode's scripting dictionary off the main actor. No file contents, forced quit or save-discard
/// commands are used; Xcode retains its normal Save/Cancel prompt for unsaved documents.
actor XcodeBranchWorkspaceAutomation {
    private let evaluate: @Sendable (String) throws -> XcodeRunAutomation.Response
    init(evaluate: @escaping @Sendable (String) throws -> XcodeRunAutomation.Response = XcodeRunAutomation.evaluateScript) {
        self.evaluate = evaluate
    }
    func paths(application: String, checkout: String) throws -> [String] {
        let root = URL(fileURLWithPath: checkout).resolvingSymlinksInPath().path + "/"
        let source = """
        with timeout of 10 seconds
            tell application \(try literal(application))
                set selectedPaths to {}
                repeat with candidate in workspace documents
                    set candidateFile to file of candidate
                    if candidateFile is not missing value then
                        set candidatePath to POSIX path of candidateFile
                        if candidatePath ends with "/" then set candidatePath to text 1 thru -2 of candidatePath
                        if candidatePath starts with \(try literal(root)) then set end of selectedPaths to candidatePath
                    end if
                end repeat
                set AppleScript's text item delimiters to linefeed
                return selectedPaths as text
            end tell
        end timeout
        """
        guard case let .text(value) = try evaluate(source) else { throw BranchSwitchError.xcodeClose }
        let paths = value.split(separator: "\n").map(String.init)
        guard paths.allSatisfy({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(root) }) else { throw BranchSwitchError.xcodeClose }
        return Array(Set(paths)).sorted()
    }
    func close(_ workspace: XcodeBranchWorkspaces.Workspace) throws {
        let source = """
        with timeout of 60 seconds
            tell application \(try literal(workspace.application))
                set selectedWorkspaces to {}
                repeat with candidate in workspace documents
                    set candidateFile to file of candidate
                    if candidateFile is not missing value then
                        set candidatePath to POSIX path of candidateFile
                        if candidatePath ends with "/" then set candidatePath to text 1 thru -2 of candidatePath
                        if candidatePath is \(try literal(workspace.path)) then set end of selectedWorkspaces to contents of candidate
                    end if
                end repeat
                repeat with selectedWorkspace in selectedWorkspaces
                    set previousAction to missing value
                    try
                        set previousAction to last scheme action result of selectedWorkspace
                    on error errorMessage number errorNumber
                        if errorNumber is not -1728 then error errorMessage number errorNumber
                    end try
                    if previousAction is not missing value then
                        if completed of previousAction is false then error "Xcode action is running" number -2700
                    end if
                    close selectedWorkspace saving ask
                end repeat
                return true
            end tell
        end timeout
        """
        guard case .flag(true) = try evaluate(source) else { throw BranchSwitchError.xcodeClose }
    }
    private func literal(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw BranchSwitchError.xcodeClose }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
