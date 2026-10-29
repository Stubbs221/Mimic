//
//  BuildAdmissionPayload.swift
//  Mimic
//
//  Created by Василий Маслов on 28.10.2026.
import Foundation
import MimicCore

/// Identity reserved synchronously before admission suspends; source labels are presentation only.
struct BuildAdmissionPayload: Equatable, Sendable {
    let project: ProjectContext
    let parameters: BuildParameters
    let owner: String?
    let workflowID: String?
    let selectionID: UUID?
    let revision: SourceRevision?
    let expectedCases: [String: [String]]?
    let cleanupArtifacts: [ManagedArtifact]?
    let cleanupActivityID: UUID?
    let simulatorConfirmed: Bool
    let enqueue: Bool
}
