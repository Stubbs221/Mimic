// Created by Василий Маслов on 09.10.2026.
import SwiftUI
import MimicCore

/// All sizes own useful controls. Detail navigation is supplied by the card header, outside this control region.
struct BuildCardView: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var builds: BuildCoordinator
    var full = false
    var extended = false
    @State private var popup = ""
    @State private var action = "run"
    @State private var search = ""
    private var presented: Binding<Bool> { Binding(get: { !popup.isEmpty }, set: { if !$0 { popup = "" } }) }
    private var contextKey: String {
        let project = model.project.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return project + (model.activeProfile?.id ?? "") + (model.activeProfile?.revision ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: extended ? 12 : 4) {
            if extended {
                Picker(text("build.action"), selection: $action) {
                    Text(text("build.tab.build")).tag("build")
                    Text(text("build.tab.run")).tag("run")
                    Text(text("build.tab.tests")).tag("tests")
                }.pickerStyle(.segmented).accessibilityIdentifier("build.tabs")
                Text(text("build.purpose")).mimicFont(.caption).foregroundStyle(.secondary)
                settings
                if action == "tests" { testPicker }
                else { actionButton(action, primary: true) }
            } else if builds.panelActivity?.status.isPending != true {
                compactControls
                Spacer(minLength: 0)
            }
            if let record = builds.panelActivity {
                BuildInlineStatus(builds: builds, record: record, compact: !extended, chooseProduct: { popup = "products" })
                if extended, record.stage == .products, record.status.isPending, record.products?.count ?? 0 > 1 {
                    Button(text("build.chooseProduct")) { popup = "products" }.buttonStyle(MimicAuxiliaryButtonStyle())
                }
                if extended, !record.status.isPending { Button(text("build.output")) { builds.showResult(record.id) }.buttonStyle(MimicAuxiliaryButtonStyle()) }
            } else if !extended { Text(text(model.project == nil ? "build.project.required" : "build.purpose.compact")).mimicFont(.caption).foregroundStyle(.secondary).lineLimit(1).help(text("build.purpose")) }
            if !builds.message.isEmpty { Text(builds.message).mimicFont(.caption).foregroundStyle(.orange).lineLimit(extended ? nil : 1).help(builds.message) }
        }.frame(maxWidth: .infinity, maxHeight: extended ? nil : .infinity, alignment: .topLeading)
            .background(PanelControlRegion())
            .popover(isPresented: presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(text(popup == "tests" ? "build.tab.tests" : popup == "products" ? "build.chooseProduct" : "build.parameters.title")).mimicFont(.heading); Spacer(); Button(text("close")) { popup = "" }.buttonStyle(.plain) }
                    if popup == "tests" { settings; testPicker }
                    else if popup == "products" { products }
                    else { settings; if popup != "settings" { actionButton(action, primary: true) } }
                }.padding(16).frame(width: 400).fixedSize(horizontal: false, vertical: true)
            }
            .task(id: contextKey) { if let project = model.project { await builds.restoreDraft(project: project); await builds.refreshCatalogue(project: project) } }
            .onChange(of: builds.draft) { _, _ in if let project = model.project { builds.saveDraft(project: project) } }
            .onChange(of: builds.draft.scheme) { _, value in if let project = model.project { Task { await builds.refreshCatalogue(project: project, scheme: value) } } }
            .onChange(of: builds.panelActivity?.stage) { _, stage in if stage == .products, builds.panelActivity?.products?.count ?? 0 > 1 { popup = "products" } }
            .onChange(of: builds.panelActivity?.products) { _, value in if builds.panelActivity?.stage == .products, value?.count ?? 0 > 1 { popup = "products" } }
            .onChange(of: contextKey) { _, _ in popup = ""; search = "" }
            .onChange(of: builds.panelActivity?.status) { _, value in if popup == "products", value?.isPending != true { popup = "" } }
            .onChange(of: popup) { _, value in if value == "tests", let project = model.project { Task { await builds.refreshCatalogue(project: project, includeTestPlans: true) } } }
            .onChange(of: action) { _, value in if value == "tests", let project = model.project { Task { await builds.refreshCatalogue(project: project, includeTestPlans: true) } } }
            .accessibilityIdentifier(extended ? "build.extended" : full ? "build.full" : "build.mini")
    }

    // MARK: - Equal-height compact controls

    /// Full uses width for its selectors; running work replaces launch controls in both sizes.
    @ViewBuilder private var compactControls: some View {
        if full {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    selections.labelsHidden()
                    Button(text("build.moreSettings")) { popup = "settings" }.buttonStyle(.plain).mimicFont(.caption).lineLimit(1)
                }.frame(maxWidth: .infinity)
                compactActions.frame(maxWidth: .infinity)
            }
        } else {
            Button { popup = "settings" } label: {
                Text(parametersSummary).mimicFont(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).help(parametersSummary).accessibilityIdentifier("build.parameters")
            compactActions
        }
    }
    private var compactActions: some View {
        VStack(spacing: 4) {
            actionButton("run", primary: true)
            HStack(spacing: 8) { actionButton("build"); actionButton("tests") }
        }
    }
    private var parametersSummary: String { (builds.draft.scheme.isEmpty ? text("build.chooseScheme") : builds.draft.scheme) + " · " + destination }
    private var destination: String { builds.catalogue.destinations.first { $0.id == builds.draft.destinationID }?.name ?? text("build.chooseDevice") }
    private func actionButton(_ value: String, primary: Bool = false) -> some View {
        Button {
            action = value
            if value == "tests" { popup = "tests" }
            else if !builds.draftCompatible || value == "run" && builds.draft.backend != .cli { popup = "execute" }
            else { builds.perform(intent: value == "run" ? .run : nil); popup = "" }
        } label: { Text(text("build.action." + value)).multilineTextAlignment(.center).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true) }
            .buttonStyle(MimicAuxiliaryButtonStyle(primary: primary, height: extended ? 32 : 28, horizontalPadding: extended ? 12 : 8)).disabled(builds.panelBusy || model.project == nil)
            .accessibilityIdentifier("build.action." + value)
    }
    private var selections: some View {
        VStack(alignment: .leading, spacing: extended || !full ? 8 : 4) {
            Picker(text("build.scheme"), selection: parameter(\.scheme)) { Text(text("build.chooseScheme")).tag(""); ForEach(builds.catalogue.schemes, id: \.self) { Text($0).tag($0) } }
                .accessibilityIdentifier("build.scheme")
            Picker(text("build.destination"), selection: parameter(\.destinationID)) { Text(text("build.chooseDevice")).tag(""); ForEach(builds.catalogue.destinations) { Text($0.name).tag($0.id) } }
                .accessibilityIdentifier("build.destination")
        }.disabled(builds.panelBusy || builds.loading)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            selections
            if builds.loading { ProgressView(text("build.loadingSettings")).controlSize(.small) }
            if !builds.draftCompatible { Text(text("build.settings.required")).mimicFont(.caption).foregroundStyle(.secondary) }
            Button(text("build.refreshSettings")) { Task { if let project = model.project { await builds.refreshCatalogue(project: project) } } }.disabled(builds.loading || builds.panelBusy)
            DisclosureGroup(text("build.moreSettings")) {
                Picker(text("build.backend"), selection: $builds.draft.backend) { ForEach(BuildBackend.allCases, id: \.self) { Text(text("build.backend." + $0.rawValue)).tag($0) } }
                Picker(text("build.configuration"), selection: parameter(\.configuration)) { ForEach(builds.catalogue.configurations, id: \.self) { Text($0).tag($0) } }
                if builds.draft.backend == .xcodeMCP { XcodeBuildConfiguration(builds: builds, project: model.project); Text(text("build.run.cliRequired")).mimicFont(.caption) }
                if !builds.catalogue.testPlans.isEmpty { Picker(text("build.testPlan"), selection: parameter(\.testPlan)) { Text(text("build.choose")).tag(""); ForEach(builds.catalogue.testPlans, id: \.self) { Text($0).tag($0) } } }
            }.disabled(builds.panelBusy)
        }
    }
    private var testPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text("build.catalogue.explanation")).mimicFont(.caption).foregroundStyle(.secondary)
            Button(text("build.catalogue.load")) { builds.perform(intent: .catalogue) }.disabled(builds.panelBusy || !builds.testsCompatible || builds.draft.backend != .cli).accessibilityIdentifier("build.catalogue.load")
            if builds.catalogue.testPlans.count > 1, builds.draft.testPlan.isEmpty { Text(text("build.tests.choosePlan")).mimicFont(.caption).foregroundStyle(.secondary) }
            if builds.draft.backend != .cli { Text(text("build.run.cliRequired")).mimicFont(.caption).foregroundStyle(.secondary) }
            TextField(text("build.tests.search"), text: $search).textFieldStyle(.roundedBorder).accessibilityIdentifier("build.tests.search")
            if let catalogue = builds.availableTests {
                let filtered = catalogue.tests.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(Set(filtered.map { $0.target + "/" + $0.className })).sorted(), id: \.self) { group in
                            Text(group).mimicFont(.body, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                            ForEach(filtered.filter { $0.target + "/" + $0.className == group }) { test in
                                Toggle(test.name, isOn: Binding(get: { builds.draft.testIdentifiers.contains(test.id) }, set: { selected in
                                    if selected { if builds.draft.testIdentifiers.count < 100 { builds.draft.testIdentifiers.append(test.id) } }
                                    else { builds.draft.testIdentifiers.removeAll { $0 == test.id } }
                                })).toggleStyle(.checkbox).help(test.id).disabled(builds.panelBusy)
                            }
                        }
                        if filtered.isEmpty { Text(text(catalogue.tests.isEmpty ? "build.tests.empty" : "build.tests.noMatches")).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
            } else { Text(text("build.tests.notLoaded")).mimicFont(.caption).foregroundStyle(.secondary) }
            Text(text("build.tests.selected") + ": \(builds.draft.testIdentifiers.count) / 100").mimicFont(.caption)
            DisclosureGroup(text("build.tests.manual")) {
                TextEditor(text: Binding(get: { builds.draft.testIdentifiers.joined(separator: "\n") }, set: { builds.draft.testIdentifiers = Array(Set($0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted() })).frame(height: 70)
            }.disabled(builds.panelBusy)
            Button(text("build.action.testsSelected")) { builds.perform(.test); popup = "" }
                .buttonStyle(MimicAuxiliaryButtonStyle(primary: true)).disabled(builds.panelBusy || !builds.testsCompatible || (try? builds.draftFor(.test).validate()) == nil)
                .accessibilityIdentifier("build.tests.start")
        }
    }
    private var products: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("build.product.explanation")).mimicFont(.caption)
            if let record = builds.panelActivity {
                ForEach(record.products ?? []) { product in
                    Button(product.name) { try? builds.chooseProduct(product.id, activityID: record.id); popup = "" }.help(product.bundleIdentifier)
                }
                Button(text("build.stop")) { builds.cancel(record.id); popup = "" }
            }
        }
    }
    private func parameter(_ keyPath: WritableKeyPath<BuildParameters, String>) -> Binding<String> {
        Binding(get: { builds.draft[keyPath: keyPath] }, set: { value in
            if builds.draft[keyPath: keyPath] != value { builds.draft.testIdentifiers = [] }
            builds.draft[keyPath: keyPath] = value
        })
    }
}

