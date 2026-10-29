//
//  XcodeProjectConfigurations.swift
//  MimicCore
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation

/// Reads project-level configuration names without loading its Swift package graph in Xcode.
enum XcodeProjectConfigurations {
    static func load(_ path: String) throws -> [String] {
        let url = URL(fileURLWithPath: path)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else { throw BuildError.capacity }
        return try names(in: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Target-specific lists may differ; only the PBXProject's own configuration list is authoritative.
    static func names(in data: Data) throws -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]], let root = plist["rootObject"] as? String,
              let project = objects[root], project["isa"] as? String == "PBXProject",
              let listID = project["buildConfigurationList"] as? String,
              let list = objects[listID], list["isa"] as? String == "XCConfigurationList",
              let identifiers = list["buildConfigurations"] as? [String], !identifiers.isEmpty else { throw BuildError.catalogueResponse }
        let names = try identifiers.map { identifier -> String in
            guard let configuration = objects[identifier], configuration["isa"] as? String == "XCBuildConfiguration",
                  let name = configuration["name"] as? String, !name.isEmpty else { throw BuildError.catalogueResponse }
            return name
        }
        guard Set(names).count == names.count else { throw BuildError.catalogueResponse }
        return names.sorted()
    }
}
