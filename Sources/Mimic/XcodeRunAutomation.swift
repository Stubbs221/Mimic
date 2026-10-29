//
//  XcodeRunAutomation.swift
//  Mimic
//
//  Created by Василий Маслов on 22.10.2026.
import Foundation
import MimicCore

/// Bounded evidence of the native Run step that failed. The activity keeps `code`; `summary` goes to its diagnostic log.
struct XcodeRunFailure: Error, Sendable, Equatable {
    let step: String
    let code: BuildError
    let detail: String
    /// Xcode returned a definitive build failure: the outcome is known, and `issues` holds its compiler messages.
    let buildFailed: Bool
    let issues: String
    init(step: String, code: BuildError, detail: String, buildFailed: Bool = false, issues: String = "") {
        self.step = step; self.code = code; self.buildFailed = buildFailed
        self.detail = String(DiagnosticText.clean(detail).replacingOccurrences(of: "\n", with: " ").prefix(480))
        self.issues = DiagnosticText.bounded(issues, limit: 256 * 1024).text
    }
    var summary: String { "Xcode Run failed at \(step) [\(code.rawValue)]: \(detail)" }
}

/// Xcode's documented scripting dictionary supplies the 26.5 debug action and exact device selection.
/// Scripts run serially off the main actor; no shell, source edits or debugger expressions are accepted.
actor XcodeRunAutomation {
    enum Response: Sendable, Equatable { case text(String), flag(Bool), empty }
    /// The original Apple Event failure; `execute` attaches the step before it leaves this type.
    struct ScriptError: Error, Sendable { let number: Int?; let message: String }
    private let evaluate: @Sendable (String) throws -> Response
    init(evaluate: @escaping @Sendable (String) throws -> Response = XcodeRunAutomation.evaluateScript) { self.evaluate = evaluate }
    struct Target: Sendable {
        let application: String
        let workspace: String
        let scheme: String
        let destinationID: String
    }
    private func literal(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw BuildError.arguments }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    /// `file` must be resolved before `POSIX path` (Xcode 27 rejects the nested reference with -1700),
    /// and Xcode reports the workspace package with a trailing slash.
    private func workspace(_ target: Target) throws -> String {
        let original = try literal(target.workspace)
        let canonical = try literal(URL(fileURLWithPath: target.workspace).resolvingSymlinksInPath().path)
        return """
        set matchingWorkspaces to {}
        repeat with candidate in workspace documents
            set candidateFile to file of candidate
            if candidateFile is not missing value then
                set candidatePath to POSIX path of candidateFile
                if candidatePath ends with "/" then set candidatePath to text 1 thru -2 of candidatePath
                if candidatePath is \(original) or candidatePath is \(canonical) then set end of matchingWorkspaces to contents of candidate
            end if
        end repeat
        if (count matchingWorkspaces) is not 1 then error "Workspace identity changed" number -2700
        set selectedWorkspace to item 1 of matchingWorkspaces
        if loaded of selectedWorkspace is false then error "Workspace is loading" number -2700
        """
    }
    private func execute(_ target: Target, step: String, body: String) throws -> Response {
        let app = try literal(target.application)
        let source = """
        with timeout of 15 seconds
            tell application \(app)
                \(try workspace(target))
                \(body)
            end tell
        end timeout
        """
        do { return try evaluate(source) } catch let error as ScriptError {
            let access = error.number == -1743 || error.number == -10004
            throw XcodeRunFailure(step: "automation." + step, code: access ? .xcodeAutomationAccess : .configuration,
                                  detail: "AppleScript " + (error.number.map(String.init) ?? "unknown") + ": " + error.message)
        }
    }
    static func evaluateScript(_ source: String) throws -> Response {
        guard let script = NSAppleScript(source: source) else { throw ScriptError(number: nil, message: "Script source was rejected") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error[NSAppleScript.errorBriefMessage] as? String ?? ""
            throw ScriptError(number: error[NSAppleScript.errorNumber] as? Int, message: message)
        }
        return response(result)
    }
    /// AppleScript returns literal booleans as 'true'/'fals' descriptors, not typeBoolean.
    static func response(_ result: NSAppleEventDescriptor) -> Response {
        if [typeBoolean, typeTrue, typeFalse].contains(result.descriptorType) { return .flag(result.booleanValue) }
        if let value = result.stringValue { return .text(value) }
        return .empty
    }
    /// Never substitute a destination with the same display name: UUID and simulator platform must match.
    /// Destinations are read as two parallel lists in one round trip each; per-item Apple Events exceed the timeout
    /// in large workspaces. Returns the scripting name of the selected destination for picker verification.
    func select(_ target: Target) throws -> String {
        let scheme = try literal(target.scheme), destination = try literal(target.destinationID)
        let result = try execute(target, step: "select", body: """
        tell selectedWorkspace
            set matchingSchemes to schemes whose name is \(scheme)
            if (count matchingSchemes) is not 1 then error "Ambiguous scheme" number -2700
            set active scheme to item 1 of matchingSchemes
            set destinationPlatforms to platform of every run destination
            set destinationDevices to device identifier of device of every run destination
            set destinationNames to name of every run destination
            if (count destinationPlatforms) is not (count destinationDevices) or (count destinationPlatforms) is not (count destinationNames) then error "Run destinations changed" number -2700
            set matchingIndexes to {}
            repeat with candidateIndex from 1 to count destinationPlatforms
                if item candidateIndex of destinationPlatforms is "iphonesimulator" and item candidateIndex of destinationDevices is \(destination) then set end of matchingIndexes to candidateIndex
            end repeat
            if (count matchingIndexes) is not 1 then error "Simulator identity changed" number -2700
            set selectedIndex to item 1 of matchingIndexes
            set selectedName to item selectedIndex of destinationNames
            set sameNames to 0
            repeat with candidateName in destinationNames
                if contents of candidateName is selectedName then set sameNames to sameNames + 1
            end repeat
            if sameNames is not 1 then error "Simulator name is ambiguous" number -2700
            -- Scripting never reports the active destination, so the indexed element is re-checked around the change.
            if platform of run destination selectedIndex is not "iphonesimulator" or device identifier of device of run destination selectedIndex is not \(destination) then error "Run destinations changed" number -2700
            set active run destination to run destination selectedIndex
            if platform of run destination selectedIndex is not "iphonesimulator" or device identifier of device of run destination selectedIndex is not \(destination) then error "Run destinations changed" number -2700
            return selectedName
        end tell
        """)
        guard case let .text(name) = result, !name.isEmpty else { throw XcodeRunFailure(step: "automation.select", code: .configuration, detail: "No destination name returned") }
        return name
    }
    /// Xcode's MCP server rejects clients until a workspace window exists, so the scripting view must see it loaded.
    /// - Returns: `nil` when ready, otherwise Xcode's reason for the scripting identity check failing.
    func workspaceNotReady(_ target: Target) throws -> String? {
        do { _ = try execute(target, step: "workspace", body: "return true"); return nil }
        catch let failure as XcodeRunFailure where failure.code == .configuration && failure.detail.hasPrefix("AppleScript -2700:") { return failure.detail }
    }
    func requireIdle(_ target: Target) throws {
        let result = try execute(target, step: "requireIdle", body: """
        try
            set previousAction to last scheme action result of selectedWorkspace
            if previousAction is missing value then return true
            return completed of previousAction
        on error errorMessage number errorNumber
            if errorNumber is -1728 then return true
            error errorMessage number errorNumber
        end try
        """)
        guard case .flag(true) = result else {
            throw XcodeRunFailure(step: "automation.requireIdle", code: .xcodeBusy, detail: { if case .flag(false) = result { return "Xcode reports an unfinished scheme action" }; return "Unexpected reply \(result)" }())
        }
    }
    func stopOwnedDebug(_ target: Target, actionID: String) throws {
        _ = try execute(target, step: "stopOwnedDebug", body: """
        if id of last scheme action result of selectedWorkspace is not \(try literal(actionID)) then error "Action replaced" number -2700
        stop selectedWorkspace
        """)
    }
    /// A changed scheme invalidates launch; the owner must explicitly request another run.
    /// Xcode 26.5 and 27 never report the active run destination to scripting, so this confirms the exact simulator
    /// is still offered once; the 26.5 `debug` command names it by UUID and Xcode 27 verifies the picker through MCP.
    func verify(_ target: Target) throws {
        _ = try execute(target, step: "verify", body: """
        tell selectedWorkspace
            if name of active scheme is not \(try literal(target.scheme)) then error "Scheme changed" number -2700
            set destinationPlatforms to platform of every run destination
            set destinationDevices to device identifier of device of every run destination
            if (count destinationPlatforms) is not (count destinationDevices) then error "Run destinations changed" number -2700
            set matchingCount to 0
            repeat with candidateIndex from 1 to count destinationPlatforms
                if item candidateIndex of destinationPlatforms is "iphonesimulator" and item candidateIndex of destinationDevices is \(try literal(target.destinationID)) then set matchingCount to matchingCount + 1
            end repeat
            if matchingCount is not 1 then error "Simulator identity changed" number -2700
        end tell
        """)
    }
    /// BuildProject already succeeded in this workspace; `debug` preserves Xcode's Run configuration and LLDB.
    func debugWithoutBuilding(_ target: Target) throws -> String {
        try verify(target)
        let result = try execute(target, step: "debug", body: """
        set actionResult to debug selectedWorkspace scheme \(try literal(target.scheme)) run destination specifier \(try literal("platform=iOS Simulator,id=" + target.destinationID)) skip building true
        return id of actionResult
        """)
        guard case let .text(id) = result, !id.isEmpty else { throw BuildError.debuggerUnavailable }
        return id
    }
    /// The action reference is pinned: replacement by an unrelated action is a context failure.
    func debugStatus(_ target: Target, actionID: String) throws -> String {
        let result = try execute(target, step: "debugStatus", body: """
        set actionResult to last scheme action result of selectedWorkspace
        if id of actionResult is not \(try literal(actionID)) then error "Action replaced" number -2700
        return status of actionResult as text
        """)
        if case let .text(value) = result { return value }
        return ""
    }
}
