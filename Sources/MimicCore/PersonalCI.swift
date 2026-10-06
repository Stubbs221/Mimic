//
//  PersonalCI.swift
//  MimicCore
//
//  Created by Василий Маслов on 05.10.2026.
import Foundation

/// Public account identity only; credentials and private user fields are never persisted here.
public struct CIUser: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let username: String
    public let name: String
    public init(id: Int, username: String, name: String) {
        self.id = id; self.username = username; self.name = name
    }
}

/// One ordered page, including the server's continuation rather than an inferred page count.
public struct CIPipelinePage: Sendable {
    public let pipelines: [CIPipeline]
    public let nextPage: Int?
    public init(pipelines: [CIPipeline], nextPage: Int? = nil) {
        self.pipelines = pipelines; self.nextPage = nextPage
    }
}

/// Explains why a pipeline belongs in the personal feed without guessing its initiator.
public enum CIOwnershipReason: String, CaseIterable, Sendable {
    case initiator, branch, jenkins
    public var localizationKey: String { "ci.reason." + self.rawValue }
}

/// A subscription loads only pipelines initiated by this account, never its branch namespace.
public struct CITrackedUser: Identifiable, Sendable {
    public let user: CIUser
    public var pipelines: [CIPipeline]
    public var error: CIError?
    public var loadedAt: Date?
    public var id: Int { self.user.id }
    public init(user: CIUser, pipelines: [CIPipeline] = [], error: CIError? = nil, loadedAt: Date? = nil) {
        self.user = user; self.pipelines = pipelines; self.error = error; self.loadedAt = loadedAt
    }
}

/// Subscriptions are isolated by server, project and authenticated account, not checkout or token.
@MainActor public protocol CITrackingStore {
    func users(connection: GitLabConnection, owner: CIUser) -> [CIUser]
    func save(_ users: [CIUser], connection: GitLabConnection, owner: CIUser)
}

@MainActor public struct DefaultsCITrackingStore: CITrackingStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ connection: GitLabConnection, _ owner: CIUser) -> String {
        "personalCI." + connection.baseURL.absoluteString + "." + String(connection.projectID) + "." + String(owner.id)
    }
    public func users(connection: GitLabConnection, owner: CIUser) -> [CIUser] {
        guard let data = self.defaults.data(forKey: self.key(connection, owner)) else { return [] }
        return (try? JSONDecoder().decode([CIUser].self, from: data)) ?? []
    }
    public func save(_ users: [CIUser], connection: GitLabConnection, owner: CIUser) {
        if let data = try? JSONEncoder().encode(users) { self.defaults.set(data, forKey: self.key(connection, owner)) }
    }
}

/// Branch ownership is a naming convention: <type>/<exact username>/<nonempty remainder>.
public enum CIPersonalSelection {
    public static func owns(ref: String, username: String, pattern: String? = nil) -> Bool {
        guard let pattern, !username.isEmpty, let regex = try? NSRegularExpression(pattern: pattern.replacingOccurrences(of: "{username}", with: NSRegularExpression.escapedPattern(for: username))) else { return false }
        return regex.firstMatch(in: ref, range: NSRange(ref.startIndex..., in: ref)) != nil
    }
    /// Returns unique pipelines in descending ID order; presentation owns the visible limit.
    public static func latest(_ values: [CIPipeline], projectID: Int) -> [CIPipeline] {
        var seen = Set<Int>()
        return Array(values.filter { $0.projectID == nil || $0.projectID == projectID }
            .sorted { $0.id > $1.id }.filter { seen.insert($0.id).inserted })
    }
}
