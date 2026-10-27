//
//  BuildTestTarget.swift
//  MimicCore
//
//  Created by Василий Маслов on 23.10.2026.
import Foundation

/// An enabled test bundle and the scheme plan that makes it runnable, without enumerating methods.
public struct BuildTestTarget: Codable, Equatable, Sendable {
    public let name: String
    public let testPlan: String
    public init(name: String, testPlan: String = "") { self.name = name; self.testPlan = testPlan }
}

/// Reads only scheme/plan metadata inside the checkout. No compiler, simulator or external XML entities.
public enum BuildTestTargetReader {
    public static func read(project: ProjectContext, scheme: String) throws -> [BuildTestTarget] {
        guard !scheme.isEmpty, !scheme.contains("/"), let target = project.appleTarget else { return [] }
        let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath()
        func data(_ url: URL) throws -> Data {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/"), let size = try resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { throw BuildError.configuration }
            return try Data(contentsOf: resolved)
        }
        var containers = [target.path]
        if let configuration = target.configurationProject, !containers.contains(configuration) { containers.append(configuration) }
        for container in containers {
            let bundle = root.appendingPathComponent(container)
            var directories = [bundle.appendingPathComponent("xcshareddata/xcschemes")]
            let users = bundle.appendingPathComponent("xcuserdata")
            directories += ((try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }.map { $0.appendingPathComponent("xcschemes") }
            for directory in directories {
                let url = directory.appendingPathComponent(scheme + ".xcscheme")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let xml = try XMLDocument(data: data(url), options: .nodeLoadExternalEntitiesNever)
                let plans = try xml.nodes(forXPath: "//TestAction/TestPlans/TestPlanReference").compactMap { $0 as? XMLElement }
                let ordered = plans.filter { $0.attribute(forName: "default")?.stringValue == "YES" } + plans.filter { $0.attribute(forName: "default")?.stringValue != "YES" }
                var result: [BuildTestTarget] = []
                for plan in ordered {
                    guard let reference = plan.attribute(forName: "reference")?.stringValue, reference.hasPrefix("container:") else { throw BuildError.configuration }
                    let file = bundle.deletingLastPathComponent().appendingPathComponent(String(reference.dropFirst("container:".count)))
                    guard let json = try JSONSerialization.jsonObject(with: data(file)) as? [String: Any], let targets = json["testTargets"] as? [[String: Any]] else { throw BuildError.catalogueResponse }
                    for target in targets where target["enabled"] as? Bool != false && target["skipped"] as? Bool != true {
                        if let name = (target["target"] as? [String: Any])?["name"] as? String, !result.contains(where: { $0.name == name }) {
                            result.append(.init(name: name, testPlan: file.deletingPathExtension().lastPathComponent))
                        }
                    }
                }
                if plans.isEmpty {
                    for node in try xml.nodes(forXPath: "//TestAction/Testables/TestableReference") {
                        guard let testable = node as? XMLElement, testable.attribute(forName: "skipped")?.stringValue != "YES",
                              let buildable = testable.elements(forName: "BuildableReference").first, let name = buildable.attribute(forName: "BlueprintName")?.stringValue else { continue }
                        if !result.contains(where: { $0.name == name }) { result.append(.init(name: name)) }
                    }
                }
                return result
            }
        }
        return []
    }
}
