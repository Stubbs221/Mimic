//
//  SimulatorViews.swift
//  Mimic
//
//  Created by Василий Маслов on 02.10.2026.
import SwiftUI
import MimicCore

struct RecentSimulatorsView: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(text("tab.simulators")) { self.model.toggleSection(.simulators) }
                .buttonStyle(.plain).mimicFont(.heading)
                .accessibilityValue(disclosureValue(self.model.expandedSection == .simulators))
            if self.model.expandedSection == .simulators { SimulatorCatalogContent(model: self.model) }
            else { SimulatorCompactDevices(model: self.model, full: false, open: { self.model.toggleSection(.simulators) }) }
        }.accessibilityIdentifier("simulators.summary")
    }
}

// MARK: - Compact summary

struct SimulatorCompactDevices: View {
    @ObservedObject var model: TaskCoordinator
    let full: Bool
    let open: () -> Void
    private var devices: [SimulatorDevice] { self.model.simulatorPresentation.compact(full: self.full) }
    var body: some View {
        Group {
            if self.devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text(self.model.simulatorStale ? "simulators.stale" : self.model.simulatorPanel.initialLoading ? "simulators.loading" : "simulators.compact.empty"))
                        .mimicFont(.caption).foregroundStyle(.secondary)
                    Button(text(self.model.simulatorStale ? "simulators.retry" : "simulators.choose")) {
                        if self.model.simulatorStale { self.model.refreshSimulators() } else { self.open() }
                    }.buttonStyle(RowButtonStyle()).background(PanelControlRegion())
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                SimulatorCompactLayout(columns: self.full ? 2 : 1) {
                    ForEach(self.devices) { device in
                        SimulatorDeviceCard(model: self.model, device: device, compact: true)
                    }
                }.frame(maxHeight: .infinity, alignment: .top)
            }
        }.transaction { $0.animation = nil }.accessibilityIdentifier("simulators.compact")
    }
}

