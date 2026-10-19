// Created by Василий Маслов on 16.10.2026.
import Foundation

/// Portable HTTP forms are separate from process actions: secret inputs never enter task history.
public struct ServiceTool: Codable, Equatable, Sendable, Identifiable {
    public struct Source: Codable, Equatable, Sendable {
        public let panelID: String
        public let namespaceField: String
        public let appVersionField: String
    }
    public struct Choice: Codable, Equatable, Sendable { public let value: String; public let title: String }
    public struct Field: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case text, integer, number, boolean, datetime }
        public let id: String
        public let title: String
        public let kind: Kind
        public let required: Bool
        public let defaultValue: String
        public let advanced: Bool
        public let secret: Bool
        public var source: String? = nil
        public var choices: [Choice]? = nil
        public var customChoice: Bool? = nil
        public var pattern: String? = nil
        public func accepts(_ value: String) -> Bool {
            if value.isEmpty { return !required }
            guard value.utf8.count <= 4096, !value.utf8.contains(0) else { return false }
            if let choices, customChoice != true, !choices.contains(where: { $0.value == value }) { return false }
            if let pattern, value.range(of: pattern, options: .regularExpression) == nil { return false }
            switch kind {
            case .integer: return value.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil && UInt64(value) != nil
            case .number: return Double(value).map { $0.isFinite && $0 > 0 } ?? false
            case .boolean: return ["true", "false"].contains(value)
            case .datetime:
                return ISO8601DateFormatter().date(from: value) != nil || Self.dateFormatter.date(from: value) != nil
            case .text: return true
            }
        }
        private static var dateFormatter: DateFormatter {
            let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(secondsFromGMT: 0)
            value.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; value.isLenient = false; return value
        }
    }
    public struct Variant: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let method: String
        public let path: String
        public let fields: [Field]
        public var responseKind: String? = nil
    }
    public struct Action: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let hint: String
        public let usesUID: Bool
        public let returnsUID: Bool
        public let variants: [Variant]
    }
    public let id: String
    public let title: String
    public let requiredFiles: [String]
    public let baseURLTemplate: String
    public let source: Source
    public let mcpAllowed: Bool
    public let actions: [Action]
    public func block(profileID: String) -> PanelBlockKind { PanelBlockKind(rawValue: "profile:" + profileID + ":" + id)! }
    public func matches(_ checkout: String) -> Bool { requiredFiles.allSatisfy { (try? ProfileValidation.checkoutPath($0, root: checkout)).map { FileManager.default.fileExists(atPath: $0) } == true } }

    // MARK: - Activation and request validation

    public func validate() throws {
        func identifier(_ s: String) -> Bool { s.range(of: #"^[A-Za-z][A-Za-z0-9._-]{0,79}$"#, options: .regularExpression) != nil }
        guard identifier(id), !title.isEmpty, title.count <= 80, !requiredFiles.isEmpty, requiredFiles.allSatisfy(ProfileValidation.relativePath),
              identifier(source.panelID), identifier(source.namespaceField), identifier(source.appVersionField),
              !actions.isEmpty, actions.count <= 32, Set(actions.map(\.id)).count == actions.count,
              baseURLTemplate.components(separatedBy: "{namespace}").count == 2 else { throw ProfileError.parameter }
        let base = try endpoint(namespace: "fixture")
        guard base.path.isEmpty || base.path == "/" else { throw ProfileError.path }
        for action in actions {
            guard identifier(action.id), !action.title.isEmpty, action.title.count <= 100, action.hint.count <= 500,
                  !action.variants.isEmpty, action.variants.count <= 8, Set(action.variants.map(\.id)).count == action.variants.count else { throw ProfileError.parameter }
            for variant in action.variants {
                guard identifier(variant.id), !variant.title.isEmpty, ["GET", "POST", "PUT", "DELETE"].contains(variant.method),
                      variant.path.hasPrefix("/"), ProfileValidation.relativePath(String(variant.path.dropFirst())),
                      !variant.path.contains("?"), !variant.path.contains("#"), !variant.path.contains("%"),
                      variant.fields.count <= 32, Set(variant.fields.map(\.id)).count == variant.fields.count else { throw ProfileError.parameter }
                guard ["object", "uid", "emptyObject", "null", "resultOK", "code"].contains(variant.responseKind ?? "object") else { throw ProfileError.parameter }
                for field in variant.fields {
                    guard identifier(field.id), field.id != "uid", !field.title.isEmpty, field.title.count <= 100,
                          field.source == nil || field.source == "appVersion", field.defaultValue.utf8.count <= 4096,
                          (field.choices?.count ?? 0) <= 100, field.secret || !["password", "session", "token"].contains(field.id.lowercased()) else { throw ProfileError.parameter }
                    if let pattern = field.pattern { guard pattern.count <= 512 else { throw ProfileError.parameter }; _ = try NSRegularExpression(pattern: pattern) }
                    if !field.defaultValue.isEmpty { guard field.accepts(field.defaultValue) else { throw ProfileError.parameter } }
                }
            }
        }
    }
    public func endpoint(namespace: String) throws -> URL {
        guard Self.validNamespace(namespace), let value = URLComponents(string: baseURLTemplate.replacingOccurrences(of: "{namespace}", with: namespace)),
              ["http", "https"].contains(value.scheme), value.host != nil, value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              let url = value.url else { throw ServiceToolError.namespace }
        return url
    }
    public static func validNamespace(_ value: String) -> Bool { value.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil }
    /// Endpoint details stay in the native profile; clients receive only form semantics.
    public var catalog: BridgeValue {
        .object(["id": .string(id), "title": .string(title), "actions": .array(actions.map { action in
            .object(["id": .string(action.id), "title": .string(action.title), "hint": .string(action.hint), "usesUID": .bool(action.usesUID), "returnsUID": .bool(action.returnsUID), "variants": .array(action.variants.map { variant in
                .object(["id": .string(variant.id), "title": .string(variant.title), "fields": (try? BridgeValue.encode(variant.fields)) ?? .array([])])
            })])
        })])
    }
}

public enum ServiceToolError: String, Error, Sendable { case namespace, arguments, duplicate, capacity, response, persistence, context }

/// The profile revision and confirmed application settings are part of every admission identity.
public struct ServiceToolContext: Codable, Equatable, Sendable {
    public let checkout: String
    public let profileRevision: String
    public let namespace: String
    public let appVersion: String
    public let sourceRevision: String
    public init(checkout: String, profileRevision: String, namespace: String, appVersion: String, sourceRevision: String) {
        self.checkout = checkout; self.profileRevision = profileRevision; self.namespace = namespace; self.appVersion = appVersion; self.sourceRevision = sourceRevision
    }
}

public enum ServiceToolBridge {
    public static let tools = ["get_service_tool_configuration", "run_service_tool_action", "get_service_tool_result"]
    public static let appTools = ["panel_service_configuration", "panel_service_run", "panel_service_result", "panel_service_save"]
}
