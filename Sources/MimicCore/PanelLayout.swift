//
//  PanelLayout.swift
//  MimicCore
//
//  Created by Василий Маслов on 06.10.2026.
import Foundation

/// Surface-specific layouts share placement rules, but never copy unavailable blocks between surfaces.
public enum PanelSurface: String, Codable, Sendable { case desktop, codex }

/// Stable presentation identities; profile action identifiers remain independent of the layout.
public struct PanelBlockKind: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard Self.builtinNames.contains(rawValue) || rawValue.range(of: #"^profile:[a-zA-Z0-9._-]{1,100}:[a-zA-Z0-9._-]{1,100}$"#, options: .regularExpression) != nil else { return nil }
        self.rawValue = rawValue
    }
    private init(_ value: String) { rawValue = value }
    public static let bootstrap = Self("bootstrap")
    public static let utils = Self("utils")
    public static let builds = Self("builds")
    public static let ci = Self("ci")
    public static let simulators = Self("simulators")
    public static let ai = Self("ai")
    public static let workItem = Self("workItem")
    public static let generateUI = Self("generateUI")
    public static let generateModule = Self("generateModule")
    public static let generateFeature = Self("generateFeature")
    public static let localization = Self("localization")
    public static let protocols = Self("protocols")
    public static let format = Self("format")
    public static let fullCleanup = Self("fullCleanup")
    public static let derivedDataCleanup = Self("derivedDataCleanup")
    public static let uiTests = Self("uiTests")
    public static let qualityGates = Self("qualityGates")
    public static let beta = Self("beta")
    private static let builtinNames = ["bootstrap", "utils", "builds", "ci", "simulators", "ai", "workItem", "generateUI", "generateModule", "generateFeature", "localization", "protocols", "format", "fullCleanup", "derivedDataCleanup", "uiTests", "qualityGates", "beta"]
    public static let allCases = builtinNames.map(Self.init)
    public var isCustom: Bool { rawValue.hasPrefix("profile:") }
    public var titleKey: String { "panel.block." + rawValue }
    public var role: ProfileToolRole? { ProfileToolRole(rawValue: rawValue) }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let aliases = (decoder.userInfo[ProfileCompatibility.codingKey] as? ProfileCompatibility)?.roles ?? [:]
        guard let value = Self(rawValue: aliases[raw] ?? ProfileCompatibility.legacyRoles[raw] ?? raw) else { throw PanelLayoutError.invalid }
        self = value
    }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var symbol: String {
        switch self {
        case .bootstrap: "shippingbox"
        case .utils: "wrench.and.screwdriver"
        case .builds: "hammer"
        case .ci, .uiTests, .qualityGates, .beta: "checkmark.seal"
        case .simulators: "iphone"
        case .ai: "sparkles"
        case .workItem: "doc.text"
        case .generateUI, .generateModule, .generateFeature: "square.stack.3d.up"
        case .localization: "character.bubble"
        case .protocols: "arrow.triangle.branch"
        case .format: "text.alignleft"
        case .fullCleanup, .derivedDataCleanup: "trash"
        default: "slider.horizontal.3"
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

/// One slot is full width; two slots are independent halves. A deliberate drop may pin either half.
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
        guard version == 1, revision >= 0, rows.count <= PanelBlockKind.allCases.count + 32,
              Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ (1...2).contains($0.slots.count) && !$0.blocks.isEmpty }),
              blocks.allSatisfy({ $0.isCustom || PanelBlockKind.catalog(for: surface).contains($0) }) else { throw PanelLayoutError.invalid }
        guard Set(blocks).count == blocks.count else { throw PanelLayoutError.duplicate }
    }

    // MARK: - Editing

    /// Fills vacancies with later mini blocks across full rows, without moving the pinned block.
    /// Apply after a complete edit: internal remove/resize steps must retain their destination rows.
    public mutating func compact(preserving block: PanelBlockKind? = nil) {
        let positions = rows.indices.filter { rows[$0].size == .mini }.flatMap { row in
            (0...1).map { (row: row, slot: $0) }
        }
        for (index, position) in positions.enumerated() where rows[position.row].slots[position.slot] == nil {
            guard let next = positions.dropFirst(index + 1).first(where: {
                let value = rows[$0.row].slots[$0.slot]
                return value != nil && value != block
            }) else { continue }
            rows[position.row].slots[position.slot] = rows[next.row].slots[next.slot]
            rows[next.row].slots[next.slot] = nil
        }
        rows.removeAll { $0.blocks.isEmpty }
    }

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

// MARK: - Drag transaction

