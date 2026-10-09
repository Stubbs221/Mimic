// Created by Василий Маслов on 09.10.2026.
import Foundation

public enum BuildIntent: String, Codable, Sendable { case run, catalogue, cleanup }
public enum BuildStage: String, Codable, Sendable { case compilation, products, installation, launch, catalogue, cleanup }

/// Product identity comes from the pinned invocation's build settings, never a global latest .app.
public struct BuildProduct: Codable, Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let bundleIdentifier: String
    public init(name: String, path: String, bundleIdentifier: String) { self.name = name; self.path = path; self.bundleIdentifier = bundleIdentifier }

    public static func parse(settings: Data, derivedData: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> [Self] {
        guard let targets = try JSONSerialization.jsonObject(with: settings) as? [[String: Any]] else { throw BuildError.catalogueResponse }
        var products: [Self] = []
        let root = derivedData.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for target in targets {
            guard let values = target["buildSettings"] as? [String: Any],
                  values["WRAPPER_EXTENSION"] as? String == "app",
                  let directory = values["TARGET_BUILD_DIR"] as? String,
                  let filename = values["FULL_PRODUCT_NAME"] as? String, filename.hasSuffix(".app"), !filename.contains("/"),
                  let bundle = values["PRODUCT_BUNDLE_IDENTIFIER"] as? String, !bundle.isEmpty,
                  values["PLATFORM_NAME"] as? String == "iphonesimulator" || values["PLATFORM_NAME"] as? String == "appletvsimulator" else { continue }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(filename).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root), exists(url.path), !products.contains(where: { $0.path == url.path }) else { continue }
            products.append(.init(name: target["target"] as? String ?? filename, path: url.path, bundleIdentifier: bundle))
        }
        guard !products.isEmpty else { throw BuildError.configuration }
        return products
    }
}

public struct BuildTest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let target: String
    public let className: String
    public let name: String
    public var caseIdentifiersTruncated: Bool?
    public let caseIdentifiers: [String]?
    public init(id: String, target: String, className: String, name: String, caseIdentifiers: [String]? = nil) { self.id = id; self.target = target; self.className = className; self.name = name; self.caseIdentifiers = caseIdentifiers }
}

/// Full identity also governs saved selection: changing revision, toolchain or destination invalidates it.
public struct BuildTestCatalogue: Codable, Equatable, Sendable {
    public let project: ProjectContext
    public let developerDirectory: String
    public let scheme: String
    public let configuration: String
    public let destinationID: String
    public let testPlan: String
    public let tests: [BuildTest]
    public func matches(project: ProjectContext, parameters: BuildParameters, developer: String) -> Bool {
        self.project == project && developerDirectory == developer && scheme == parameters.scheme && configuration == parameters.configuration && destinationID == parameters.destinationID && testPlan == parameters.testPlan
    }
    public init(project: ProjectContext, developerDirectory: String, parameters: BuildParameters, tests: [BuildTest]) {
        self.project = project; self.developerDirectory = developerDirectory; scheme = parameters.scheme; configuration = parameters.configuration; destinationID = parameters.destinationID; testPlan = parameters.testPlan; self.tests = tests
    }

