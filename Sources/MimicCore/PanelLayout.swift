//
//  PanelLayout.swift
//  MimicCore
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation

/// Surface-specific layouts share placement rules, but never copy unavailable blocks between surfaces.
public enum PanelSurface: String, Codable, Sendable { case desktop, codex }

/// Stable presentation identities; profile action identifiers remain independent of the layout.
public enum PanelBlockKind: String, Codable, CaseIterable, Sendable {
    case bootstrap, utils, builds, ci, simulators, ai
    case generateUI, generateSicilia, generateGalera, localization, protocols, format
    case fullCleanup, derivedDataCleanup, uiTests, qualityGates, beta

    public var titleKey: String { "panel.block." + rawValue }
    public var role: ProfileToolRole? { ProfileToolRole(rawValue: rawValue) }
    public var symbol: String {
        switch self {
        case .bootstrap: "shippingbox"
        case .utils: "wrench.and.screwdriver"
        case .builds: "hammer"
        case .ci, .uiTests, .qualityGates, .beta: "checkmark.seal"
        case .simulators: "iphone"
        case .ai: "sparkles"
        case .generateUI, .generateSicilia, .generateGalera: "square.stack.3d.up"
        case .localization: "character.bubble"
        case .protocols: "arrow.triangle.branch"
        case .format: "text.alignleft"
        case .fullCleanup, .derivedDataCleanup: "trash"
        }
    }
    public static func catalog(for surface: PanelSurface) -> [Self] { allCases.filter { surface == .desktop || $0 != .ai } }
}

public enum PanelBlockSize: String, Codable, Sendable { case full, mini }
public enum PanelLayoutError: Error, Equatable { case invalid, duplicate, occupied, missing, conflict }

/// A logical destination is independent of animated frames; optional insertion sizing is separate.
public enum PanelInsertionTarget: Equatable, Sendable {
    case slot(row: UUID, slot: Int)
    case boundary(before: UUID?)
}

/// One slot is full width; two slots are independent halves. A lone mini block keeps its empty neighbour.
public struct PanelLayoutRow: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var slots: [PanelBlockKind?]
    public init(id: UUID = UUID(), slots: [PanelBlockKind?]) { self.id = id; self.slots = slots }
    public var blocks: [PanelBlockKind] { slots.compactMap { $0 } }
    public var size: PanelBlockSize { slots.count == 1 ? .full : .mini }
}

/// Layout changes are transactional values. Execution, drafts and temporary expansion are not stored here.
public struct PanelLayout: Codable, Equatable, Sendable {
    public let version: Int
    public var revision: Int
    public var rows: [PanelLayoutRow]
    public init(version: Int = 1, revision: Int = 0, rows: [PanelLayoutRow]) {
        self.version = version; self.revision = revision; self.rows = rows
    }
    public var blocks: [PanelBlockKind] { rows.flatMap(\.blocks) }
    public func size(of block: PanelBlockKind) -> PanelBlockSize? { rows.first { $0.blocks.contains(block) }?.size }
    public static func standard(for surface: PanelSurface) -> Self {
        // Reading an unsaved default must preserve row identity across polling and edit cancellation.
        let identities = (1...4).map { UUID(uuidString: "00000000-0000-4000-8000-00000000000\($0)")! }
        var rows = [PanelLayoutRow(id: identities[0], slots: [.bootstrap]), PanelLayoutRow(id: identities[1], slots: [.utils, .builds]), PanelLayoutRow(id: identities[2], slots: [.ci, .simulators])]
        if surface == .desktop { rows.append(PanelLayoutRow(id: identities[3], slots: [.ai])) }
        return Self(rows: rows)
    }

