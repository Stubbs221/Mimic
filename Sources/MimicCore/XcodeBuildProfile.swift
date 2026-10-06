// Created by Василий Маслов on 04.10.2026.
import Foundation

/// Conservative adapter for Xcode's tab-scoped MCP tools. A latest-build log has no operation identity.
public enum XcodeBuildProfile {
    public static func accepts(name: String, input: BridgeValue, output: BridgeValue) -> Bool {
        guard input["type"].string == "object", output["type"].string == "object" else { return false }
        let required = Set(input["required"].array?.compactMap(\.string) ?? [])
        let properties = input["properties"]
        switch name {
        case "XcodeListWindows": return required.isEmpty && output["properties"]["message"]["type"].string == "string"
        case "BuildProject":
            return required == ["tabIdentifier"] && properties["tabIdentifier"]["type"].string == "string" && output["properties"]["buildResult"]["type"].string == "string" && output["properties"]["errors"]["type"].string == "array"
        case "RunSomeTests":
            let item = properties["tests"]["items"]
            return required == ["tabIdentifier", "tests"] && properties["tabIdentifier"]["type"].string == "string" && properties["tests"]["type"].string == "array" && Set(item["required"].array?.compactMap(\.string) ?? []) == ["targetName", "testIdentifier"] && item["properties"]["targetName"]["type"].string == "string" && item["properties"]["testIdentifier"]["type"].string == "string" && output["properties"]["counts"]["type"].string == "object"
        default: return false
        }
    }
    /// Extract pairs only when the server explicitly supplies both identities in the same entry.
    public static func windows(_ message: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"tabIdentifier:\s*([^,\s]+),\s*workspacePath:\s*([^\n\r]+)"#)
        var result: [String: String] = [:]
        for match in regex.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
            guard let tab = Range(match.range(at: 1), in: message), let path = Range(match.range(at: 2), in: message) else { continue }
            result[String(message[tab])] = String(message[path]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
    public static func status(operation: BuildOperation, result: BridgeValue, isError: Bool) -> BuildStatus {
        if operation == .test {
            guard let total = result["counts"]["total"].integer, let failed = result["counts"]["failed"].integer, let notRun = result["counts"]["notRun"].integer else { return .unknown }
            if failed > 0 { return .failed }
            return total > 0 && notRun == 0 && !isError ? .succeeded : .unknown
        }
        let result = result["buildResult"].string?.lowercased() ?? ""
        if result.contains("fail") { return .failed }
        let successes: Set<String> = ["success", "build succeeded", "build succeeded.", "the project built successfully."]
        if !isError, successes.contains(result.trimmingCharacters(in: .whitespacesAndNewlines)) { return .succeeded }
        return .unknown
    }
}