    /// Xcode hierarchical enumeration nests target/class/case nodes. Only leaf case identifiers are selectable.
    public static func parse(_ data: Data) throws -> [BuildTest] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any], root["values"] is [Any] || root["testNodes"] is [Any] || root["tests"] is [Any] else { throw BuildError.catalogueResponse }
        if let errors = root["errors"] as? [Any], !errors.isEmpty { throw BuildError.catalogueResponse }
        var tests: [BuildTest] = [], seen = Set<String>(), incomplete = false
        func append(_ id: String, cases: [String] = []) {
            let components = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if id.utf8.count <= 1024, cases.allSatisfy({ $0.utf8.count <= 1024 }), components.count == 3, components.allSatisfy({ !$0.isEmpty && !$0.contains("*") && !$0.hasPrefix("-") }), seen.insert(id).inserted {
                tests.append(.init(id: id, target: components[0], className: components[1], name: components[2], caseIdentifiers: cases.isEmpty ? nil : cases))
            } else if !seen.contains(id) { incomplete = true }
        }
        func walk(_ value: Any, target: String = "", className: String = "", trail: [String] = []) {
            guard trail.count < 24 else { incomplete = true; return }
            if let identifier = value as? String { append(identifier); return }
            if let list = value as? [Any] { for item in list { walk(item, target: target, className: className, trail: trail) }; return }
            guard let node = value as? [String: Any] else { return }
            let type = (node["nodeType"] as? String ?? node["type"] as? String ?? "").lowercased()
            let name = node["name"] as? String ?? ""
            let identifier = node["nodeIdentifier"] as? String ?? node["testIdentifier"] as? String ?? node["identifier"] as? String ?? ""
            let nextTarget = type.contains("target") || type.contains("bundle") ? name : target
            let nextClass = type.contains("class") || type.contains("suite") ? name : className
            let children = node["children"] as? [Any] ?? []
            if type.contains("case") || type == "test" || children.isEmpty && !name.isEmpty && trail.count >= 2 {
                let normalized = identifier.hasPrefix("test://") ? String(identifier.dropFirst(7)) : identifier
                let parts = normalized.split(separator: "/").map(String.init)
                let id = parts.count == 3 ? parts.joined(separator: "/") : [nextTarget.isEmpty ? trail.dropLast().last ?? "" : nextTarget, nextClass.isEmpty ? trail.last ?? "" : nextClass, name].joined(separator: "/")
                if parts.count == 3, type.contains("case"), !children.isEmpty {
                    func caseIDs(_ nodes: [Any]) -> [String] {
                        nodes.flatMap { value -> [String] in
                            guard let node = value as? [String: Any] else { return [] }
                            if let nested = node["children"] as? [Any], !nested.isEmpty { return caseIDs(nested) }
                            return [node["nodeIdentifier"] as? String ?? node["testIdentifier"] as? String ?? node["name"] as? String ?? ""].filter { !$0.isEmpty }
                        }
                    }
                    append(id, cases: caseIDs(children)); return
                }
                append(id)
            }
            for key in ["values", "children", "testNodes", "tests"] { if let child = node[key] { walk(child, target: nextTarget, className: nextClass, trail: name.isEmpty ? trail : trail + [name]) } }
        }
        walk(json)
        guard !incomplete else { throw BuildError.catalogueResponse }
        return tests.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

public extension BuildActivity {
    var actionKey: String { parameters.intent == .cleanup ? "build.action.cleanup" : parameters.intent == .run ? "build.action.run" : parameters.intent == .catalogue ? "build.action.catalogue" : parameters.operation == .test ? "build.action.testsSelected" : "build.action.build" }
    var progressTotal: Int { parameters.intent == .run ? 3 : 1 }
    /// Counts completed stages; an unknown compiler total remains indeterminate.
    var selectedTestCount: Int? { parameters.operation == .test && parameters.testIdentifiers.allSatisfy { $0.split(separator: "/").count == 3 } ? Set(parameters.testIdentifiers).count : nil }
    var progressFraction: Double? {
        if status == .succeeded { return 1 }
        if let count = completedTestCount, let total = selectedTestCount, total > 0 { return Double(count) / Double(total) }
        return completedStages.flatMap { $0 > 0 ? Double($0) / Double(progressTotal) : nil }
    }
}

/// Count only observed completions that unambiguously match a selected leaf. Retries never double-count.
public struct BuildTestProgress: Sendable {
    private var buffer = ""
    private var completed = Set<String>()
    public init() { }
    public mutating func append(_ text: String, selected: [String]) -> Int {
        buffer += text
        let lines = buffer.components(separatedBy: .newlines)
        buffer = String((lines.last ?? "").suffix(4096))
        for line in lines.dropLast() {
            guard line.contains("Test Case '") || line.contains("Test case '"), line.contains(" passed") || line.contains(" failed") || line.contains(" skipped"), let quoted = line.split(separator: "'", omittingEmptySubsequences: false).dropFirst().first else { continue }
            let name = String(quoted)
            let matches = selected.filter { identifier in
                let parts = identifier.split(separator: "/").map(String.init)
                guard parts.count == 3 else { return false }
                let method = parts[2].replacingOccurrences(of: "()", with: "")
                return name == parts[1] + "." + parts[2] || name == "-[" + parts[1] + " " + method + "]" || name == "-[" + parts[0] + "." + parts[1] + " " + method + "]"
            }
            if matches.count == 1 { completed.insert(matches[0]) }
        }
        return completed.count
    }
}