/// A drag owns its original value, generated row identities and the last accepted preview.
/// Destinations from reflowed rows resolve through stable neighbours; persistence sees only the layout.
public struct PanelDragTransaction: Sendable {
    public let origin: PanelLayout
    public let block: PanelBlockKind
    public private(set) var preview: PanelLayout
    public private(set) var target: PanelInsertionTarget?
    public private(set) var valid = false
    private var size: PanelBlockSize?
    private var side: Int?
    private let rowIDs = PanelBlockKind.allCases.map { _ in UUID() }

    public init(origin: PanelLayout, block: PanelBlockKind) {
        self.origin = origin; self.block = block; preview = origin
    }

    /// Failed proposals invalidate feedback without discarding the last confirmed layout.
    @discardableResult public mutating func propose(_ destination: PanelInsertionTarget?, size: PanelBlockSize? = nil,
                                                   miniSlot: Int? = nil, surface: PanelSurface) -> Bool {
        guard let destination else { valid = false; return false }
        do {
            let resolved = try resolve(destination)
            let side = miniSlot ?? 0
            if resolved == target && self.size == size && self.side == side { valid = true; return true }
            var next = origin
            try next.insert(block, at: resolved, size: size, miniSlot: miniSlot, generatedRowIDs: rowIDs)
            next.compact(preserving: block)
            try next.validate(for: surface)
            if next.rows.map(\.slots) == origin.rows.map(\.slots) { next = origin }
            preview = next; target = resolved; self.size = size; self.side = side; valid = true
            return true
        } catch { valid = false; return false }
    }

    private func resolve(_ destination: PanelInsertionTarget) throws -> PanelInsertionTarget {
        let id: UUID?
        switch destination { case .slot(let row, _): id = row; case .boundary(let before): id = before }
        guard let id else { return destination }
        if origin.rows.contains(where: { $0.id == id }) { return destination }
        guard let row = preview.rows.first(where: { $0.id == id }) else { throw PanelLayoutError.missing }
        // A generated placeholder still refers to the insertion that created it, including a reverse resize.
        if row.blocks.contains(block), let target { return target }
        guard let neighbour = row.blocks.first(where: { $0 != block }),
              let original = origin.rows.first(where: { $0.blocks.contains(neighbour) }) else { throw PanelLayoutError.missing }
        switch destination {
        case .slot(_, let slot): return .slot(row: original.id, slot: slot)
        case .boundary: return .boundary(before: original.id)
        }
    }
}

// MARK: - Persistence

/// Compare-and-save prevents another chat's completed edit from being overwritten by an older draft.
@MainActor public final class PanelLayoutStore {
    let defaults: UserDefaults
    public var compatibility: ProfileCompatibility?
    public init(defaults: UserDefaults = .standard, compatibility: ProfileCompatibility? = nil) { self.defaults = defaults; self.compatibility = compatibility }
    private func key(_ surface: PanelSurface) -> String { "panelLayout." + surface.rawValue }
    public func load(_ surface: PanelSurface) -> PanelLayout {
        guard let data = defaults.data(forKey: key(surface)), let layout = try? ProfileCompatibility.decoder(compatibility).decode(PanelLayout.self, from: data),
              (try? layout.validate(for: surface)) != nil else { return .standard(for: surface) }
        return layout
    }
    /// Normalizes legacy vacancies once per surface. Later loads preserve deliberate right-half drops.
    /// The original value remains recoverable outside the wire layout; unchanged layouts do not gain a revision.
    public func prepareForPresentation(_ surface: PanelSurface) -> PanelLayout {
        let marker = key(surface) + ".compactionVersion"
        let original = load(surface)
        guard defaults.integer(forKey: marker) < 1 else { return original }
        var next = original; next.compact()
        do {
            if next != original {
                let backup = key(surface) + ".beforeCompaction"
                if defaults.data(forKey: backup) == nil { defaults.set(try JSONEncoder().encode(original), forKey: backup) }
                next = try save(next, for: surface, expectedRevision: original.revision)
            }
            defaults.set(1, forKey: marker)
            return next
        } catch { return load(surface) }
    }
    @discardableResult public func save(_ draft: PanelLayout, for surface: PanelSurface, expectedRevision: Int) throws -> PanelLayout {
        try draft.validate(for: surface)
        guard load(surface).revision == expectedRevision else { throw PanelLayoutError.conflict }
        var saved = draft; saved.revision = expectedRevision + 1
        defaults.set(try JSONEncoder().encode(saved), forKey: key(surface)); return saved
    }
}
