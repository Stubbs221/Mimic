//
//  XcodeRunVerification.swift
//  MimicCore
//
//  Created by Василий Маслов on 22.10.2026.
import Foundation

/// Launch and debugger replies must identify the same process; console text is never evidence.
public enum XcodeRunVerification {
    public static func launchedProcess(_ result: BridgeValue, isError: Bool) throws -> Int {
        guard !isError, result["runResult"].string?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == "the app was launched successfully.",
              let errors = result["buildErrors"].array, errors.isEmpty,
              let process = result["processIdentifier"].integer, process > 0 else { throw BuildError.debuggerUnavailable }
        return process
    }
    public static func debuggerMatches(_ result: BridgeValue, process: Int, isError: Bool) -> Bool {
        !isError && process > 0 && result["debugSessionActive"] == .bool(true) && result["processIdentifier"].integer == process
    }
    /// Xcode 27 scripting reports no active run destination, so the picker state must name the entry chosen by UUID.
    /// - Parameter title: the scripting `name` of the single destination whose device identifier matched.
    public static func destinationMatches(_ result: BridgeValue, scheme: String, title: String, isError: Bool) -> Bool {
        guard !isError, !title.isEmpty, result["activeSchemeName"].string == scheme, result["activeDestinationDisplayTitle"].string == title,
              let entries = result["destinations"].array else { return false }
        let active = entries.filter { $0["isActive"] == .bool(true) }
        guard active.count == 1, let entry = active.first else { return false }
        return entry["displayTitle"].string == title && entry["isSimulator"] == .bool(true) && entry["isGenericDevice"] != .bool(true)
            && entry["platformIdentifier"].string == "com.apple.platform.iphonesimulator"
            && entries.filter({ $0["displayTitle"].string == title }).count == 1
    }
    /// Xcode's own compiler issues from a BuildProject/RunProject reply, one per line, for the activity output.
    public static func issues(_ entries: [BridgeValue]?) -> String {
        (entries ?? []).prefix(500).map { entry in
            let location = entry["filePath"].string.map { $0 + (entry["lineNumber"].integer.map { ":\($0)" } ?? "") + ": " } ?? ""
            return location + (entry["classification"].string ?? "issue") + ": " + (entry["message"].string ?? "")
        }.joined(separator: "\n")
    }
    /// A simulator app is a host process whose executable lives in its device's data container.
    public static func processBelongsToSimulator(executablePath: String, deviceID: String) -> Bool {
        guard UUID(uuidString: deviceID) != nil else { return false }
        return executablePath.uppercased().contains("/LIBRARY/DEVELOPER/CORESIMULATOR/DEVICES/" + deviceID.uppercased() + "/DATA/")
    }
}
