// Created by Василий Маслов on 16.10.2026.
import Foundation

/// A portable scalar form. Project-specific labels, applications and behavior live in the profile.
public struct ProfilePanel: Codable, Equatable, Sendable, Identifiable {
    /// Optional patterns describe nonnumeric scalar fields without project-specific renderer code.
    public struct Field: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public var pattern: String? = nil
        public var placeholder: String? = nil
        public func accepts(_ value: String) -> Bool {
            guard !value.isEmpty else { return true }
            if let pattern {
                return value.utf8.count <= 128 && value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
            }
            return ProfilePanel.validValue(value)
        }
    }
    public struct Application: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
    }
    public let id: String
    public let title: String
    public let actionID: String
    public let requiredFiles: [String]
    public let applications: [Application]
    public let fields: [Field]
    public func block(profileID: String) -> PanelBlockKind { PanelBlockKind(rawValue: "profile:" + profileID + ":" + id)! }
    public func matches(checkout: String) -> Bool {
        requiredFiles.allSatisfy { path in
            (try? ProfileValidation.checkoutPath(path, root: checkout)).map { FileManager.default.fileExists(atPath: $0) } == true
        }
    }

    // MARK: - Validation

    private static func identifier(_ value: String) -> Bool { value.range(of: #"^[A-Za-z][A-Za-z0-9._-]{0,79}$"#, options: .regularExpression) != nil }
    public static let parameterIDs: Set<String> = ["operation", "device", "application", "values", "field", "expectedRevision", "force"]
    public static let operations = ["catalog", "read", "apply", "reset", "resetAll", "launch"]
    public static func validate(profile: MimicProfile) throws {
        let panels = profile.panels ?? []
        guard panels.count <= 32, Set(panels.map(\.id)).count == panels.count,
              Set(panels.map(\.actionID)).count == panels.count else { throw ProfileError.interface }
        for panel in panels {
            for field in panel.fields {
                guard field.placeholder?.count ?? 0 <= 80 else { throw ProfileError.parameter }
                if let pattern = field.pattern { guard pattern.utf8.count <= 512 else { throw ProfileError.parameter }; _ = try NSRegularExpression(pattern: pattern) }
            }
            guard identifier(profile.id), identifier(panel.id),
                  !panel.title.isEmpty, panel.title.count <= 80, (1...3).contains(panel.fields.count),
                  !panel.requiredFiles.isEmpty, panel.requiredFiles.allSatisfy(ProfileValidation.relativePath),
                  Set(panel.fields.map(\.id)).count == panel.fields.count,
                  panel.fields.allSatisfy({ identifier($0.id) && !$0.title.isEmpty && $0.title.count <= 40 }),
                  !panel.applications.isEmpty, panel.applications.count <= 20,
                  Set(panel.applications.map(\.id)).count == panel.applications.count,
                  panel.applications.allSatisfy({ identifier($0.id) && !$0.title.isEmpty && $0.title.count <= 100 }),
                  let action = profile.actions.first(where: { $0.id == panel.actionID }),
                  action.remote == nil, action.presentation == .regular, action.allowsMCP,
                  action.logPolicy == .metadataOnly, !action.requiresXcodeQuit,
                  Set(action.parameters.map(\.id)) == parameterIDs,
                  profile.interface?.bindings.contains(where: { $0.actionID == action.id }) != true else { throw ProfileError.interface }
        }
    }
    /// Direct agent actions and native controls share validation before any adapter can execute.
    public func validateRequest(_ parameters: [String: String]) throws {
        guard Set(parameters.keys) == Self.parameterIDs, let operation = parameters["operation"], Self.operations.contains(operation),
              parameters["force"] == "true" || parameters["force"] == "false",
              parameters["expectedRevision", default: ""].utf8.count <= 128,
              let data = parameters["values"]?.data(using: .utf8), data.count <= 4096,
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              Set(values.keys).isSubset(of: Set(fields.map(\.id))),
              values.allSatisfy({ key, value in fields.first(where: { $0.id == key })?.accepts(value) == true }) else { throw ProfileError.parameter }
        if operation != "catalog" {
            guard UUID(uuidString: parameters["device", default: ""]) != nil,
                  applications.contains(where: { $0.id == parameters["application"] }) else { throw ProfileError.parameter }
        }
        if operation == "apply" { guard Set(values.keys) == Set(fields.map(\.id)) else { throw ProfileError.parameter } }
        if operation == "reset" { guard fields.contains(where: { $0.id == parameters["field"] }) else { throw ProfileError.parameter } }
        if ["apply", "reset", "resetAll"].contains(operation) {
            guard parameters["expectedRevision"]?.isEmpty == false else { throw ProfileError.parameter }
        }
    }
    public static func validValue(_ value: String) -> Bool {
        value.isEmpty || (value.utf8.count <= 20 && value.first != "0" && value.utf8.allSatisfy { (48...57).contains($0) })
    }
}

extension MimicProfile {
    public func panel(forAction actionID: String) -> ProfilePanel? { panels?.first { $0.actionID == actionID } }
    public func panels(checkout: String?) -> [ProfilePanel] { checkout.map { path in (panels ?? []).filter { $0.matches(checkout: path) } } ?? [] }
}

/// Only form data crosses this boundary; arbitrary adapter output never becomes a task result.
public struct ProfilePanelResult: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
    }
    public let status: String
    public let values: [String: String]
    public let revision: String
    public let devices: [Device]
    public let developerMode: Bool
    public static func parse(_ output: Data, panel: ProfilePanel) -> Self? {
        let lines = String(decoding: output.suffix(128 * 1024), as: UTF8.self).components(separatedBy: .newlines)
        guard let line = lines.last(where: { $0.hasPrefix("MIMIC_PANEL_RESULT ") }),
              let data = String(line.dropFirst(19)).data(using: .utf8),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              ["ready", "saved", "launchFailed", "conflict", "failed", "rollbackFailed", "unavailable", "shutdown", "notInstalled"].contains(result.status),
              Set(result.values.keys).isSubset(of: Set(panel.fields.map(\.id))),
              result.values.allSatisfy({ key, value in panel.fields.first(where: { $0.id == key })?.accepts(value) == true && DiagnosticText.clean(value) == value }),
              result.revision.utf8.count <= 128,
              !result.revision.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (result.revision.utf8.count == 64 && result.revision.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }) || DiagnosticText.clean(result.revision) == result.revision,
              result.devices.count <= 200, Set(result.devices.map { $0.id.uppercased() }).count == result.devices.count,
              result.devices.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.title.utf8.count <= 512 && DiagnosticText.clean($0.title) == $0.title }) else { return nil }
        return result
    }
}

extension PanelLayoutStore {
    /// A durable introduction marker prevents deleted custom tiles reappearing on every poll/import.
    public func introduce(_ panels: [ProfilePanel], profileID: String, checkout: String, surface: PanelSurface) -> PanelLayout {
        var layout = prepareForPresentation(surface)
        for panel in panels {
            let block = panel.block(profileID: profileID)
            let marker = "profilePanel.introduced." + surface.rawValue + ":" + checkout + ":" + block.rawValue
            guard !defaults.bool(forKey: marker) else { continue }
            if !layout.blocks.contains(block) {
                var next = layout
                do {
                    try next.add(block, size: .mini); next.compact()
                    layout = try save(next, for: surface, expectedRevision: layout.revision)
                } catch { continue }
            }
            defaults.set(true, forKey: marker)
        }
        return layout
    }
}
