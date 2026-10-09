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
    @Published private(set) var removing = false
    @Published private(set) var dragging: PanelBlockKind?
    @Published private(set) var dragPreview: PanelLayout?
    private var dragOrigin: PanelLayout?
    private var dragTarget: PanelInsertionTarget?
    private var dragSize: PanelBlockSize?
    private var dragMiniSlot: Int?
    @Published private(set) var dragCancellationID = 0
    @Published var message = ""
    let store: PanelLayoutStore
    var editing: Bool { draft != nil }
    var layout: PanelLayout { dragPreview ?? draft ?? saved }
    var availableBlocks: [PanelBlockKind] { PanelBlockKind.catalog(for: .desktop).filter { !saved.blocks.contains($0) } }
    init(defaults: UserDefaults) { store = PanelLayoutStore(defaults: defaults); saved = store.load(.desktop) }
    func begin() { cancelPresentation(); saved = store.load(.desktop); draft = saved; expanded = nil; message = "" }
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

    // MARK: - Direct tile management

    func toggleCatalog() {
        guard !editing, dragging == nil else { return }
        removing = false; catalogVisible.toggle(); message = ""
    }
    func toggleRemoval() {
        guard !editing, dragging == nil, !saved.blocks.isEmpty else { return }
        catalogVisible = false; removing.toggle(); expanded = nil; message = ""
    }
    /// Each explicit selection commits once against the visible revision; stale layouts never overwrite a newer save.
    @discardableResult func add(_ block: PanelBlockKind) -> Bool {
        guard !editing, dragging == nil, availableBlocks.contains(block) else { return false }
        guard commit({ try $0.add(block) }) else { return false }
        catalogVisible = false; removing = false
        return true
    }
    @discardableResult func remove(_ block: PanelBlockKind) -> Bool {
        guard removing, !editing, dragging == nil, saved.blocks.contains(block) else { return false }
        guard commit({ $0.remove(block) }) else { return false }
        if expanded == block { expanded = nil }
        removing = false
        return true
    }
    /// Escape consumes an in-panel interaction before the window dismisses.
    @discardableResult func cancelPresentation() -> Bool {
        let active = cancelDrag() || catalogVisible || removing
        catalogVisible = false; removing = false
        return active
    }
    private func commit(_ mutation: (inout PanelLayout) throws -> Void) -> Bool {
        var next = saved
        do {
            try mutation(&next)
            saved = try store.save(next, for: .desktop, expectedRevision: saved.revision)
            message = ""
            return true
        } catch {
            saved = store.load(.desktop)
            message = text(error as? PanelLayoutError == .conflict ? "panel.layout.drag.conflict" : "panel.layout.invalid")
            if saved.blocks.isEmpty { removing = false }
            return false
        }
    }
    // MARK: - Direct rearrangement

    func beginDrag(_ block: PanelBlockKind) {
        guard !removing, !catalogVisible, dragging == nil, layout.blocks.contains(block) else { return }
        dragOrigin = layout; dragPreview = layout; dragging = block; dragTarget = nil; dragSize = nil; dragMiniSlot = nil; message = ""
    }
    func previewDrag(at target: PanelInsertionTarget?, size: PanelBlockSize? = nil, miniSlot: Int? = nil) {
        guard dragOrigin != nil, let block = dragging, var next = dragPreview else { return }
        guard target != dragTarget || size != dragSize || miniSlot != dragMiniSlot else { return }
        dragTarget = target; dragSize = size; dragMiniSlot = miniSlot
        // Leaving the valid region keeps the confirmed preview; release there rolls back the transaction.
        guard let target else { return }
        do {
            try next.insert(block, at: target, size: size, miniSlot: miniSlot)
            try next.validate(for: .desktop)
            if let origin = dragOrigin, next.rows.map(\.slots) == origin.rows.map(\.slots) { next = origin }
            if next != dragPreview { dragPreview = next }
        } catch { dragTarget = nil }
    }
    /// A direct drop is one compare-and-save; editing drops remain inside the existing draft.
    func finishDrag() {
        guard let origin = dragOrigin, let next = dragPreview else { return }
        defer { cancelDrag() }
        guard dragTarget != nil, next.rows.map(\.slots) != origin.rows.map(\.slots) else { return }
        if editing { draft = next; return }
        do { saved = try store.save(next, for: .desktop, expectedRevision: origin.revision) }
        catch { saved = store.load(.desktop); message = text("panel.layout.drag.conflict") }
    }
    @discardableResult func cancelDrag() -> Bool {
        let active = dragging != nil
        if active { dragCancellationID += 1 }
        dragging = nil; dragOrigin = nil; dragPreview = nil; dragTarget = nil; dragSize = nil; dragMiniSlot = nil
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
    var singleColumn = false
    var dragging: PanelBlockKind? = nil
    var dragPosition: CGPoint = .zero
    var dragAnchor: UnitPoint = .topLeading
    var initialGrabOffset: CGPoint?
    var transientRow: UUID?
    var frameStore: PanelFrameStore?
    let gap: CGFloat = MimicMetrics.large
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? MimicMetrics.panelWidth - 2 * MimicMetrics.documentInset
        return CGSize(width: width, height: placements(width: width, subviews: subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = placements(width: bounds.width, subviews: subviews)
        frameStore?.record(Dictionary(uniqueKeysWithValues: cells.indices.map { (cells[$0].id, result.frames[$0]) }))
        for index in subviews.indices {
            let frame = result.frames[index]
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
                let itemWidth = full || singleColumn ? width : (width - gap) / 2
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
                frames[index] = CGRect(x: full || singleColumn ? 0 : CGFloat(cells[index].slot) * (itemWidth + gap), y: y, width: itemWidth, height: size.height)
                height = max(height, size.height)
                if singleColumn && !full { y += size.height + gap; height = 0 }
            }
            if !singleColumn || row.size == .full || expanded.map({ row.blocks.contains($0) }) == true { y += height + gap }
        }
        return (frames, max(0, y - gap))
    }
}

