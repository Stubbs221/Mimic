//
//  MimicCoreResources.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation

/// Packaged binaries resolve resources from their own app, without a developer checkout fallback.
public enum MimicCoreResources {
    public static let bundle: Bundle = {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Mimic_MimicCore.bundle"), app.appendingPathComponent("Contents/Resources/Mimic_MimicCore.bundle")]
        for candidate in candidates { if let bundle = Bundle(url: candidate) { return bundle } }
        #if DEBUG
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()
}
