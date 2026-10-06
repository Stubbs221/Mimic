//
//  PanelGrid.swift
//  Mimic
//
//  Created by Василий Маслов on 06.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Editing is an isolated value transaction; expanding a card never modifies the persisted slots.
@MainActor final class PanelLayoutController: ObservableObject {
    @Published private(set) var saved: PanelLayout
    @Published private(set) var draft: PanelLayout?
    @Published var expanded: PanelBlockKind?
    @Published var catalogVisible = false
    @Published private(set) var dragging: PanelBlockKind?
    @Published private(set) var dragPreview: PanelLayout?
    private var dragOrigin: PanelLayout?
    private var dragTarget: PanelInsertionTarget?
    private var dragSize: PanelBlockSize?
    private var dragMiniSlot: Int?
    private var dragRowIDs: [UUID] = []
    @Published private(set) var dragCancellationID = 0
    @Published var message = ""
    let store: PanelLayoutStore
    var editing: Bool { draft != nil }
    var layout: PanelLayout { dragPreview ?? draft ?? saved }
    var dragLayoutOrigin: PanelLayout { dragOrigin ?? layout }
    init(defaults: UserDefaults) { store = PanelLayoutStore(defaults: defaults); saved = store.load(.desktop) }
    func begin() { saved = store.load(.desktop); draft = saved; expanded = nil; message = "" }
    func cancel() { cancelDrag(); draft = nil; message = "" }
    func finish() {
        guard let draft else { return }
        do { saved = try store.save(draft, for: .desktop, expectedRevision: saved.revision); cancel() }
        catch { message = text("panel.layout.conflict") }
    }
    func edit(_ mutation: (inout PanelLayout) throws -> Void) {
        guard var next = draft else { return }
        do { try mutation(&next); try next.validate(for: .desktop); draft = next; message = "" }
        catch { message = text("panel.layout.invalid") }
    }
    // MARK: - Direct rearrangement

    func beginDrag(_ block: PanelBlockKind) {
        guard dragging == nil, layout.blocks.contains(block) else { return }
        dragOrigin = layout; dragPreview = layout; dragging = block; dragTarget = nil; dragSize = nil; dragMiniSlot = nil; dragRowIDs = (0..<3).map { _ in UUID() }; message = ""
    }
    func previewDrag(at target: PanelInsertionTarget?, size: PanelBlockSize? = nil, miniSlot: Int? = nil) {
        guard let origin = dragOrigin, let block = dragging else { return }
        guard target != dragTarget || size != dragSize || miniSlot != dragMiniSlot else { return }
        dragTarget = target; dragSize = size; dragMiniSlot = miniSlot
        guard let target else {
            var next = origin
            if let size, let row = origin.rows.first(where: { $0.blocks.contains(block) }) {
                try? next.insert(block, at: .boundary(before: row.id), size: size, miniSlot: miniSlot, generatedRowIDs: dragRowIDs)
            }
            dragPreview = next
            return
        }
        var next = origin
        do { try next.insert(block, at: target, size: size, miniSlot: miniSlot, generatedRowIDs: dragRowIDs); try next.validate(for: .desktop); dragPreview = next }
        catch { dragTarget = nil; dragPreview = origin }
    }
    /// A direct drop is one compare-and-save; editing drops remain inside the existing draft.
    func finishDrag() {
        guard let origin = dragOrigin, let next = dragPreview else { return }
        defer { cancelDrag() }
        guard dragTarget != nil, next.rows != origin.rows else { return }
        if editing { draft = next; return }
        do { saved = try store.save(next, for: .desktop, expectedRevision: origin.revision) }
        catch { saved = store.load(.desktop); message = text("panel.layout.drag.conflict") }
    }
    @discardableResult func cancelDrag() -> Bool {
        let active = dragging != nil
        if active { dragCancellationID += 1 }
        dragging = nil; dragOrigin = nil; dragPreview = nil; dragTarget = nil; dragSize = nil; dragMiniSlot = nil; dragRowIDs = []
        return active
    }
    func open(_ block: PanelBlockKind) { expanded = expanded == block ? nil : block; catalogVisible = false }
    func reset() { edit { $0.rows = PanelLayout.standard(for: .desktop).rows } }
}

struct PanelGridCell: Identifiable {
    let row: UUID
    let slot: Int
    let block: PanelBlockKind?
    var id: String { block?.rawValue ?? "empty.\(row).\(slot)" }
}

