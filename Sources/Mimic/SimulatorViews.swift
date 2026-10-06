//
//  SimulatorViews.swift
//  Mimic
//
//  Created by Василий Маслов on 02.10.2026.
import SwiftUI
import MimicCore

/// The home panel follows one booted device. Powered-off devices live only in the catalogue.
struct RecentSimulatorsView: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: MimicMetrics.medium) {
            HStack {
                Text(text("tab.simulators")).font(MimicMetrics.heading).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(text(self.model.expandedSection == .simulators ? "panel.collapse" : "simulators.choose")) {
                    self.model.toggleSection(.simulators)
                }.buttonStyle(RowButtonStyle()).font(MimicMetrics.secondary)
                    .accessibilityValue(disclosureValue(self.model.expandedSection == .simulators)).accessibilityIdentifier("simulators.toggle")
            }.frame(minHeight: MimicMetrics.footerRow)
            MimicCollapse(expanded: self.model.expandedSection == .simulators, source: self.model.navigationSource) {
                SimulatorCatalogContent(model: self.model)
            }
            MimicCollapse(expanded: self.model.expandedSection != .simulators, source: self.model.navigationSource) {
            if self.model.loadingSimulators {
                HStack(spacing: MimicMetrics.medium) {
                    ProgressView().controlSize(.small)
                    Text(text("simulators.loading")).font(MimicMetrics.secondary).foregroundStyle(.secondary)
                }.frame(minHeight: 40)
            } else if !self.model.simulatorError.isEmpty {
                Text(self.model.simulatorError).font(MimicMetrics.secondary).foregroundStyle(.orange)
            } else if let device = self.model.selectedSimulator {
                SimulatorRow(model: self.model, device: device, compact: true)
            } else {
                Label(text("simulators.not.running"), systemImage: "iphone")
                    .font(MimicMetrics.secondary).foregroundStyle(.secondary).frame(minHeight: 40)
            }
            }
        }.accessibilityIdentifier("simulators.summary")
    }
}

struct SimulatorRow: View {
    @ObservedObject var model: TaskCoordinator
    let device: SimulatorDevice
    var compact = false
    var body: some View {
        HStack(spacing: MimicMetrics.medium) {
            Image(systemName: self.device.name.contains("iPad") ? "ipad" : "iphone")
                .foregroundStyle(.secondary).frame(width: 20).mimicStatus(self.device.name.contains("iPad")).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MimicMetrics.small) {
                Text(self.device.name).font(MimicMetrics.body.weight(.medium)).lineLimit(1).truncationMode(.middle).help(self.device.name).mimicStatus(self.device.name)
                HStack(spacing: MimicMetrics.small) {
                    if self.device.isBooted { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.green).accessibilityHidden(true) }
                    Text(self.device.runtime + " · " + text(self.device.isBooted ? "simulators.booted" : "simulators.off"))
                        .font(MimicMetrics.secondary).foregroundStyle(.secondary).lineLimit(1).mimicStatus(self.device.runtime + self.device.state)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if self.device.isBooted {
                Button(text("simulators.open")) { self.model.openSimulator(self.device) }
                    .buttonStyle(MimicButtonStyle()).disabled(self.model.switchingBranch || self.model.loadingSimulators)
                    .accessibilityIdentifier("simulator.open." + self.device.id.uuidString)
                if self.compact, self.model.bootedSimulators.count > 1 {
                    Menu {
                        ForEach(self.model.bootedSimulators) { candidate in
                            Button { self.model.selectSimulator(candidate) } label: {
                                if candidate.id == self.device.id { Label(candidate.name + " · " + candidate.runtime, systemImage: "checkmark") }
                                else { Text(candidate.name + " · " + candidate.runtime) }
                            }
                        }
                    } label: { Image(systemName: "chevron.up.chevron.down").frame(width: 24, height: 28) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).fixedSize().disabled(self.model.switchingBranch || self.model.loadingSimulators)
                        .help(text("simulators.switch")).accessibilityLabel(text("simulators.switch"))
                        .accessibilityIdentifier("simulators.switch")
                }
                Menu {
                    if !self.compact { Button(text("simulators.select")) { self.model.selectSimulator(self.device); self.model.toggleSection(.simulators) } }
                    Button(text("simulators.shutdown")) { self.model.request(.simulatorShutdown, simulator: self.device) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).fixedSize().disabled(self.model.switchingBranch || self.model.loadingSimulators)
                    .accessibilityLabel(text("simulators.actions"))
            } else {
                Button(text("simulators.boot")) { self.model.request(.simulatorBoot, simulator: self.device) }
                    .buttonStyle(MimicButtonStyle()).disabled(self.model.switchingBranch || self.model.readiness[.simulatorBoot] != [])
                    .accessibilityIdentifier("simulator.boot." + self.device.id.uuidString)
            }
        }.padding(.vertical, MimicMetrics.small).frame(minHeight: 44)
            .help(self.device.name + " · " + self.device.runtime + "\n" + self.device.id.uuidString)
            .accessibilityElement(children: .contain).accessibilityIdentifier("simulator.row." + self.device.id.uuidString)
    }
}
