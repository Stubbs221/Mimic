// Created by Василий Маслов on 22.10.2026.
import Foundation

/// Catalogue identity excludes source revisions and simulator boot state.
public struct BuildCatalogueSignature: Codable, Equatable, Sendable {
    public let configuration: String
    public let destinations: String
    public init(configuration: String, destinations: String) {
        self.configuration = configuration; self.destinations = destinations
    }

    /// Reads only build metadata and the installed simulator inventory; never resolves packages.
    static func capture(project: ProjectContext) throws -> Self {
        let configuration = try configurationDigest(project: project)
        let devices = ReadOnlyProcess.capture("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], environment: EnvironmentInspector.environment(project: project), timeout: 8)
        guard devices.0 == 0 else { throw BuildError.catalogueProcess }
        return Self(configuration: configuration, destinations: try destinationDigest(json: Data(devices.1.utf8)))
    }

    static func configurationDigest(project: ProjectContext) throws -> String {
        guard let target = project.appleTarget, let developer = project.developerDirectory else { throw BuildError.configuration }
        let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath()
        let patterns = ["project.pbxproj", "contents.xcworkspacedata", "*.xcscheme", "*.xctestplan", "*.xcconfig", "Package.swift", "Package@swift-*.swift", "Package.resolved", "Podfile.lock", "Cartfile.resolved"]
        let listed = ReadOnlyProcess.capture("/usr/bin/git", ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"] + patterns, timeout: 8, maximumBytes: 2 * 1024 * 1024)
        guard listed.0 == 0 else { throw BuildError.catalogueProcess }
        var paths = Set(listed.1.split(separator: "\0").map(String.init))
        // Generated projects and workspace-local resolved files may be ignored by Git.
        var bundles = try Set([target.path, target.configurationProject].compactMap { $0 }).map { URL(fileURLWithPath: try ProfileValidation.checkoutPath($0, root: root.path)) }
        var visited = Set<URL>()
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while let bundle = bundles.popLast() {
            guard visited.insert(bundle).inserted else { continue }
            guard visited.count <= 256, bundle.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw BuildError.configuration }
            if bundle.pathExtension == "xcworkspace" {
                let references = WorkspaceCatalogueReferences(container: bundle.deletingLastPathComponent())
                let parser = XMLParser(data: try Data(contentsOf: bundle.appendingPathComponent("contents.xcworkspacedata")))
                parser.delegate = references; parser.shouldResolveExternalEntities = false
                guard parser.parse() else { throw BuildError.catalogueResponse }
                bundles.append(contentsOf: references.bundles)
            }
            guard let files = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey]) else { throw BuildError.configuration }
            for case let file as URL in files {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw BuildError.catalogueTimeout }
                if file.hasDirectoryPath && !["xcworkspace", "xcodeproj"].contains(bundle.pathExtension) {
                    if file.lastPathComponent != ".swiftpm" && !file.path.contains("/.swiftpm/") { files.skipDescendants() }
                }
                if ["project.pbxproj", "contents.xcworkspacedata", "Package.resolved"].contains(file.lastPathComponent) || ["xcscheme", "xcconfig", "xctestplan"].contains(file.pathExtension) || file.lastPathComponent.hasPrefix("Package@swift-") && file.pathExtension == "swift" {
                    let resolved = file.resolvingSymlinksInPath().path
                    guard resolved.hasPrefix(root.path + "/") else { throw BuildError.configuration }
                    paths.insert(String(resolved.dropFirst(root.path.count + 1)))
                }
            }
            if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Package.swift").path) {
                paths.insert(String(bundle.appendingPathComponent("Package.swift").resolvingSymlinksInPath().path.dropFirst(root.path.count + 1)))
            }
        }
        guard paths.count <= 10_000 else { throw BuildError.capacity }
        var content = Data()
        for path in paths.sorted() {
            let file = try ProfileValidation.checkoutPath(path, root: root.path)
            content.append(Data(path.utf8)); content.append(0)
            if FileManager.default.fileExists(atPath: file) {
                guard let size = try URL(fileURLWithPath: file).resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else { throw BuildError.capacity }
                let data = try Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe)
                guard data.count <= 16 * 1024 * 1024 else { throw BuildError.capacity }
                content.append(Data(SourceRevisionReader.hash(data).utf8))
            } else { content.append(Data("deleted".utf8)) }
            content.append(0)
        }
        let info = URL(fileURLWithPath: developer).deletingLastPathComponent().appendingPathComponent("Info.plist")
        content.append(try Data(contentsOf: info))
        return SourceRevisionReader.hash(content)
    }

    static func destinationDigest(json: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any], let runtimes = object["devices"] as? [String: [[String: Any]]] else { throw BuildError.catalogueResponse }
        var inventory: [String] = []
        for (runtime, devices) in runtimes {
            for device in devices {
                guard let id = device["udid"] as? String, let name = device["name"] as? String else { throw BuildError.catalogueResponse }
                inventory.append(runtime + "|" + id + "|" + name + "|" + String(describing: device["isAvailable"] ?? false))
            }
        }
        return SourceRevisionReader.hash(Data(inventory.sorted().joined(separator: "\n").utf8))
    }
}

/// Workspace references include ignored generated projects and local package metadata.
private final class WorkspaceCatalogueReferences: NSObject, XMLParserDelegate {
    let container: URL
    var groups: [URL]
    var bundles: [URL] = []
    init(container: URL) { self.container = container; self.groups = [container] }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let location = attributeDict["location"] ?? "group:"
        let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let base = parts.first == "container" ? container : groups.last!
        let path = parts.count == 2 ? String(parts[1]) : location
        let resolved = (parts.first == "absolute" ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL
        if elementName == "Group" { groups.append(resolved) }
        if elementName == "FileRef", ["xcodeproj", "xcworkspace"].contains(resolved.pathExtension) || FileManager.default.fileExists(atPath: resolved.appendingPathComponent("Package.swift").path) { bundles.append(resolved) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Group", groups.count > 1 { groups.removeLast() }
    }
}