/// One flat ForEach retains a block's SwiftUI identity when it moves into a different row or half.
struct PanelGridLayout: Layout {
    let rows: [PanelLayoutRow]
    let cells: [PanelGridCell]
    let expanded: PanelBlockKind?
    var dragging: PanelBlockKind? = nil
    var dragPosition: CGPoint = .zero
    var dragAnchor: UnitPoint = .topLeading
    var initialGrabOffset: CGPoint?
    var transientRow: UUID?
    let gap: CGFloat = MimicMetrics.large
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? MimicMetrics.panelWidth - 2 * MimicMetrics.documentInset
        return CGSize(width: width, height: placements(width: width, subviews: subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = placements(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let frame = result.frames[index]
            subviews[index][PanelFrameSink.self]?(frame)
            let lifted = cells[index].block == dragging && dragging != nil
            let offset = lifted ? initialGrabOffset : nil
            let position = lifted ? CGPoint(x: dragPosition.x - (offset?.x ?? 0), y: dragPosition.y - (offset?.y ?? 0)) : frame.origin
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), anchor: lifted && offset == nil ? dragAnchor : .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
    private func placements(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        var frames = Array(repeating: CGRect.zero, count: subviews.count), y: CGFloat = 0
        for row in rows {
            if dragging != nil && row.id == transientRow { continue }
            let indices = cells.indices.filter { cells[$0].row == row.id }
            var height: CGFloat = 0
            for index in indices {
                // An expanded card owns its row; invisible siblings must not set its height.
                if let expanded, row.blocks.contains(expanded), cells[index].block != expanded { continue }
                let full = row.size == .full || cells[index].block == expanded
                let itemWidth = full ? width : (width - gap) / 2
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
                frames[index] = CGRect(x: full ? 0 : CGFloat(cells[index].slot) * (itemWidth + gap), y: y, width: itemWidth, height: size.height)
                height = max(height, size.height)
            }
            y += height + gap
        }
        return (frames, max(0, y - gap))
    }
}

struct PanelGrid: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var layout: PanelLayoutController
    @State private var frames: [String: CGRect] = [:]
    @State private var targets: [PanelDragGeometry.Cell] = []
    @State private var dragPosition: CGPoint = .zero
    @State private var grabOffset: CGPoint = .zero
    @State private var grabAnchor: UnitPoint = .topLeading
    @State private var initialGrabOffset: CGPoint?
    @State private var dragResize: PanelDragResize?
    @State private var dragMorph: PanelDragMorph?
    @State private var dragMorphPending = false
    @State private var dragMorphScale = CGSize(width: 1, height: 1)
    @State private var hovered: PanelBlockKind?
    private var visibleExpansion: PanelBlockKind? { layout.editing || layout.dragging != nil ? nil : layout.expanded }
    private var policy: MimicMotionPolicy { MimicMotionPolicy(source: .pointer, reduceMotion: model.motionSettings.nativeReduceMotion, multiplier: model.motionSettings.multiplier) }
    private var accessibility = MimicAccessibility()
    private var rows: [PanelLayoutRow] {
        var rows = layout.layout.rows
        if let block = layout.expanded, !layout.layout.blocks.contains(block) { rows.insert(PanelLayoutRow(id: transientID, slots: [block]), at: 0) }
        return rows
    }
    @State private var transientID = UUID()
    private var cells: [PanelGridCell] {
        rows.flatMap { row in row.slots.enumerated().map { PanelGridCell(row: row.id, slot: $0.offset, block: $0.element) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.large) {
            toolbar.disabled(layout.dragging != nil)
            if !layout.message.isEmpty { Text(layout.message).foregroundStyle(.orange) }
            if layout.catalogVisible { catalog }
            PanelGridLayout(rows: rows, cells: cells, expanded: visibleExpansion, dragging: layout.dragging, dragPosition: dragPosition, dragAnchor: grabAnchor, initialGrabOffset: initialGrabOffset, transientRow: transientID) {
                ForEach(cells) { cell in
                    let hidden = (layout.dragging != nil && cell.row == transientID) || (rows.first(where: { $0.id == cell.row })?.blocks.contains(visibleExpansion ?? .bootstrap) == true && visibleExpansion != nil && cell.block != visibleExpansion)
                    let measuredDuringDrag = cell.block != nil && layout.dragging == cell.block
                    Group {
                        if let block = cell.block { card(block, row: cell.row) }
                        else { emptySlot(cell) }
                    }.opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).disabled(hidden).accessibilityHidden(hidden)
                        .layoutValue(key: PanelFrameSink.self, value: { frame in
                            Task { @MainActor in
                                // Resolve the anchor from the first measured collapsed card, not an expanded frame.
                                if measuredDuringDrag, layout.dragging == cell.block, let offset = initialGrabOffset {
                                    grabAnchor = UnitPoint(x: min(1, max(0, offset.x / max(1, frame.width))), y: min(1, max(0, offset.y / max(1, frame.height))))
                                    initialGrabOffset = nil
                                }
                                if frames[cell.id] != frame { frames[cell.id] = frame }
                            }
                        })
                        .zIndex(layout.dragging == cell.block && cell.block != nil ? 100 : hovered == cell.block && cell.block != nil ? 10 : 0)
                        .transaction { if layout.dragging == cell.block && cell.block != nil { $0.animation = nil } }
                }
            }
            .background(PanelDragBridge(
                cancellationID: layout.dragCancellationID, enabled: model.panelPage == .home, candidate: dragCandidate, click: { block in open(block) },
                lift: lift, move: dragMoved, end: { point, pointer, time in
                    dragMoved(point, pointer, time, true)
                    withAnimation(policy.animation(.geometry)) { layout.finishDrag() }
                }, cancel: { withAnimation(policy.animation(.geometry)) { _ = layout.cancelDrag() } }
            ))
            .padding(.bottom, layout.editing || layout.dragging != nil ? 32 : 0)
            if model.expandedSection == .tasks {
                Surface {
                    HStack { Text(text("tasks")).font(MimicMetrics.heading); Spacer(); Button(text("close")) { model.toggleSection(.tasks) } }
                    TaskHistoryContent(model: model)
                }.id(PanelSection.tasks.scrollID)
            }
        }.accessibilityIdentifier("panel.grid")
            .onExitCommand { if !layout.cancelDrag() { if layout.editing { layout.cancel() } else { layout.expanded = nil } } }
            .onDisappear { layout.cancelDrag() }
            .onChange(of: layout.dragging) { _, block in
                if block == nil { initialGrabOffset = nil; dragResize = nil; dragMorph = nil; dragMorphPending = false; dragMorphScale = CGSize(width: 1, height: 1) }
            }
            .onChange(of: frames) { old, next in
                guard dragMorphPending, let block = layout.dragging, let from = old[block.rawValue], let to = next[block.rawValue], from.size != to.size else { return }
                dragMorphPending = false
                let now = ProcessInfo.processInfo.systemUptime
                let correction = dragMorph?.scale(at: now) ?? CGSize(width: 1, height: 1)
                dragMorph = PanelDragMorph(from: CGSize(width: from.width * correction.width, height: from.height * correction.height), to: to.size, started: now, duration: policy.duration(.geometry))
                dragMorphScale = dragMorph!.scale(at: now)
            }
            .onChange(of: model.expandedSection) { _, section in
                guard !layout.editing, layout.dragging == nil else { return }
                if layout.expanded?.section == section { return }
                if let block = PanelBlockKind.section(section) { layout.expanded = block }
                else if section == .tasks || section == .branches { layout.expanded = nil }
            }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if layout.editing {
                Menu(text("panel.layout.add")) {
                    ForEach(PanelBlockKind.catalog(for: .desktop).filter { !layout.layout.blocks.contains($0) }, id: \.self) { block in
                        Button(text(block.titleKey)) { layout.edit { try $0.add(block) } }
                    }
                }
                Button(text("panel.layout.done")) { layout.finish() }.keyboardShortcut(.return, modifiers: .command)
                Button(text("panel.layout.cancel")) { layout.cancel() }
                Button(text("panel.layout.reset")) { layout.reset() }
            } else {
                Button(text("panel.new.action")) { layout.catalogVisible.toggle() }
                Spacer(minLength: 0)
                Button { model.toggleHistory() } label: { Image(systemName: "clock.arrow.circlepath") }.help(text("tasks"))
                Button { layout.begin() } label: { Image(systemName: "slider.horizontal.3") }.help(text("panel.layout.edit"))
            }
        }.font(MimicMetrics.secondary)
    }
    private var catalog: some View {
        Surface {
            ForEach(PanelBlockKind.catalog(for: .desktop), id: \.self) { block in
                Button { open(block) } label: { Label(text(block.titleKey), systemImage: block.symbol).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(RowButtonStyle()).accessibilityIdentifier("panel.catalog." + block.rawValue)
            }
        }
    }

    private func card(_ block: PanelBlockKind, row: UUID) -> some View {
        let expanded = visibleExpansion == block
        let lifted = layout.dragging == block
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if block == .bootstrap, !layout.editing {
                    BootstrapCard(model: model, mode: expanded ? .expanded : layout.layout.size(of: block) == .full ? .full : .mini,
                                  header: AnyView(blockHeader(block, expanded: expanded)))
                } else {
                    if layout.editing { editHeader(block) }
                    else {
                        blockHeader(block, expanded: expanded)
                        if !expanded, block == .ci {
                            if let summary = model.ci.compactSummary { CICompactBody(summary: summary) }
                            else { Text(text("ci.compact.empty")).font(MimicMetrics.secondary).foregroundStyle(.secondary) }
                        } else if !expanded { Text(summary(block)).font(MimicMetrics.secondary).foregroundStyle(.secondary).lineLimit(2).help(summary(block)) }
                    }
                }
                // A single container prevents retained ForEach children from reserving collapsed row gaps.
                MimicCollapse(expanded: expanded && block != .bootstrap, source: layout.dragging == nil ? model.navigationSource : .keyboard, retainsContent: true) {
                    VStack(alignment: .leading, spacing: 8) { content(block) }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: expanded ? nil : MimicMetrics.collapsedCardHeight, alignment: .topLeading)
            .modifier(PanelCardBackground(block: block))
            .overlay(alignment: .bottom) {
                if block == .ci, !expanded, !layout.editing, let summary = model.ci.compactSummary { CICompactProgress(summary: summary).allowsHitTesting(false) }
            }.clipShape(RoundedRectangle(cornerRadius: 14))
            .environment(\.mimicInsideSurface, true)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(.black).shadow(color: .black.opacity(0.10), radius: 5, y: 3).opacity(hovered == block && !lifted ? 1 : 0)
                    RoundedRectangle(cornerRadius: 14).fill(.black).shadow(color: .black.opacity(0.18), radius: 12, y: 10).opacity(lifted ? 1 : 0)
                }
            }
            .scaleEffect(x: lifted ? dragMorphScale.width : 1, y: lifted ? dragMorphScale.height : 1, anchor: grabAnchor)
            .scaleEffect(policy.moves ? lifted ? 1.04 : hovered == block ? 1.02 : 1 : 1, anchor: lifted ? grabAnchor : .center)
            .animation(policy.animation(.feedback), value: hovered == block)
            .animation(policy.animation(.feedback), value: lifted)
            .onHover { inside in hovered = inside ? block : hovered == block ? nil : hovered }
            .help(text("panel.layout.drag.hint"))
            .id(block.scrollID).accessibilityIdentifier("panel.block." + block.rawValue)
    }
    private func blockHeader(_ block: PanelBlockKind, expanded: Bool) -> some View {
        Button { open(block) } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: block.symbol).foregroundStyle(accessibility.increasedContrast ? Color.primary : PanelCardPalette.color(block))
                Text(text(block.titleKey)).font(MimicMetrics.heading).lineLimit(2).help(text(block.titleKey))
                Spacer(minLength: 0)
                if block == .ci, !expanded, let summary = model.ci.compactSummary {
                    CIStatusBadge(status: summary.status).lineLimit(1).help(text("ci.status." + summary.status))
                }
            }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets())).accessibilityValue(disclosureValue(expanded))
    }
    private func editHeader(_ block: PanelBlockKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "line.3.horizontal").help(text("panel.layout.drag.hint"))
                Text(text(block.titleKey)).font(MimicMetrics.heading).lineLimit(2).help(text(block.titleKey))
                Spacer(minLength: 0)
                Menu {
                    Button(text("panel.layout.full")) { layout.edit { try $0.resize(block, to: .full) } }
                    Button(text("panel.layout.mini")) { layout.edit { try $0.resize(block, to: .mini) } }
                    Button(text("panel.layout.up")) { move(block, direction: -1) }
                    Button(text("panel.layout.down")) { move(block, direction: 1) }
                    Menu(text("panel.layout.replace")) {
                        ForEach(PanelBlockKind.catalog(for: .desktop).filter { !layout.layout.blocks.contains($0) }, id: \.self) { replacement in
                            Button(text(replacement.titleKey)) { layout.edit { try $0.replace(block, with: replacement) } }
                        }
                    }
                    Menu(text("panel.layout.join")) {
                        ForEach(layout.layout.rows.filter { $0.slots.count == 2 && $0.slots.contains(nil) }) { row in
                            Button(row.blocks.map { text($0.titleKey) }.joined(separator: " · ")) {
                                layout.edit { try $0.resize(block, to: .mini); try $0.move(block, to: row.id, slot: row.slots.firstIndex(of: nil) ?? 1) }
                            }.disabled(row.blocks.contains(block))
                        }
                    }
                    Button(text("panel.layout.remove")) { layout.edit { $0.remove(block) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
        }
    }
    private func emptySlot(_ cell: PanelGridCell) -> some View {
        Color.clear.frame(height: MimicMetrics.collapsedCardHeight).overlay {
            if layout.editing {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4]))
                Menu {
                    ForEach(PanelBlockKind.catalog(for: .desktop).filter { !layout.layout.blocks.contains($0) }, id: \.self) { block in
                        Button(text(block.titleKey)) { layout.edit { try $0.add(block, size: .mini); try $0.move(block, to: cell.row, slot: cell.slot) } }
                    }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help(text("panel.layout.add"))
            }
        }
    }
    // MARK: - Gesture geometry

    private func dragCandidate(_ point: CGPoint) -> PanelDragBridge.Candidate? {
        guard model.panelPage == .home, let cell = cells.first(where: { cell in
            guard let block = cell.block, frames[cell.id]?.contains(point) == true else { return false }
            return visibleExpansion == nil || visibleExpansion == block || rows.first(where: { $0.id == cell.row })?.blocks.contains(visibleExpansion!) != true
        }),
              let block = cell.block, layout.layout.blocks.contains(block),
              let frame = frames[cell.id] else { return nil }
        let header = point.y < frame.minY + 48 && (!layout.editing || point.x < frame.maxX - 40)
        return .init(block: block, header: header)
    }
    private func lift(_ block: PanelBlockKind, _ point: CGPoint, _ pointer: CGPoint, _ time: TimeInterval) {
        guard let frame = frames[block.rawValue] else { return }
        grabOffset = CGPoint(x: point.x - frame.minX, y: visibleExpansion == block ? min(point.y - frame.minY, 96) : point.y - frame.minY)
        if visibleExpansion == block && layout.layout.size(of: block) == .mini {
            grabOffset.x = min(grabOffset.x, (frame.width - 12) / 2)
        }
        dragPosition = point
        let rowHeights = layout.layout.rows.reduce(into: [UUID: CGFloat]()) { heights, row in
            guard !row.blocks.contains(visibleExpansion ?? .bootstrap) || visibleExpansion == nil else { return }
            heights[row.id] = row.blocks.compactMap { frames[$0.rawValue]?.height }.max()
        }
        targets = PanelDragGeometry.compactCells(layout: layout.layout, width: frames.values.map(\.maxX).max() ?? 488, rowHeights: rowHeights)
        let source = layout.layout.rows.first { $0.blocks.contains(block) }
        let compact = targets.first { $0.row == source?.id && $0.slot == source?.slots.firstIndex(of: block) }?.frame ?? frame
        let anchorSize = visibleExpansion == block ? compact.size : frame.size
        grabAnchor = UnitPoint(x: min(1, max(0, grabOffset.x / max(1, anchorSize.width))), y: min(1, max(0, grabOffset.y / max(1, anchorSize.height))))
        initialGrabOffset = grabOffset
        dragResize = PanelDragResize(size: layout.layout.size(of: block) ?? .full, pointer: pointer)
        dragMorph = nil; dragMorphPending = false; dragMorphScale = CGSize(width: 1, height: 1)
        layout.beginDrag(block)
    }
    private func dragMoved(_ point: CGPoint, _ pointer: CGPoint, _ time: TimeInterval, _ visible: Bool) {
        guard let block = layout.dragging else { return }
        dragPosition = point
        let width = targets.map(\.frame.maxX).max() ?? 0
        let initialTarget = PanelDragGeometry.target(point: point, block: block, layout: layout.dragLayoutOrigin, cells: targets, size: dragResize?.size)
        let zone = !visible || initialTarget == nil ? nil : PanelDragResize.Zone.resolve(x: point.x, width: width)
        if dragResize?.update(zone: zone, pointer: pointer, time: time) == true { dragMorphPending = true }
        let target = PanelDragGeometry.target(point: point, block: block, layout: layout.dragLayoutOrigin, cells: targets, size: dragResize?.size)
        if let dragMorph { dragMorphScale = dragMorph.scale(at: time) }
        withAnimation(policy.animation(.geometry)) { layout.previewDrag(at: target, size: dragResize?.size, miniSlot: zone?.slot) }
    }
    private func move(_ block: PanelBlockKind, direction: Int) {
        guard let index = layout.layout.rows.firstIndex(where: { $0.blocks.contains(block) }) else { return }
        let target = direction < 0 ? index - 1 : index + 2
        guard target >= 0 else { return }
        let row = layout.layout.rows.indices.contains(target) ? layout.layout.rows[target].id : nil
        layout.edit { try $0.move(block, before: row) }
    }
    private func open(_ block: PanelBlockKind) {
        guard !layout.editing, layout.dragging == nil else { return }
        let policy = MimicMotionPolicy(source: .current, reduceMotion: model.motionSettings.nativeReduceMotion, multiplier: model.motionSettings.multiplier)
        withAnimation(policy.moves ? policy.animation(.disclosure) : nil) { layout.open(block) }
        if block == .ci { model.clearCIInspection() }
        if let section = block.section { model.expandedSection = layout.expanded == nil ? nil : section }
        if let generator = block.role?.generator { model.generatorKind = generator }
        if let kind = block.remoteKind, layout.expanded != nil { model.ciLaunch.open(kind) }
    }
    private func summary(_ block: PanelBlockKind) -> String {
        switch block {
        case .bootstrap: model.bootstrapRecord.map { text("status." + $0.status.rawValue) } ?? text("panel.ready")
        case .builds: model.builds.records.last.map { text("build.status." + $0.status.rawValue) } ?? text("panel.ready")
        case .ai: model.aiUsage.percentage
        case .simulators: model.simulators.first(where: \.isBooted)?.name ?? text("simulators.not.running")
        default: text("panel.open.tool")
        }
    }
    @ViewBuilder private func content(_ block: PanelBlockKind) -> some View {
        switch block {
        case .bootstrap: EmptyView()
        case .utils:
            ForEach([MimicAction.generation, .localization, .proto, .format, .fullCleanup, .derivedDataCleanup], id: \.self) { ToolRow(model: model, action: $0) }
        case .builds: BuildConfigurationView(model: model, builds: model.builds)
        case .ci, .uiTests, .qualityGates, .beta:
            if let inspection = model.ciInspection, inspection.checkout != model.project?.path {
                HStack {
                    Text(URL(fileURLWithPath: inspection.checkout).lastPathComponent).font(MimicMetrics.secondary).help(inspection.checkout)
                    Spacer(minLength: 4)
                    Button(text("ci.compact.currentProject")) { model.clearCIInspection() }
                }
            }
            CISection(state: model.ciPresentedState, settings: model.ciSettings, launch: model.ciInspection == nil || model.ciInspection?.checkout == model.project?.path ? model.ciLaunch : nil, jenkins: model.jenkinsSettings, openSettings: { model.openSettings(group: .ci) }, showsHeader: false, presented: layout.expanded == block && !layout.editing, expanded: .constant(true))
        case .simulators: SimulatorCatalogContent(model: model)
        case .ai: AIUsageSection(model: model, usage: model.aiUsage, showsHeader: false)
        default:
            if let action = block.role?.localAction { ToolContent(model: model, action: action) }
        }
    }
}

extension PanelBlockKind {
    var section: PanelSection? {
        switch self {
        case .bootstrap: nil
        case .utils: .tool(.generation)
        case .builds: .builds
        case .ci, .uiTests, .qualityGates, .beta: .ci
        case .simulators: .simulators
        case .ai: .usage
        default: role?.localAction.map(PanelSection.tool)
        }
    }
    var remoteKind: RemoteCIKind? { switch self { case .uiTests: .uiTests; case .qualityGates: .qualityGates; case .beta: .beta; default: nil } }
    var scrollID: String { self == .bootstrap ? "section.bootstrap" : section?.scrollID ?? "panel.block." + rawValue }
    static func section(_ section: PanelSection?) -> Self? {
        switch section {
        case .builds: .builds
        case .ci: .ci
        case .simulators: .simulators
        case .usage: .ai
        case .tool(let action):
            switch action { case .generation: .utils; case .localization: .localization; case .proto: .protocols; case .format: .format; case .fullCleanup: .fullCleanup; case .derivedDataCleanup: .derivedDataCleanup; default: nil }
        default: nil
        }
    }
}