struct PanelGrid: View {
    private var theme = MimicTheme()
    @Environment(\.mimicTextScale) private var textScale
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var layout: PanelLayoutController
    // Geometry is an input cache. Observing its publisher here would feed layout back into body updates.
    @State private var frameStore: PanelFrameStore
    private var frames: [String: CGRect] { frameStore.logical }
    @State private var dragTarget: PanelInsertionTarget?
    @State private var lastHitPoint: CGPoint?
    @State private var dragValid = false
    @State private var activeZone: PanelDragResize.Zone?
    @State private var dragPosition: CGPoint = .zero
    @State private var grabOffset: CGPoint = .zero
    @State private var grabAnchor: UnitPoint = .topLeading
    @State private var initialGrabOffset: CGPoint?
    @State private var dragResize: PanelDragResize?
    @State private var dragMorph: PanelDragMorph?
    @State private var dragMorphPending = false
    @State private var dragMorphScale = CGSize(width: 1, height: 1)
    /// The same measured geometry drives drag hit testing and fixture verification of complete tiles.
    init(model: TaskCoordinator, layout: PanelLayoutController, frameStore: PanelFrameStore = PanelFrameStore()) {
        self.model = model; self.layout = layout; _frameStore = State(initialValue: frameStore)
    }
    private var visibleExpansion: PanelBlockKind? { layout.editing || layout.removing || layout.dragging != nil ? nil : layout.expanded }
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
            // A legacy layout draft can survive an appearance switch; retain its save/cancel controls.
            if !theme.tiled || layout.editing { toolbar.disabled(layout.dragging != nil) }
            if !layout.message.isEmpty { Text(layout.message).foregroundStyle(.orange) }
            if !theme.tiled, layout.catalogVisible { catalog }
            if layout.removing {
                HStack {
                    Text(text("panel.tiles.remove.hint")).mimicFont(.body)
                    Spacer(minLength: 0)
                    Button { layout.cancelPresentation() } label: { Text("Esc").mimicFont(.caption) }
                        .buttonStyle(.plain).help(text("panel.layout.cancel")).accessibilityLabel(text("panel.layout.cancel"))
                }.padding(12).background(theme.color("accentSoft"), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("panel.tiles.removing")
            }
            if theme.tiled, layout.layout.blocks.isEmpty {
                Surface {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text("panel.tiles.empty")).mimicFont(.heading)
                        Text(text("panel.tiles.empty.help")).mimicFont(.body).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("panel.tiles.empty")
            }
            PanelGridLayout(rows: rows, cells: cells, expanded: visibleExpansion, singleColumn: theme.tiled && textScale > 1.2, dragging: layout.dragging, dragPosition: dragPosition, dragAnchor: grabAnchor, initialGrabOffset: initialGrabOffset, transientRow: transientID, frameStore: frameStore) {
                ForEach(cells) { cell in
                    let hidden = (layout.dragging != nil && cell.row == transientID) || (rows.first(where: { $0.id == cell.row })?.blocks.contains(visibleExpansion ?? .bootstrap) == true && visibleExpansion != nil && cell.block != visibleExpansion)
                    Group {
                        if let block = cell.block { card(block, row: cell.row) }
                        else { emptySlot(cell) }
                    }.opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).disabled(hidden).accessibilityHidden(hidden)
                        .modifier(PanelCardFeedback(enabled: cell.block != nil && !hidden, lifted: layout.dragging == cell.block && cell.block != nil,
                                                    morphScale: dragMorphScale, grabAnchor: grabAnchor, radius: theme.cardRadius, policy: policy))
                        .transaction { if layout.dragging == cell.block && cell.block != nil { $0.animation = nil } }
                }
            }
            .overlay(alignment: .topLeading) { dragFeedback }
            .background(PanelDragBridge(
                cancellationID: layout.dragCancellationID, enabled: model.panelPage == .home && !layout.removing, candidate: dragCandidate, click: { block in open(block) },
                lift: lift, move: { point, pointer, time, visible in dragMoved(point, pointer, time, visible) }, end: { point, pointer, time in
                    dragMoved(point, pointer, time, true, advanceDwell: false)
                    withAnimation(policy.animation(.geometry)) { layout.finishDrag() }
                }, cancel: { withAnimation(policy.animation(.geometry)) { _ = layout.cancelDrag() } }
            ))
            .padding(.bottom, layout.editing || layout.dragging != nil ? 32 : 0)
            if model.expandedSection == .tasks {
                Surface {
                    HStack { Text(text("tasks")).mimicFont(.heading); Spacer(); Button(text("close")) { model.toggleSection(.tasks) } }
                    TaskHistoryContent(model: model)
                }.id(PanelSection.tasks.scrollID)
            }
        }.accessibilityIdentifier("panel.grid")
            .task(id: self.pollsSimulators) {
                if self.pollsSimulators { await model.pollSimulators() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if self.pollsSimulators { model.refreshSimulators() }
            }
            .onChange(of: layout.expanded) { _, block in
                if block == .simulators { model.refreshSimulators() }
            }
            .onExitCommand { if !layout.cancelPresentation() { if layout.editing { layout.cancel() } else { layout.expanded = nil } } }
            .onDisappear { layout.cancelPresentation() }
            .onChange(of: theme.appearance) { _, _ in layout.cancelPresentation() }
            .onChange(of: textScale) { _, _ in layout.cancelDrag() }
            .onChange(of: layout.dragging) { _, block in
                if block == nil { dragTarget = nil; lastHitPoint = nil; dragValid = false; activeZone = nil; initialGrabOffset = nil; dragResize = nil; dragMorph = nil; dragMorphPending = false; dragMorphScale = CGSize(width: 1, height: 1) }
            }
            .onReceive(frameStore.changes) { change in
                let old = change.old, next = change.next
                if let block = layout.dragging, let offset = initialGrabOffset, let frame = next[block.rawValue] {
                    grabAnchor = UnitPoint(x: min(1, max(0, offset.x / max(1, frame.width))), y: min(1, max(0, offset.y / max(1, frame.height))))
                    initialGrabOffset = nil
                }
                guard dragMorphPending, let block = layout.dragging, let from = old[block.rawValue], let to = next[block.rawValue], from.size != to.size else { return }
                dragMorphPending = false
                let now = ProcessInfo.processInfo.systemUptime
                let correction = dragMorph?.scale(at: now) ?? CGSize(width: 1, height: 1)
                dragMorph = PanelDragMorph(from: CGSize(width: from.width * correction.width, height: from.height * correction.height), to: to.size, started: now, duration: policy.duration(.geometry))
                dragMorphScale = dragMorph!.scale(at: now)
            }
            .onChange(of: model.expandedSection) { _, section in
                guard !layout.editing, !layout.removing, layout.dragging == nil else { return }
                if layout.expanded?.section == section { return }
                if let block = PanelBlockKind.section(section) { layout.expanded = block }
                else if section == .tasks || section == .branches { layout.expanded = nil }
            }
    }

    private var pollsSimulators: Bool {
        let visible = layout.layout.blocks.contains(.simulators) && !layout.editing && layout.dragging == nil &&
            !layout.layout.rows.contains { $0.blocks.contains(.simulators) && visibleExpansion != nil && visibleExpansion != .simulators && $0.blocks.contains(visibleExpansion!) }
        return model.shouldPollSimulators(blockVisible: visible)
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
                Button { model.toggleHistory() } label: { Label { Text(text("tasks")).frame(width: theme.tiled ? nil : 0).clipped() } icon: { Image(systemName: "clock.arrow.circlepath") } }.help(text("tasks"))
                Button { layout.begin() } label: { Label { Text(text("panel.layout.short")).frame(width: theme.tiled ? nil : 0).clipped() } icon: { Image(systemName: "slider.horizontal.3") } }.help(text("panel.layout.edit"))
            }
        }.mimicFont(.caption)
    }
    private var catalog: some View {
        Surface {
            ForEach(PanelBlockKind.catalog(for: .desktop), id: \.self) { block in
                Button { open(block) } label: { Label(text(block.titleKey), systemImage: block.symbol).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(RowButtonStyle()).accessibilityIdentifier("panel.catalog." + block.rawValue)
            }
        }
    }

    func card(_ block: PanelBlockKind, row: UUID) -> some View {
        let expanded = visibleExpansion == block
        let compactTools = block == .utils && !expanded && !layout.editing
        let compactSimulators = block == .simulators && !expanded && theme.tiled
        return VStack(alignment: .leading, spacing: 0) {
            // The retained zero-height catalog must not reserve a trailing gap below favorites.
            VStack(alignment: .leading, spacing: compactTools ? 0 : compactSimulators ? 8 : 6) {
                if block == .bootstrap, !layout.editing {
                    BootstrapCard(model: model, mode: expanded ? .expanded : layout.layout.size(of: block) == .full ? .full : .mini,
                                  header: AnyView(blockHeader(block, expanded: expanded)))
                } else {
                    if layout.editing { editHeader(block) }
                    else {
                        blockHeader(block, expanded: expanded).padding(.bottom, compactTools ? 6 : 0)
                        if !expanded, block == .builds {
                            BuildCardView(model: model, builds: model.builds, full: layout.layout.size(of: block) == .full)
                        } else if !expanded, block == .ci {
                            CICompactSummaryView(state: model.ci, full: layout.layout.size(of: block) == .full, open: { model.showCI($0) })
                        } else if !expanded, block == .ai {
                            AICompactProviders(usage: model.aiUsage, full: layout.layout.size(of: block) == .full, open: { open(.ai) })
                        } else if !expanded, block == .utils {
                            ToolsCompactView(model: model, preferences: model.toolsPreferences, full: layout.layout.size(of: block) == .full)
                        } else if !expanded, block == .simulators {
                            SimulatorCompactDevices(model: model, full: layout.layout.size(of: block) == .full, open: { open(.simulators) })
                        } else if !expanded { Text(summary(block)).mimicFont(.caption).foregroundStyle(.secondary).lineLimit(2).help(summary(block)) }
                    }
                }
                // Bootstrap owns its retained subtree; another hidden card would reserve spacing and reparent its screen.
                if block != .bootstrap {
                    // A single container prevents retained ForEach children from reserving collapsed row gaps.
                    MimicCollapse(expanded: expanded, source: layout.dragging == nil ? model.navigationSource : .keyboard, retainsContent: true) {
                        VStack(alignment: .leading, spacing: 8) { content(block) }
                            .environment(\.mimicPresentationVisible, expanded && !layout.editing && model.panelPage == .home && model.panelVisible)
                            // Hosted forms can expose only their container to AppKit hit testing.
                            // Keep their entire surface out of the card's click/hold recognizer.
                            .background(PanelControlRegion())
                    }.frame(minWidth: 0, maxWidth: .infinity)
                }
            }.frame(maxHeight: (block == .ci || block == .ai || block == .simulators || block == .utils) && !expanded && !layout.editing ? .infinity : nil, alignment: .topLeading)
                // Bootstrap marks only its controls and terminal so its text and free surface can disclose.
                // Other hosted forms retain their whole-surface control exclusion.
                .background { if block != .bootstrap || layout.editing { PanelControlRegion() } }
        }.padding(block == .bootstrap ? EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12) : compactSimulators ? SimulatorCompactLayout.tileInsets : MimicMetrics.cardInsets).frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            // Content changes never give one collapsed tile a different height from its neighbours.
            .frame(height: expanded ? nil : MimicMetrics.collapsedCardHeight * (theme.tiled ? max(1, textScale) : 1), alignment: .topLeading)
            .modifier(PanelCardBackground(block: block))
            .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
            .disabled(layout.removing).accessibilityHidden(layout.removing)
            .overlay {
                if layout.removing {
                    Button {
                        if layout.remove(block), model.expandedSection == block.section { model.expandedSection = nil }
                    } label: {
                        RoundedRectangle(cornerRadius: theme.cardRadius)
                            .fill(theme.color("accent").opacity(0.001))
                            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius).strokeBorder(theme.color("accent"), lineWidth: 1.5))
                            .contentShape(RoundedRectangle(cornerRadius: theme.cardRadius))
                    }.buttonStyle(.plain).accessibilityLabel(text("panel.layout.remove") + ": " + text(block.titleKey))
                        .accessibilityIdentifier("panel.remove." + block.rawValue)
                }
            }
            .environment(\.mimicInsideSurface, true)
            .modifier(PanelCardTooltip(message: text(layout.removing ? "panel.layout.remove" : "panel.layout.drag.hint"), preservesChildHelp: (block == .bootstrap || block == .builds) && !layout.removing))
            .id(block.scrollID).accessibilityIdentifier("panel.block." + block.rawValue)
    }
    private func blockHeader(_ block: PanelBlockKind, expanded: Bool) -> some View {
        Button { open(block) } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: block.symbol).foregroundStyle(theme.tiled || accessibility.increasedContrast ? Color.primary : PanelCardPalette.color(block))
                Text(text(block.titleKey))
                    .font(.system(size: (block == .simulators && !expanded && theme.tiled ? 14 : MimicTheme.metric("heading")) * (theme.tiled ? textScale : 1), weight: .semibold))
                    .lineLimit(2).help(text(block.titleKey))
                if block == .ci, let checkout = expanded ? model.ciPresentedState.context?.checkout : model.project?.path { CIProjectName(checkout: checkout) }
                Spacer(minLength: 0)

            }.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets(), showsHoverBackground: false))
            .background(PanelDragHeaderRegion()).accessibilityValue(disclosureValue(expanded))
    }
    private func editHeader(_ block: PanelBlockKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "line.3.horizontal").help(text("panel.layout.drag.hint"))
                    .background(PanelDragHeaderRegion())
                Text(text(block.titleKey)).mimicFont(.heading).lineLimit(2).help(text(block.titleKey))
                    .background(PanelDragHeaderRegion())
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
                    .background(PanelControlRegion())
            }
        }
    }
    private func emptySlot(_ cell: PanelGridCell) -> some View {
        Color.clear.frame(height: MimicMetrics.collapsedCardHeight * (theme.tiled ? max(1, textScale) : 1)).overlay {
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
              let block = cell.block, layout.layout.blocks.contains(block) else { return nil }
        return .init(block: block)
    }
    private func lift(_ block: PanelBlockKind, _ point: CGPoint, _ pointer: CGPoint, _ time: TimeInterval) {
        guard let frame = frames[block.rawValue] else { return }
        grabOffset = CGPoint(x: point.x - frame.minX, y: visibleExpansion == block ? min(point.y - frame.minY, 96) : point.y - frame.minY)
        if visibleExpansion == block && layout.layout.size(of: block) == .mini {
            grabOffset.x = min(grabOffset.x, (frame.width - 12) / 2)
        }
        dragPosition = point
        // Cards collapse to their actual design height; measurements replace this seed after layout.
        let width = frames.values.map(\.maxX).max() ?? 488
        let compactSize = CGSize(width: layout.layout.size(of: block) == .mini ? (width - MimicMetrics.large) / 2 : width, height: MimicMetrics.collapsedCardHeight)
        let anchorSize = visibleExpansion == block ? compactSize : frame.size
        grabAnchor = UnitPoint(x: min(1, max(0, grabOffset.x / max(1, anchorSize.width))), y: min(1, max(0, grabOffset.y / max(1, anchorSize.height))))
        initialGrabOffset = grabOffset
        dragResize = PanelDragResize(size: layout.layout.size(of: block) ?? .full, pointer: pointer)
        dragMorph = nil; dragMorphPending = false; dragMorphScale = CGSize(width: 1, height: 1)
        dragTarget = nil; lastHitPoint = nil
        layout.beginDrag(block)
        dragMoved(point, pointer, time, true)
    }
    private func dragMoved(_ point: CGPoint, _ pointer: CGPoint, _ time: TimeInterval, _ visible: Bool, advanceDwell: Bool = true) {
        guard let block = layout.dragging else { return }
        if dragPosition != point { dragPosition = point }
        let current = layout.layout
        let geometry = cells.compactMap { cell -> PanelDragGeometry.Cell? in
            guard cell.row != transientID, let frame = frames[cell.id], frame.width > 0 else { return nil }
            return .init(row: cell.row, slot: cell.slot, frame: frame, full: current.rows.first(where: { $0.id == cell.row })?.size == .full)
        }
        let width = geometry.map(\.frame.maxX).max() ?? 0
        let bottom = geometry.map(\.frame.maxY).max() ?? 0
        let valid = visible && point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= bottom + 32
        let zone = valid ? PanelDragResize.Zone.resolve(x: point.x, width: width) : nil
        activeZone = zone
        let resized = advanceDwell && dragResize?.update(zone: zone, pointer: pointer, time: time) == true
        if resized { dragMorphPending = true }
        if let dragMorph { dragMorphScale = dragMorph.scale(at: time) }
        if !valid {
            dragValid = false
            layout.previewDrag(at: nil, size: dragResize?.size)
        } else if lastHitPoint != point || resized || !dragValid {
            let target = PanelDragGeometry.retainedTarget(point: point, block: block, layout: current, cells: geometry,
                                                         current: dragTarget, size: dragResize?.size ?? .full, resized: resized)
            dragTarget = target; dragValid = target != nil
            withAnimation(policy.animation(.geometry)) { layout.previewDrag(at: target, size: dragResize?.size, miniSlot: zone?.slot) }
        }
        lastHitPoint = point
    }

    /// Indicators occupy an overlay, so progress and destination borders cannot change grid measurements.
    @ViewBuilder private var dragFeedback: some View {
        if let block = layout.dragging, let source = frames[block.rawValue] {
            let width = frames.values.map(\.maxX).max() ?? source.width
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<3) { index in
                        let zone: PanelDragResize.Zone = index == 0 ? .left : index == 1 ? .center : .right
                        Rectangle().fill(Color.accentColor.opacity(activeZone == zone ? 0.05 : 0))
                            .overlay(Rectangle().stroke(Color.accentColor.opacity(activeZone == zone ? 0.25 : 0)))
                            .frame(width: width * (index == 1 ? 0.4 : 0.3))
                    }
                }
                if dragValid {
                    RoundedRectangle(cornerRadius: theme.cardRadius).fill(Color.accentColor.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5])))
                        .frame(width: source.width, height: source.height).offset(x: source.minX, y: source.minY)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text((dragResize?.pending?.size ?? dragResize?.size) == .mini ? "panel.layout.drag.mini" : "panel.layout.drag.full"))
                            .mimicFont(.caption)
                        Rectangle().fill(Color.accentColor).frame(width: 100, height: 2)
                            .scaleEffect(x: dragResize?.progress ?? 0, anchor: .leading)
                    }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .offset(x: min(max(0, dragPosition.x + 16), max(0, width - 120)), y: max(0, dragPosition.y + 20))
                }
            }.allowsHitTesting(false).accessibilityHidden(true).zIndex(50)
        }
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
        if block == .utils { model.selectedProjectTool = nil }
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
            ToolsDetailView(model: model)
        case .builds: BuildConfigurationView(model: model, builds: model.builds)
        case .ci, .uiTests, .qualityGates, .beta:
            if let inspection = model.ciInspection, inspection.checkout != model.project?.path {
                HStack {
                    Text(URL(fileURLWithPath: inspection.checkout).lastPathComponent).mimicFont(.caption).help(inspection.checkout)
                    Spacer(minLength: 4)
                    Button(text("ci.compact.currentProject")) { model.clearCIInspection() }
                }
            }
            CISection(state: model.ciPresentedState, settings: model.ciSettings, launch: model.ciInspection == nil || model.ciInspection?.checkout == model.project?.path ? model.ciLaunch : nil, jenkins: model.jenkinsSettings, openSettings: { model.openSettings(group: .ci) }, showsHeader: false, presented: layout.expanded == block && !layout.editing && model.panelPage == .home && model.panelVisible, expanded: .constant(true))
        case .simulators: SimulatorCatalogContent(model: model)
        case .ai: AIUsageSection(model: model, usage: model.aiUsage, showsHeader: false)
        default:
            if let action = block.role?.localAction { ToolContent(model: model, action: action) }
        }
    }
}