struct BuildInlineStatus: View {
    @ObservedObject var builds: BuildCoordinator
    let record: BuildActivity
    var compact = false
    var chooseProduct: (() -> Void)?
    private var identity: String { text(record.actionKey) + " · " + record.parameters.scheme + " · " + buildInitiator(record) }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if record.status.isPending { Text(identity).mimicFont(.caption).lineLimit(compact ? 2 : nil).truncationMode(.middle).help(identity) }
            HStack(alignment: .firstTextBaseline) {
                Text(text(record.phase)).foregroundStyle(buildColor(record)).lineLimit(compact ? 1 : nil).help(record.errorCode.map { text("build.error." + $0) } ?? text(record.phase))
                Spacer(minLength: 8)
                MimicActivityClock(running: record.status.isPending) { _ in Text(buildDuration(record)).monospacedDigit() }
            }.mimicFont(.caption)
            BuildProgressView(record: record)
            if let completed = record.completedStages, record.parameters.intent == .run, !compact || record.status.isPending { Text(String(format: text("build.progress.stages"), completed, record.progressTotal)).mimicFont(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : nil) }
            if let completed = record.completedTestCount, let total = record.selectedTestCount, !compact || record.status.isPending { Text(String(format: text("build.progress.tests"), completed, total)).mimicFont(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : nil) }
            if !compact, let error = record.errorCode { Text(text("build.error." + error)).mimicFont(.caption).foregroundStyle(.orange) }
            if record.canCancel || compact && record.stage == .products && record.status.isPending && record.products?.count ?? 0 > 1 {
                HStack(spacing: 8) {
                    if compact, record.stage == .products, record.status.isPending, record.products?.count ?? 0 > 1 {
                        Button(text("build.chooseProduct")) { chooseProduct?() }.buttonStyle(MimicAuxiliaryButtonStyle(height: 28, horizontalPadding: 8))
                    }
                    if record.canCancel { Button(text("build.stop")) { builds.cancel(record.id) }.buttonStyle(MimicAuxiliaryButtonStyle(height: compact ? 28 : 32)).accessibilityIdentifier("build.cancel") }
                }
            }
        }.accessibilityElement(children: .contain)
    }
}

struct BuildProgressView: View {
    let record: BuildActivity
    var body: some View {
        Group {
            if let value = record.progressFraction { MimicProgressBar(value: value, color: buildColor(record), label: text("build.progress")) }
            else if record.status.isPending { ProgressView().progressViewStyle(.linear).tint(.accentColor).frame(height: 6).accessibilityLabel(text("build.progress.active")) }
            else { MimicProgressBar(value: 0, color: buildColor(record), label: text("build.progress")) }
        }.accessibilityIdentifier("build.progress")
    }
}
