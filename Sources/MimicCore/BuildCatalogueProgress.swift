//
//  BuildCatalogueProgress.swift
//  MimicCore
//
//  Created by Василий Маслов on 22.10.2026.
import Foundation
import os

/// Completed discovery steps, never a time-based estimate of Xcode's remaining work.
public struct BuildCatalogueProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case checking, schemes, metadata, configurations, destinations, testPlans, verifying
    }
    public let phase: Phase
    public let completed: Int
    public let total: Int
    public let startedAt: Date
    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    public var step: Int { min(completed + 1, total) }
    public init(phase: Phase = .checking, completed: Int = 0, total: Int = 0, startedAt: Date = Date()) {
        self.phase = phase; self.completed = completed; self.total = total; self.startedAt = startedAt
    }
}

/// A synchronous process worker publishes into the same snapshot read by all coalesced observers.
final class BuildCatalogueProgressState: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: BuildCatalogueProgress())
    var snapshot: BuildCatalogueProgress { storage.withLock { $0 } }
    func update(phase: BuildCatalogueProgress.Phase, completed: Int, total: Int) {
        storage.withLock { $0 = .init(phase: phase, completed: completed, total: total, startedAt: $0.startedAt) }
    }
}
