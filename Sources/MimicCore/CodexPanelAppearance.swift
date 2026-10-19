//
//  CodexPanelAppearance.swift
//  MimicCore
//
//  Created by Василий Маслов on 12.10.2026.
import Foundation
import Observation

/// Wire-compatible theme names shared by native and Codex; workspace/layout owners stay independent.
public enum CodexPanelAppearance: String, Codable, CaseIterable, Sendable {
    case tileGrid, legacy, windows95, windowsXP
}

/// Revision and selection are persisted together; layout revisions belong to a different store.
public struct CodexAppearanceSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let selection: CodexPanelAppearance
    public let revision: Int
    public init(selection: CodexPanelAppearance, revision: Int = 0) {
        self.version = 1; self.selection = selection; self.revision = revision
    }
}

public enum CodexAppearanceError: Error { case conflict, invalid }

/// The native owner serializes saves. A failed atomic write never publishes a new revision.
@MainActor @Observable public final class CodexPanelAppearanceStore {
    public private(set) var value: CodexAppearanceSnapshot
    public private(set) var persistenceFailed = false
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let write: (Data, URL) throws -> Void
    /// Native editing may defer presentation during IME composition. Persistence still commits first.
    @ObservationIgnored public var selectionWillChange: (() -> Void)?

    public init(directory: URL, previous: PanelAppearance, write: @escaping (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }) {
        self.url = directory.appendingPathComponent("codex-appearance.json")
        self.write = write
        self.value = .init(selection: CodexPanelAppearance(rawValue: previous.rawValue) ?? .tileGrid)
        if FileManager.default.fileExists(atPath: self.url.path) {
            // Existing but damaged data must not silently repeat migration from desktop.
            do {
                let saved = try JSONDecoder().decode(CodexAppearanceSnapshot.self, from: Data(contentsOf: self.url))
                guard saved.version == 1, saved.revision >= 0, saved.revision < Int.max else { throw CodexAppearanceError.invalid }
                self.value = saved
            } catch { self.value = .init(selection: .tileGrid); self.persistenceFailed = true }
        } else {
            do { try self.persist(self.value) } catch { self.persistenceFailed = true }
        }
    }

    /// Compare-and-save is synchronous on the owner actor, including replacement of the JSON file.
    @discardableResult public func select(_ appearance: CodexPanelAppearance, expectedRevision: Int) throws -> CodexAppearanceSnapshot {
        guard expectedRevision == self.value.revision else { throw CodexAppearanceError.conflict }
        guard self.value.revision < Int.max - 1 else { throw CodexAppearanceError.invalid }
        if appearance == self.value.selection, !self.persistenceFailed { return self.value }
        let next = CodexAppearanceSnapshot(selection: appearance, revision: self.value.revision + 1)
        try self.persist(next)
        self.selectionWillChange?()
        self.value = next; self.persistenceFailed = false
        return next
    }

    private func persist(_ snapshot: CodexAppearanceSnapshot) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try self.write(encoder.encode(snapshot), self.url)
    }
}
