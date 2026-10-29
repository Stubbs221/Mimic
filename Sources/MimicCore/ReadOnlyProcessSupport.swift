//
//  ReadOnlyProcessSupport.swift
//  MimicCore
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import os

/// Capability discovery is a bounded read against the operation's pinned developer directory.
public enum ReadOnlyProcessSupport {
    private static let capabilities = OSAllocatedUnfairLock(initialState: [String: Bool]())
    public static func captureXcodeHelp(developer: String) -> (identity: String, supportsResponseFile: Bool) {
        let environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "DEVELOPER_DIR": developer]
        let version = ReadOnlyProcess.capture("/usr/bin/xcrun", ["xcodebuild", "-version"], environment: environment)
        let identity = developer + ":" + version.1
        if let cached = capabilities.withLock({ $0[identity] }) { return (identity, cached) }
        let help = ReadOnlyProcess.capture("/usr/bin/xcrun", ["xcodebuild", "-help"], environment: environment, maximumBytes: 512 * 1024, includeStandardError: true)
        let supported = version.0 == 0 && help.0 == 0 && help.1.contains("response file") && help.1.contains("-only-testing")
        if version.0 == 0 && help.0 == 0 { capabilities.withLock { $0[identity] = supported } }
        return (identity, supported)
    }
    /// Allowlisted installed-toolchain facts; available SDK is not asserted to be an effective view trait.
    public static func environmentSnapshot(developer: String, platform: BootstrapPlatform) -> BridgeValue {
        let environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "DEVELOPER_DIR": developer]
        func read(_ arguments: [String]) -> BridgeValue {
            let value = ReadOnlyProcess.capture("/usr/bin/xcrun", arguments, environment: environment, timeout: 8, maximumBytes: 4096)
            return value.0 == 0 ? .string(value.1.trimmingCharacters(in: .whitespacesAndNewlines)) : .null
        }
        return .object(["source": .string("pinnedXcodeReadOnlyQueries"), "developerDirectory": .string(developer), "xcode": read(["xcodebuild", "-version"]), "swift": read(["swiftc", "--version"]), "availableSDK": read(["--sdk", platform == .tvos ? "appletvsimulator" : "iphonesimulator", "--show-sdk-version"])])
    }

}
