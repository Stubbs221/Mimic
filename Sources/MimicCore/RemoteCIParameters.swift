//
//  RemoteCIParameters.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Combine
import Foundation

// MARK: - Job contracts

/// The launch surface is intentionally limited to these existing Jenkins jobs.
public enum RemoteCIKind: String, Codable, CaseIterable, Sendable {
    case uiTests, qualityGates, beta
    public var job: String {
        switch self {
        case .uiTests: "uiTests"
        case .qualityGates: "qualityGates"
        case .beta: "beta"
        }
    }
    public var localizationKey: String { "ci.kind." + self.rawValue }
    public var branchParameter: String { self == .uiTests ? "BRANCH" : "SELECTED_BRANCH" }
}

public enum QualityGate: String, Codable, CaseIterable, Sendable {
    case locales = "QG_LOCALIZATION_CHECK"
    case unitIOS = "QG_UNIT_TESTS_IOS", unitTVOS = "QG_UNIT_TESTS_TVOS"
    case snapshotIOS = "QG_SNAPSHOT_TESTS_IOS", snapshotTVOS = "QG_SNAPSHOT_TESTS_TVOS"
    case buildIOS = "QG_BUILD_APPS_IOS", buildTVOS = "QG_BUILD_APPS_TVOS"
    case performance = "QG_VIEW_RENDERING_PERFORMANCE"
    public var localizationKey: String { "ci.gate." + self.rawValue }
}

/// Parameters are frozen with the request, including the Beta defaults the user reviewed.
public enum RemoteCIParameters: Codable, Sendable, Equatable {
    case uiTests(UITestPlan)
    case qualityGates([QualityGate: Bool])
    case beta(target: String, rebase: String, upload: String)
    public var kind: RemoteCIKind {
        switch self { case .uiTests: .uiTests; case .qualityGates: .qualityGates; case .beta: .beta }
    }
    public var fields: [String: String] {
        switch self {
        case .uiTests(let plan): ["TEST_PLAN": plan.rawValue]
        case .qualityGates(let gates): Dictionary(uniqueKeysWithValues: gates.map { ($0.key.rawValue, $0.value ? "true" : "false") })
        case .beta(let target, let rebase, let upload): ["TARGET": target, "REBASE_BRANCH": rebase, "UPLOAD_TO_APP_DISTRIBUTION": upload]
        }
    }
}

/// Only allowlisted parameter definitions are retained; arbitrary server fields are discarded.
public struct JenkinsJobContract: Sendable, Equatable {
    public let kind: RemoteCIKind
    public let defaults: [String: String]
    public let choices: [String: [String]]
    public let usesGitParameter: Bool
    /// Fetched only at admission; changing the branch list does not change reviewed form defaults.
    public let branchValues: Set<String>?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.defaults == rhs.defaults && lhs.choices == rhs.choices && lhs.usesGitParameter == rhs.usesGitParameter
    }

    /// Keep GitLab/history identity unchanged and translate only the Jenkins wire value.
    public func branchValue(for branch: String) throws -> String {
        guard self.usesGitParameter else { return branch }
        guard let branchValues, !branchValues.isEmpty else { throw JenkinsConnectionError.branchValuesUnavailable }
        // Prefer the remote-qualified branch: Beta can also list an identically named tag.
        if branchValues.contains("origin/" + branch) { return "origin/" + branch }
        guard branchValues.contains(branch) else { throw JenkinsConnectionError.branchUnavailable }
        return branch
    }

    public func parameters(plan: UITestPlan = .smoke, gates: [QualityGate: Bool]? = nil) -> RemoteCIParameters {
        switch self.kind {
        case .uiTests: .uiTests(plan)
        case .qualityGates: .qualityGates(gates ?? Dictionary(uniqueKeysWithValues: QualityGate.allCases.map { ($0, self.defaults[$0.rawValue] == "true") }))
        case .beta: .beta(target: self.defaults["TARGET"]!, rebase: self.defaults["REBASE_BRANCH"]!, upload: self.defaults["UPLOAD_TO_APP_DISTRIBUTION"]!)
        }
    }
    public func validates(_ parameters: RemoteCIParameters) -> Bool {
        guard parameters.kind == self.kind else { return false }
        switch parameters {
        case .uiTests(let plan): return self.choices["TEST_PLAN"]?.contains(plan.rawValue) == true
        case .qualityGates(let gates): return Set(gates.keys) == Set(QualityGate.allCases)
        case .beta: return parameters.fields == self.defaults.filter { $0.key != self.kind.branchParameter }
        }
    }
}

// MARK: - Launch preferences

/// Additional launch buttons are global preferences; they do not filter history or stop remote jobs.
@MainActor public final class CILaunchPreferences: ObservableObject {
    @Published public var qualityGates: Bool { didSet { self.defaults.set(self.qualityGates, forKey: "ci.launch.qualityGates") } }
    @Published public var beta: Bool { didSet { self.defaults.set(self.beta, forKey: "ci.launch.beta") } }
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; self.qualityGates = defaults.bool(forKey: "ci.launch.qualityGates"); self.beta = defaults.bool(forKey: "ci.launch.beta")
    }
    public var kinds: [RemoteCIKind] { [.uiTests] + (self.qualityGates ? [.qualityGates] : []) + (self.beta ? [.beta] : []) }
}