// MARK: - Tile-local pointer feedback

/// Scroll-driven pointer crossings update one tile, without invalidating the grid or sibling content.
private struct PanelCardFeedback: ViewModifier {
    let enabled: Bool
    let lifted: Bool
    let morphScale: CGSize
    let grabAnchor: UnitPoint
    let radius: CGFloat
    let policy: MimicMotionPolicy
    @State private var hovered = false
    func body(content: Content) -> some View {
        let hovering = enabled && hovered
        content.background {
            ZStack {
                RoundedRectangle(cornerRadius: radius).fill(.black).shadow(color: .black.opacity(0.10), radius: 5, y: 3).opacity(hovering && !lifted ? 1 : 0)
                RoundedRectangle(cornerRadius: radius).fill(.black).shadow(color: .black.opacity(0.18), radius: 12, y: 10).opacity(lifted ? 1 : 0)
            }
        }
        .scaleEffect(x: lifted ? morphScale.width : 1, y: lifted ? morphScale.height : 1, anchor: grabAnchor)
        .scaleEffect(policy.moves ? lifted ? 1.04 : hovering ? 1.02 : 1 : 1, anchor: lifted ? grabAnchor : .center)
        .animation(policy.animation(.feedback), value: hovering)
        .animation(policy.animation(.feedback), value: lifted)
        .zIndex(lifted ? 100 : hovering ? 10 : 0)
        .onHover { inside in
            guard hovered != inside else { return }
            hovered = inside
            FramePerformanceTrace.event("Panel hover changed")
        }
    }
}

/// A card-wide tooltip must not replace Bootstrap's launch and Xcode explanations.
private struct PanelCardTooltip: ViewModifier {
    let message: String
    let preservesChildHelp: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if self.preservesChildHelp { content }
        else { content.help(self.message) }
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
