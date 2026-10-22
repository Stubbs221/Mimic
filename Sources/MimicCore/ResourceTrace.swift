//
//  ResourceTrace.swift
//  MimicCore
//
//  Created by Василий Маслов on 21.10.2026.
import os

/// Resource signposts contain only fixed causes and numeric request identities, never user payloads.
public enum ResourceTrace {
    private static let log = OSLog(subsystem: "local.vmaslov.Mimic", category: .pointsOfInterest)
    public static func begin(_ name: StaticString, cause: StaticString) -> OSSignpostID {
        guard log.signpostsEnabled else { return .invalid }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id, "cause=%{public}@", String(describing: cause))
        return id
    }
    public static func end(_ name: StaticString, _ id: OSSignpostID) {
        guard id != .invalid else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
    public static func event(_ name: StaticString) { guard log.signpostsEnabled else { return }; os_signpost(.event, log: log, name: name) }
}
