//
//  QueuePolicy.swift
//  MimicCore
//
//  Created by Василий Маслов on 01.10.2026.
import Foundation

/// Queue admission is global: scripts can mutate shared user-level developer settings.
public enum QueuePolicy {
    public static func next(in records: [TaskRecord]) -> TaskRecord? {
        guard !records.contains(where: { $0.status == .running }) else { return nil }
        return records.first { $0.status == .queued }
    }

    public enum Activity: Equatable, Sendable { case legacy(UUID), build(UUID), simulator(UUID) }
    /// The earliest admitted mutation wins across all histories; uncertain Xcode work holds the queue.
    public static func nextActivity(in records: [TaskRecord], builds: [BuildActivity], simulators: [SimulatorActivity] = []) -> Activity? {
        guard !records.contains(where: { $0.status == .running }), !builds.contains(where: { $0.status == .running || $0.status == .preparing || ($0.status == .unknown && $0.queueReleased != true) }) else { return nil }
        guard !simulators.contains(where: \.holdsQueue) else { return nil }
        let simulator = simulators.filter { $0.status == .queued }.min { $0.createdAt < $1.createdAt }
        let legacy = records.filter { $0.status == .queued }.min { $0.createdAt < $1.createdAt }
        let build = builds.filter { $0.status == .queued }.min { $0.createdAt < $1.createdAt }
        if let simulator, legacy.map({ simulator.createdAt < $0.createdAt }) ?? true, build.map({ simulator.createdAt < $0.createdAt }) ?? true { return .simulator(simulator.id) }
        if let build, legacy.map({ build.createdAt < $0.createdAt }) ?? true { return .build(build.id) }
        return legacy.map { .legacy($0.id) }
    }

    public static func matches(_ actual: ProjectContext, request: ProjectContext) -> Bool {
        actual.path == request.path && actual.branch == request.branch && actual.commit == request.commit && actual.developerDirectory == request.developerDirectory && actual.appleTarget == request.appleTarget
    }
}
