//
//  TestIdentity.swift
//  MimicCore
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation

/// A leaf execution, distinct from its method and logical argument case.
public struct TestExecutionFact: Codable, Sendable {
    public let method: String
    public let caseID: String
    public let status: String
    public let duration: Double?
    public let identifierURL: String?
    public let configurationID: String?
    public let deviceID: String?
    public let attempt: Int
}

/// Complete internal facts are retained before the transport applies pagination.
public struct ParsedTestIdentities: Sendable {
    public var facts: [TestExecutionFact] = []
    public var methods: [BuildTest] = []
    public var errors: [String] = []
    public var observedFailure = false
    public var complete: Bool { errors.isEmpty }
}

/// Structural XCTest/Swift Testing identity. Display names never fuzzy-match a signature.
public enum TestIdentityParser {
    private struct Context {
        var target: String?
        var suite: String?
        var method: String?
        var caseID: String?
        var configuration: String?
        var device: String?
    }

    public static func parse(_ nodes: [[String: Any]], requireResults: Bool = true, configurationID: String? = nil, deviceID: String? = nil) -> ParsedTestIdentities {
        var result = ParsedTestIdentities(), methods: [String: BuildTest] = [:]
        var cases: [String: Set<String>] = [:], attempts: [String: Int] = [:], count = 0
        func error(_ code: String) { if !result.errors.contains(code) { result.errors.append(code) } }
        func walk(_ nodes: [[String: Any]], context: Context, depth: Int) {
            guard depth < 24 else { error("testIdentityDepth"); return }
            for node in nodes {
                count += 1
                guard count <= 200_000 else { error("testIdentityCapacity"); return }
                var next = context
                let type = (node["nodeType"] as? String ?? node["type"] as? String ?? "").lowercased()
                let name = node["name"] as? String ?? ""
                let rawValue = node["nodeIdentifier"] as? String ?? node["testIdentifier"] as? String ?? node["identifier"] as? String ?? ""
                let raw = rawValue.hasPrefix("test://") ? String(rawValue.dropFirst(7)) : rawValue
                let urlString = node["nodeIdentifierURL"] as? String
                guard raw.utf8.count <= 4096, (urlString?.utf8.count ?? 0) <= 4096, (node["result"] as? String)?.utf8.count ?? 0 <= 64 else { error("testIdentityCapacity"); continue }
                let url = urlString.flatMap(URLComponents.init(string:))
                let urlParts = url?.path.split(separator: "/").map(String.init) ?? []
                let structuredURL = url?.scheme == "test" && url?.host == "com.apple.xcode"
                let isBundle = type.contains("bundle") || type == "test target" || type == "target"
                let isMethod = type == "test case" || type == "test"
                let children: [[String: Any]]
                if let value = node["children"] {
                    guard let list = value as? [[String: Any]] else { error("testChildrenMalformed"); continue }
                    children = list
                } else { children = [] }
                if node["result"] as? String == "Failed" { result.observedFailure = true }
                if isBundle {
                    let candidates = [name.isEmpty ? nil : name, structuredURL && urlParts.count >= 2 ? urlParts[1] : nil].compactMap { $0 }
                    guard Set(candidates).count == 1 else { error("testTargetConflict"); continue }
                    next.target = candidates.first
                } else if structuredURL, urlParts.count >= 2, let target = next.target, target != urlParts[1] {
                    error("testTargetConflict"); continue
                }
                if type.contains("suite") || type == "class" { next.suite = name.isEmpty ? context.suite : name }
                next.configuration = node["configurationId"] as? String ?? context.configuration
                next.device = node["deviceId"] as? String ?? context.device
                // Schema versions represent context either as a typed wrapper or explicit metadata.
                if type == "test plan configuration" || type == "configuration" { next.configuration = raw.isEmpty ? name : raw }
                if type == "device" { next.device = raw.isEmpty ? name : raw }
                if isMethod {
                    let rawParts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                    let parts: [String]
                    if rawParts.count == 3 { parts = rawParts }
                    else if rawParts.count == 2, let target = next.target ?? (structuredURL && urlParts.count >= 2 ? urlParts[1] : nil) { parts = [target] + rawParts }
                    else if !requireResults, raw.isEmpty, let target = next.target, let suite = next.suite, !name.isEmpty { parts = [target, suite, name] }
                    else { error("testMethodIdentityUnavailable"); continue }
                    guard parts.allSatisfy({ !$0.isEmpty && !$0.contains("\n") }), parts.joined(separator: "/").utf8.count <= 1024,
                          next.target == nil || next.target == parts[0],
                          !structuredURL || urlParts.count >= 4 && urlParts[1] == parts[0] && urlParts[2] == parts[1] else { error("testMethodIdentityConflict"); continue }
                    // XCTest URL omits () for a no-argument ObjC selector. This is an exact,
                    // format-specific alias, never a normalization of Swift signatures.
                    if structuredURL, urlParts[3] != parts[2], !(parts[2] == urlParts[3] + "()" && !urlParts[3].contains(":")) { error("testMethodURLConflict"); continue }
                    let method = parts.joined(separator: "/")
                    next.method = method; next.caseID = nil
                    methods[method] = BuildTest(id: method, target: parts[0], className: parts[1], name: parts[2], identifierURL: urlString)
                }
                if type == "arguments" {
                    guard let method = next.method, let urlString, structuredURL,
                          url?.queryItems?.contains(where: { $0.name == "args" && !($0.value ?? "").isEmpty }) == true else { error("testCaseIdentityUnavailable"); continue }
                    let parts = method.split(separator: "/").map(String.init)
                    guard urlParts.count == 4, urlParts[1] == parts[0], urlParts[2] == parts[1], urlParts[3] == parts[2] else { error("testCaseMethodConflict"); continue }
                    next.caseID = urlString
                    cases[method, default: []].insert(urlString)
                } else if !isMethod, next.method != nil, next.caseID == nil, !raw.isEmpty, children.isEmpty {
                    next.caseID = raw
                    cases[next.method!, default: []].insert(raw)
                }
                guard (next.configuration?.utf8.count ?? 0) <= 1024, (next.device?.utf8.count ?? 0) <= 1024 else { error("executionContextCapacity"); continue }
                if children.isEmpty, let method = next.method {
                    guard ["test case", "test", "arguments", "test case run", "test iteration", "test repetition"].contains(type) else { error("unsupportedTestLeaf"); continue }
                    let caseID = next.caseID ?? method
                    if let status = node["result"] as? String {
                        let key = [method, caseID, next.configuration ?? "", next.device ?? ""].joined(separator: "\0")
                        attempts[key, default: 0] += 1
                        let duration = (node["durationInSeconds"] as? NSNumber)?.doubleValue
                        result.facts.append(.init(method: method, caseID: caseID, status: status, duration: duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, identifierURL: urlString, configurationID: next.configuration, deviceID: next.device, attempt: attempts[key]!))
                    } else if requireResults { error("testStatusUnavailable") }
                }
                walk(children, context: next, depth: depth + 1)
            }
        }
        walk(nodes, context: Context(configuration: configurationID, device: deviceID), depth: 0)
        result.methods = methods.keys.sorted().compactMap { id in
            guard let method = methods[id] else { return nil }
            return BuildTest(id: id, target: method.target, className: method.className, name: method.name, caseIdentifiers: cases[id].map { $0.sorted() }, identifierURL: method.identifierURL)
        }
        return result
    }
}
