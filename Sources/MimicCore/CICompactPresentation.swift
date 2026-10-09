//
//  CICompactPresentation.swift
//  MimicCore
//
//  Created by Василий Маслов on 09.10.2026.
import Foundation
import Observation

/// Native compact readers observe only their committed projection, independently of detail requests.
@MainActor @Observable public final class CICompactPresentation {
    public internal(set) var summaries: [CICompactSummary] = []
    public internal(set) var footer = CICompactFooter()
}

/// Footer inputs retain exact identity, errors and freshness without subscribing to full CI history.
public struct CICompactFooter: Equatable, Sendable {
    public var loading = false
    public var error: CIError?
    public var pipeline: CIPipeline?
    public var context: CIContext?
    public var loadedAt: Date?
    public var historyIncomplete = false
}
