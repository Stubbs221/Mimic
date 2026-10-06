//
//  MimicVersion.swift
//  MimicCore
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation

/// App packaging, helpers and exported plugins share the checked-in version resource.
public enum MimicVersion {
    private static let values: [String: String] = {
        guard let url = MimicCoreResources.bundle.url(forResource: "Version", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListDecoder().decode([String: String].self, from: data),
              values["version"] != nil, values["build"] != nil else {
            preconditionFailure("Missing Mimic version resource")
        }
        return values
    }()
    public static var version: String { self.values["version"]! }
    public static var build: String { self.values["build"]! }
}