/// Occupied slots share all available space; an odd final device spans the last row.
struct SimulatorCompactLayout: Layout {
    let columns: Int
    static let spacing: CGFloat = 8
    static let tileInsets = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 214, height: proposal.height ?? 102)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in self.frames(in: bounds, count: subviews.count).enumerated() {
            subviews[index].place(at: frame.origin, anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    func frames(in bounds: CGRect, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = min(max(1, self.columns), count)
        let rows = (count + columns - 1) / columns
        let width = max(0, (bounds.width - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
        let height = max(0, (bounds.height - CGFloat(rows - 1) * Self.spacing) / CGFloat(rows))
        return (0..<count).map { index in
            let spansRow = index == count - 1 && count % columns == 1
            return CGRect(x: bounds.minX + CGFloat(index % columns) * (width + Self.spacing),
                          y: bounds.minY + CGFloat(index / columns) * (height + Self.spacing),
                          width: spansRow ? bounds.width : width, height: height)
        }
    }
}

/// Feedback stays immediate and uses the same rounded boundary as the full activation target.
private struct SimulatorCompactButtonStyle: ButtonStyle {
    private var theme = MimicTheme()
    private var accessibility = MimicAccessibility()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10).fill(theme.tiled ? theme.color("paper") : Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 10).fill(theme.tiled ? theme.color("accentSoft") : Color.accentColor)
                    .opacity(enabled && (hovered || configuration.isPressed) ? configuration.isPressed ? 0.8 : theme.tiled ? 1 : 0.12 : 0)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((theme.tiled ? theme.color("accent") : Color.accentColor).opacity(focused ? 1 : accessibility.increasedContrast ? 0.5 : 0), lineWidth: focused ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { self.hovered = $0 }
    }
}

// MARK: - Shared device card

struct SimulatorDeviceCard: View {
    @ObservedObject var model: TaskCoordinator
    let device: SimulatorDevice
    var compact = false
    private var theme = MimicTheme()
    private var presentation: SimulatorPresentation { self.model.simulatorPresentation }
    private var pending: TaskRecord? { self.model.simulatorPendingRecord(self.device) }
    private var failure: SimulatorPanelFailure? { self.model.simulatorFailure(self.device) }
    private var busy: Bool { self.model.simulatorBusy(self.device) }
    private var status: String {
        if self.model.simulatorOpening[self.device.id] != nil { return text("simulators.opening") }
        if let pending {
            if pending.status == .queued { return text("simulators.queued") }
            return text(pending.action == .simulatorBoot ? "simulators.booting" : "simulators.shuttingDown")
        }
        if self.model.simulatorAdmissions[self.device.id] != nil { return text("simulators.preparing") }
        if self.device.isBooted { return text("simulators.booted") }
        if self.device.state == "Shutdown" { return text("simulators.off") }
        return self.device.state
    }
    private var statusColor: Color {
        if self.model.simulatorStale { return self.compact && self.theme.tiled ? self.theme.color("warning") : .orange }
        if self.busy { return self.compact && self.theme.tiled ? self.theme.color("accent") : .accentColor }
        if self.device.isBooted { return self.compact && self.theme.tiled ? self.theme.color("success") : .green }
        return self.compact && self.theme.tiled ? self.theme.color("muted") : .secondary.opacity(0.45)
    }
    private var description: String {
        [self.device.name, self.device.runtime, self.status, self.device.id.uuidString,
         self.model.simulatorStale ? text("simulators.stale") : "", self.failure?.message ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var detailLine: String { self.device.runtime + " · " + self.status }
    private var accessibleName: String { self.device.name + (self.presentation.shortID(self.device).map { " · " + $0 } ?? "") }
    private var accessibleValue: String { self.detailLine + (self.model.simulatorStale ? " · " + text("simulators.stale") : "") }

    var body: some View {
        Group {
            if self.compact {
                self.primaryButton
                    .overlay(alignment: .trailing) { self.accessories.padding(.trailing, 8) }
            } else {
                self.catalogCard
            }
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("simulator.card." + self.device.id.uuidString)
    }

    private var accessories: some View {
        HStack(spacing: 4) {
            if self.model.simulatorStale || self.failure != nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).mimicFont(.caption)
                    .help(self.failure?.message ?? text("simulators.stale"))
                    .accessibilityLabel(self.failure?.message ?? text("simulators.stale"))
                    .allowsHitTesting(false)
            }
            self.actions
        }
    }

    private var catalogCard: some View {
        HStack(spacing: 4) {
            self.primaryButton
            self.accessories
        }.padding(8).frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: SimulatorCatalogContent.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.025))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
    }

    private var primaryButton: some View {
        Group {
            if self.compact {
                Button { self.model.activateSimulator(self.device) } label: {
                    self.deviceLabel
                        .padding(.leading, 8)
                        .padding(.trailing, self.model.simulatorStale || self.failure != nil ? 48 : 32)
                        .padding(.vertical, 8)
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(SimulatorCompactButtonStyle())
            } else {
                Button { self.model.activateSimulator(self.device) } label: { self.deviceLabel }
                    .buttonStyle(.plain)
            }
        }.disabled(!self.model.canActivateSimulator(self.device))
            .frame(minWidth: 0, maxWidth: .infinity)
            .background(PanelControlRegion()).help(self.description)
            .accessibilityLabel(self.accessibleName).accessibilityValue(self.accessibleValue)
            .accessibilityHint(text(self.device.isBooted ? "simulators.open" : "simulators.boot"))
            .accessibilityIdentifier("simulator.activate." + self.device.id.uuidString)
    }

    private var deviceLabel: some View {
        HStack(spacing: self.compact ? 8 : 6) {
            if self.compact {
                Image(systemName: SimulatorPresentation.symbol(self.device))
                    .font(.system(size: 16))
                    .foregroundStyle(self.theme.tiled ? self.theme.color("accent") : Color.accentColor)
                    .frame(width: 26, height: 30)
                    .background(self.theme.color("accentSoft"), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: SimulatorPresentation.symbol(self.device))
                    .foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(self.device.name).mimicFont(.body, weight: self.compact ? .semibold : .medium)
                        .lineLimit(1).truncationMode(.middle)
                    if !self.compact, let identifier = self.presentation.shortID(self.device) {
                        Text(identifier).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    Circle().fill(self.statusColor).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(self.detailLine).lineLimit(1)
                    if self.compact, let identifier = self.presentation.shortID(self.device) {
                        Text("· " + identifier).fixedSize()
                    }
                }.mimicFont(.caption)
                    .foregroundStyle(self.compact && self.theme.tiled ? self.theme.color("muted") : Color.secondary)
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(self.compact && self.theme.tiled ? self.theme.color("ink") : Color.primary)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: self.compact ? nil : .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private var actions: some View {
        Menu {
            if self.model.simulatorStale {
                Button(text("simulators.retry")) { self.model.refreshSimulators() }.disabled(self.model.loadingSimulators)
            }
            if self.device.isBooted {
                Button(text("simulators.shutdown")) { self.model.requestSimulator(.simulatorShutdown, device: self.device) }
                    .disabled(!self.model.canActivateSimulator(self.device))
            }
            if self.presentation.isRecent(self.device) {
                Button(text("simulators.forget")) { self.model.forgetSimulator(self.device) }
            }
            if let id = self.failure?.taskID ?? self.pending?.id {
                Button(text("simulators.showTask")) { self.model.showHistory(id: id) }
            }
            if !self.device.isBooted, !self.presentation.isRecent(self.device), self.failure?.taskID == nil, self.pending == nil, !self.model.simulatorStale {
                Button(text("simulators.boot")) { self.model.activateSimulator(self.device) }
                    .disabled(!self.model.canActivateSimulator(self.device))
            }
        } label: { Image(systemName: "ellipsis").frame(width: 20, height: 28).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.primary)
            .frame(minHeight: self.compact ? 28 : nil).contentShape(Rectangle())
            .background(PanelControlRegion()).help(text("simulators.actions"))
            .accessibilityLabel(text("simulators.actions") + " · " + self.accessibleName)
            .accessibilityIdentifier("simulator.actions." + self.device.id.uuidString)
    }

}

// MARK: - Bounded catalogue

/// Only this fixed-size control observes background query activity; retained cards keep their snapshot.
private struct SimulatorRefreshButton: View {
    let model: TaskCoordinator
    var body: some View {
        Button { model.refreshSimulators() } label: { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
            .buttonStyle(.plain).disabled(model.loadingSimulators).help(text("refresh"))
            .accessibilityLabel(text("refresh")).accessibilityIdentifier("simulators.refresh")
    }
}

struct SimulatorCatalogContent: View {
    static let rowHeight: CGFloat = 64
    static let rowSpacing: CGFloat = 8
    @ObservedObject var model: TaskCoordinator
    private var page: SimulatorCatalogPage { self.model.simulatorCatalogPage }
    static func viewportHeight(count: Int) -> CGFloat {
        let rows = min(4, (count + 1) / 2)
        return CGFloat(rows) * self.rowHeight + CGFloat(max(0, rows - 1)) * self.rowSpacing
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(text("simulators.search"), text: self.$model.simulatorSearch).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("simulators.search")
                SimulatorRefreshButton(model: model)
            }
            Picker(text("simulators.filter"), selection: self.$model.simulatorFilter) {
                ForEach(SimulatorFilter.allCases, id: \.self) { filter in Text(filter.title).tag(filter) }
            }.pickerStyle(.segmented).accessibilityIdentifier("simulators.filter")
            if self.model.simulatorStale {
                HStack(spacing: 6) {
                    Label(text("simulators.stale"), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        .help(self.model.simulatorError)
                    Spacer(minLength: 0)
                    Button(text("simulators.retry")) { self.model.refreshSimulators() }.disabled(self.model.loadingSimulators)
                    Button(text("ready.open.settings")) { self.model.openSettings(group: .environment) }
                }.mimicFont(.caption)
            }
            if self.page.devices.isEmpty {
                if self.model.simulatorPanel.initialLoading {
                    HStack { ProgressView().controlSize(.small); Text(text("simulators.loading")) }.mimicFont(.caption)
                } else if !self.model.simulatorStale {
                    Text(text(!self.model.simulatorSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "simulators.search.empty" : self.model.simulators.isEmpty ? "simulators.empty" : "simulators.filter.empty"))
                        .mimicFont(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                        .accessibilityIdentifier("simulators.empty")
                }
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.flexible(minimum: 0), spacing: 8), GridItem(.flexible(minimum: 0), spacing: 8)], spacing: Self.rowSpacing) {
                        ForEach(self.page.devices) { device in SimulatorDeviceCard(model: self.model, device: device) }
                    }
                }.scrollIndicators(.automatic).frame(height: Self.viewportHeight(count: self.page.devices.count))
                    // A page starts at the top; polling within that page preserves the scroll view.
                    .id(self.page.index)
                    .accessibilityIdentifier("simulators.catalog.scroll")
                if self.page.count > 1 { self.pagination }
            }
        }.transaction { $0.animation = nil }.accessibilityIdentifier("simulators.catalog")
    }

    private var pagination: some View {
        HStack {
            Button { self.model.moveSimulatorPage(by: -1) } label: {
                Label(text("simulators.page.previous"), systemImage: "chevron.left")
                    .frame(width: 60)
            }.disabled(self.page.index == 0).accessibilityIdentifier("simulators.page.previous")
            Spacer(minLength: 8)
            Text(String(format: text("simulators.page.position"), self.page.index + 1, self.page.count))
                .foregroundStyle(.secondary).monospacedDigit()
                .accessibilityIdentifier("simulators.page.position")
            Spacer(minLength: 8)
            Button { self.model.moveSimulatorPage(by: 1) } label: {
                HStack(spacing: 4) { Text(text("simulators.page.next")); Image(systemName: "chevron.right") }
                    .frame(width: 60)
            }.disabled(self.page.index == self.page.count - 1).accessibilityIdentifier("simulators.page.next")
        }.buttonStyle(.bordered).controlSize(.small).mimicFont(.caption)
            .background(PanelControlRegion()).accessibilityIdentifier("simulators.pagination")
    }
}