    public func validate(for surface: PanelSurface) throws {
        guard version == 1, revision >= 0, rows.count <= PanelBlockKind.allCases.count,
              Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ (1...2).contains($0.slots.count) && !$0.blocks.isEmpty }),
              Set(blocks).isSubset(of: Set(PanelBlockKind.catalog(for: surface))) else { throw PanelLayoutError.invalid }
        guard Set(blocks).count == blocks.count else { throw PanelLayoutError.duplicate }
    }

    // MARK: - Editing

    /// Inserts without overwriting a block. Within a mini run only the traversed slots rotate;
    /// across full-row boundaries displacement ends at the next vacancy or a new mini row.
    /// Optional size/side changes are atomic. Session-owned generated IDs stabilize transient rows;
    /// omitted options preserve the source size and existing insertion behavior.
    public mutating func insert(_ block: PanelBlockKind, at destination: PanelInsertionTarget, size: PanelBlockSize? = nil, miniSlot: Int? = nil, generatedRowIDs: [UUID] = []) throws {
        // Size and placement commit together; IDs supplied by a drag remain stable across previews.
        if size != nil || miniSlot != nil {
            if let miniSlot, !(0...1).contains(miniSlot) { throw PanelLayoutError.invalid }
            var next = self
            if let size { try next.resize(block, to: size) }
            try next.insert(block, at: destination)
            if case .boundary = destination, let miniSlot,
               let index = next.rows.firstIndex(where: { $0.blocks == [block] && $0.size == .mini }) {
                next.rows[index].slots = miniSlot == 0 ? [block, nil] : [nil, block]
            }
            let originalIDs = Set(rows.map(\.id))
            var generated = generatedRowIDs.makeIterator()
            next.rows = next.rows.map { row in
                guard !originalIDs.contains(row.id), let id = generated.next() else { return row }
                return PanelLayoutRow(id: id, slots: row.slots)
            }
            self = next
            return
        }
        guard let source = rows.firstIndex(where: { $0.blocks.contains(block) }),
              let sourceSlot = rows[source].slots.firstIndex(of: block) else { throw PanelLayoutError.missing }
        var next = self
        switch destination {
        case .boundary(let before):
            if before == rows[source].id { return }
            if let before, !rows.contains(where: { $0.id == before }) { throw PanelLayoutError.missing }
            let item = rows[source].size == .full ? rows[source] : PanelLayoutRow(slots: [block, nil])
            next.remove(block)
            let index = before.flatMap { id in next.rows.firstIndex { $0.id == id } } ?? next.rows.count
            next.rows.insert(item, at: index)
        case .slot(let rowID, let slot):
            guard rows[source].size == .mini, (0...1).contains(slot),
                  let target = rows.firstIndex(where: { $0.id == rowID }), rows[target].size == .mini else { throw PanelLayoutError.invalid }
            if target == source && slot == sourceSlot { return }
            if rows[target].slots[slot] == nil {
                next.rows[source].slots[sourceSlot] = nil
                next.rows[target].slots[slot] = block
            } else {
                var start = target, end = target
                while start > 0 && rows[start - 1].size == .mini { start -= 1 }
                while end + 1 < rows.count && rows[end + 1].size == .mini { end += 1 }
                if (start...end).contains(source) {
                    var slots = rows[start...end].flatMap(\.slots)
                    let from = (source - start) * 2 + sourceSlot, to = (target - start) * 2 + slot
                    slots.remove(at: from); slots.insert(block, at: to)
                    for index in start...end { next.rows[index].slots = Array(slots[(index - start) * 2..<(index - start) * 2 + 2]) }
                } else {
                    next.rows[source].slots[sourceSlot] = nil
                    var carry: PanelBlockKind? = block
                    for index in target...end {
                        for half in (index == target ? slot : 0)...1 {
                            guard let value = carry else { break }
                            carry = next.rows[index].slots[half]; next.rows[index].slots[half] = value
                        }
                        if carry == nil { break }
                    }
                    if let carry { next.rows.insert(PanelLayoutRow(slots: [carry, nil]), at: end + 1) }
                }
            }
            next.rows.removeAll { $0.blocks.isEmpty }
        }
        self = next
    }

    public mutating func remove(_ block: PanelBlockKind) {
        for index in rows.indices { rows[index].slots = rows[index].slots.map { $0 == block ? nil : $0 } }
        rows.removeAll { $0.blocks.isEmpty }
    }

    public mutating func add(_ block: PanelBlockKind, size: PanelBlockSize = .full, before rowID: UUID? = nil) throws {
        guard !blocks.contains(block) else { throw PanelLayoutError.duplicate }
        let index: Int
        if let rowID { guard let found = rows.firstIndex(where: { $0.id == rowID }) else { throw PanelLayoutError.missing }; index = found }
        else { index = rows.count }
        rows.insert(PanelLayoutRow(slots: size == .full ? [block] : [block, nil]), at: index)
    }

    /// Removing a source and inserting it only commits after the target has been checked.
    public mutating func move(_ block: PanelBlockKind, before rowID: UUID?) throws {
        guard let size = size(of: block) else { throw PanelLayoutError.missing }
        if let rowID, rows.first(where: { $0.id == rowID })?.blocks.contains(block) == true { return }
        var next = self; next.remove(block); try next.add(block, size: size, before: rowID); self = next
    }

    public mutating func move(_ block: PanelBlockKind, to rowID: UUID, slot: Int) throws {
        guard let target = rows.firstIndex(where: { $0.id == rowID }), rows[target].slots.count == 2,
              (0...1).contains(slot) else { throw PanelLayoutError.missing }
        guard rows[target].slots[slot] == nil else { throw PanelLayoutError.occupied }
        guard size(of: block) == .mini else { throw PanelLayoutError.invalid }
        var next = self; next.remove(block)
        guard let index = next.rows.firstIndex(where: { $0.id == rowID }) else { throw PanelLayoutError.missing }
        next.rows[index].slots[slot] = block; self = next
    }

    public mutating func resize(_ block: PanelBlockKind, to size: PanelBlockSize) throws {
        guard let index = rows.firstIndex(where: { $0.blocks.contains(block) }) else { throw PanelLayoutError.missing }
        guard rows[index].size != size else { return }
        if size == .mini { rows[index].slots = [block, nil] }
        else {
            let neighbour = rows[index].blocks.first { $0 != block }
            rows[index].slots = [block]
            if let neighbour { rows.insert(PanelLayoutRow(slots: [neighbour, nil]), at: index + 1) }
        }
    }

    public mutating func replace(_ block: PanelBlockKind, with replacement: PanelBlockKind) throws {
        guard !blocks.contains(replacement) else { throw PanelLayoutError.duplicate }
        guard let index = rows.firstIndex(where: { $0.blocks.contains(block) }),
              let slot = rows[index].slots.firstIndex(of: block) else { throw PanelLayoutError.missing }
        rows[index].slots[slot] = replacement
    }
}

// MARK: - Persistence

/// Compare-and-save prevents another chat's completed edit from being overwritten by an older draft.
@MainActor public final class PanelLayoutStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ surface: PanelSurface) -> String { "panelLayout." + surface.rawValue }
    public func load(_ surface: PanelSurface) -> PanelLayout {
        guard let data = defaults.data(forKey: key(surface)), let layout = try? JSONDecoder().decode(PanelLayout.self, from: data),
              (try? layout.validate(for: surface)) != nil else { return .standard(for: surface) }
        return layout
    }
    @discardableResult public func save(_ draft: PanelLayout, for surface: PanelSurface, expectedRevision: Int) throws -> PanelLayout {
        try draft.validate(for: surface)
        guard load(surface).revision == expectedRevision else { throw PanelLayoutError.conflict }
        var saved = draft; saved.revision = expectedRevision + 1
        defaults.set(try JSONEncoder().encode(saved), forKey: key(surface)); return saved
    }
}
