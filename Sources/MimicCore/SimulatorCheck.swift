//
//  SimulatorCheck.swift
//  MimicCore
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation

public struct SimulatorBuildBinding: Codable, Sendable {
    public let sessionID: UUID
    public let deviceID: UUID
    public let activityID: UUID
    public let productID: String
    public let sourceRevision: SourceRevision
    public let project: ProjectContext
    public init(sessionID: UUID, deviceID: UUID, activityID: UUID, productID: String, sourceRevision: SourceRevision, project: ProjectContext) { self.sessionID = sessionID; self.deviceID = deviceID; self.activityID = activityID; self.productID = productID; self.sourceRevision = sourceRevision; self.project = project }
}

/// The event stream contains operation metadata and explicit observation references, never typed text.
public struct SimulatorCheckRecord: Codable, Sendable {
    public struct Event: Codable, Sendable {
        public let at: Date
        public let kind: String
        public let activityID: UUID?
        public let revision: UInt64?
        public let artifact: String?
    }
    public let id: UUID
    public let owner: String?
    public let workflowID: UUID
    public let binding: SimulatorBuildBinding
    public let startedAt: Date
    public var finishedAt: Date?
    public var status = "recording"
    public var events: [Event] = []
    public var truncated = false
    public var recordingID: UUID?
    public var video: SimulatorRecordingResult?
    public init(id: UUID, owner: String?, workflowID: UUID, binding: SimulatorBuildBinding) {
        self.id = id; self.owner = owner; self.workflowID = workflowID; self.binding = binding; startedAt = Date()
    }
    public mutating func append(kind: String, activityID: UUID? = nil, revision: UInt64? = nil, artifact: String? = nil) {
        guard events.count < 500 else { truncated = true; return }
        events.append(.init(at: Date(), kind: kind, activityID: activityID, revision: revision, artifact: artifact))
    }
}

public struct SimulatorRecordingResult: Codable, Sendable {
    public let path: String
    public let frames: Int
    public let droppedFrames: Int
    public let status: String
    public let error: String?
    public init(path: String, frames: Int, droppedFrames: Int, status: String, error: String?) { self.path = path; self.frames = frames; self.droppedFrames = droppedFrames; self.status = status; self.error = error }
}

/// Values are constructed only after resolving a build product or trusted scenario in the native facade.
public struct SimulatorAppRequest: Codable, Equatable, Sendable {
    public let product: BuildProduct?
    public let deeplink: String?
    public let revision: SourceRevision
    public let exclusions: [String]
    public let artifact: ManagedArtifact?
    public let artifactRoot: String?
    public init(product: BuildProduct?, deeplink: String?, revision: SourceRevision, exclusions: [String], artifact: ManagedArtifact? = nil, artifactRoot: String? = nil) { self.product = product; self.deeplink = deeplink; self.revision = revision; self.exclusions = exclusions; self.artifact = artifact; self.artifactRoot = artifactRoot }
}
