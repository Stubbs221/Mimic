// Created by Василий Маслов on 04.10.2026.
import AppKit
import SwiftTerm
import SwiftUI
import MimicCore

func buildTitle(_ record: BuildActivity) -> String { text("build.operation." + record.parameters.operation.rawValue) }
func buildDuration(_ record: BuildActivity) -> String { let seconds = Int(record.duration); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
func buildColor(_ record: BuildActivity) -> SwiftUI.Color { record.status == .failed || record.status == .unknown || record.status == .interrupted ? .orange : record.status == .succeeded ? .green : .secondary }

struct BuildToolRow: View {
    @ObservedObject var model: TaskCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.toggleSection(.builds) } label: {
                HStack { Image(systemName: "hammer").frame(width: 24); Text(text("build.title")).mimicFont(.heading).accessibilityAddTraits(.isHeader); Spacer(); Image(systemName: model.expandedSection == .builds ? "chevron.down" : "chevron.right").font(.system(size: 9)) }.contentShape(Rectangle())
            }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets(top: 10, leading: MimicMetrics.medium, bottom: 10, trailing: MimicMetrics.medium))).accessibilityIdentifier("build.toggle").accessibilityValue(disclosureValue(model.expandedSection == .builds))
            MimicCollapse(expanded: model.expandedSection == .builds, source: model.navigationSource) { BuildConfigurationView(model: model, builds: model.builds) }
        }.id(PanelSection.builds.scrollID)
    }
}

/// Explicit destinations and tests are edited in the same main panel as the existing tools.
struct BuildConfigurationView: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var builds: BuildCoordinator
    private var identifiers: Binding<String> { Binding(get: { builds.draft.testIdentifiers.joined(separator: "\n") }, set: { builds.draft.testIdentifiers = $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(text("build.backend"), selection: $builds.draft.backend) { Text(text("build.backend.cli")).tag(BuildBackend.cli); Text(text("build.backend.xcodeMCP")).tag(BuildBackend.xcodeMCP) }.accessibilityIdentifier("build.backend")
            Picker(text("build.operation"), selection: $builds.draft.operation) { ForEach(BuildOperation.allCases, id: \.self) { Text(text("build.operation." + $0.rawValue)).tag($0) } }
            if builds.draft.backend == .cli {
                Picker(text("build.scheme"), selection: $builds.draft.scheme) { Text(text("build.choose")).tag(""); ForEach(builds.catalogue.schemes, id: \.self) { Text($0).tag($0) } }.accessibilityIdentifier("build.scheme")
                Picker(text("build.configuration"), selection: $builds.draft.configuration) { Text(text("build.choose")).tag(""); ForEach(builds.catalogue.configurations, id: \.self) { Text($0).tag($0) } }
                Picker(text("build.destination"), selection: $builds.draft.destinationID) { Text(text("build.choose")).tag(""); ForEach(builds.catalogue.destinations) { Text($0.name).tag($0.id).help($0.id) } }.accessibilityIdentifier("build.destination")
                if builds.draft.operation == .test, !builds.catalogue.testPlans.isEmpty { Picker(text("build.testPlan"), selection: $builds.draft.testPlan) { Text(text("build.choose")).tag(""); ForEach(builds.catalogue.testPlans, id: \.self) { Text($0).tag($0) } } }
                HStack { Button(text("refresh")) { Task { if let project = model.project { await builds.refreshCatalogue(project: project) } } }.disabled(builds.loading); if builds.loading { ProgressView().controlSize(.small) } }
            } else {
                XcodeBuildConfiguration(builds: builds, project: model.project)
            }
            if builds.draft.operation == .test {
                Text(text("build.tests.hint")).font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: identifiers).font(.system(size: 11, design: .monospaced)).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary)).accessibilityLabel(text("build.tests")).accessibilityIdentifier("build.tests")
            }
            Text(text("build.preparation.hint")).font(.system(size: 11)).foregroundStyle(.secondary)
            if !builds.message.isEmpty {
                Text(builds.message).foregroundStyle(.orange).textSelection(.enabled)
                Button(text("build.bootstrap")) { model.openTool(.bootstrap) }
            }
            Text(builds.draft.backend == .cli ? builds.draft.scheme + " · " + builds.draft.configuration + "\n" + builds.draft.destinationID : builds.draft.workspaceTab + " · " + text("build.xcode.settings")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Button(text("build.start")) { builds.submitDraft() }.buttonStyle(MimicButtonStyle(primary: true)).disabled(model.project == nil || builds.loading || !valid).accessibilityIdentifier("build.start")
        }.padding(.leading, 32)
        .task(id: model.project.map { $0.path + $0.branch + $0.commit + ($0.developerDirectory ?? "") }) { if let project = model.project { await builds.restoreDraft(project: project); await builds.refreshCatalogue(project: project) } }
        .onChange(of: builds.draft) { _, _ in if let project = model.project { builds.saveDraft(project: project) } }
        .onChange(of: builds.draft.scheme) { _, scheme in if !scheme.isEmpty, let project = model.project { Task { await builds.refreshCatalogue(project: project, scheme: scheme) } } }
    }
    private var valid: Bool {
        var parameters = builds.draft
        if parameters.operation == .build { parameters.testIdentifiers = []; parameters.testPlan = "" }
        if parameters.backend == .xcodeMCP { parameters.scheme = ""; parameters.configuration = ""; parameters.destinationID = ""; parameters.testPlan = ""; return (try? parameters.validate()) != nil && builds.xcodeSimulatorConfirmed && builds.xcode.supports(parameters.operation) }
        return (try? parameters.validate()) != nil
    }
}

struct XcodeBuildConfiguration: View {
    @ObservedObject var builds: BuildCoordinator
    let project: ProjectContext?
    var body: some View { XcodeConnectionFields(connection: builds.xcode, builds: builds, project: project) }
}
struct XcodeConnectionFields: View {
    @ObservedObject var connection: XcodeBuildConnection
    @ObservedObject var builds: BuildCoordinator
    let project: ProjectContext?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(text("build.xcode.connect")) { Task { if let project { await connection.connect(project: project) } } }.disabled(connection.connecting || builds.hasPending || project == nil)
            if connection.connecting { ProgressView().controlSize(.small) }
            if !connection.message.isEmpty { Text(connection.message).foregroundStyle(.orange) }
            Picker(text("build.workspace"), selection: $builds.draft.workspaceTab) { Text(text("build.choose")).tag(""); ForEach(connection.windows.keys.sorted(), id: \.self) { tab in Text(tab + " · " + (connection.windows[tab] ?? "")).tag(tab) } }
            Text(text("build.xcode.settings")).font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle(text("build.xcode.simulator.confirm"), isOn: $builds.xcodeSimulatorConfirmed).font(.system(size: 11)).accessibilityIdentifier("build.xcode.simulator.confirm")
            if !connection.version.isEmpty { Text("Xcode MCP · " + connection.version).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

struct BuildHistoryRow: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var builds: BuildCoordinator
    let record: BuildActivity
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.toggleBuild(record.id) } label: {
                HStack(alignment: .top) {
                    Image(systemName: record.status == .succeeded ? "checkmark.circle" : "hammer").foregroundStyle(buildColor(record))
                    VStack(alignment: .leading, spacing: 4) { Text(buildTitle(record)).font(.system(size: 12, weight: .semibold)); Text(URL(fileURLWithPath: record.project.path).lastPathComponent + " · " + record.project.branch).lineLimit(2); Text(text("build.status." + record.status.rawValue)) }
                    Spacer(); Text(record.createdAt, style: .time); Image(systemName: builds.selectedID == record.id ? "chevron.down" : "chevron.right")
                }.font(.system(size: 11)).contentShape(Rectangle())
            }.buttonStyle(RowButtonStyle(contentInsets: EdgeInsets(top: 7, leading: MimicMetrics.medium, bottom: 7, trailing: MimicMetrics.medium))).accessibilityValue(disclosureValue(builds.selectedID == record.id)).accessibilityIdentifier("build.history." + record.id.uuidString)
            MimicCollapse(expanded: builds.selectedID == record.id, source: model.navigationSource) { BuildResultView(model: model, builds: builds, record: record) }
            Divider()
        }.id("build." + record.id.uuidString)
    }
}

struct BuildResultView: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var builds: BuildCoordinator
    let record: BuildActivity
    @State private var diagnostic = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(text("build.status." + record.status.rawValue)).foregroundStyle(buildColor(record)); Spacer(); MimicActivityClock(running: record.status == .running && record.startedAt != nil) { _ in Text(buildDuration(record)).monospacedDigit() } }
            Text(record.project.path + "\n" + record.project.branch + " · " + record.project.commit).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text(record.parameters.backend == .cli ? record.parameters.scheme + " · " + record.parameters.configuration + "\n" + record.parameters.destinationID : record.parameters.workspaceTab + " · " + text("build.xcode.settings")).font(.system(size: 11)).textSelection(.enabled)
            if !record.parameters.testIdentifiers.isEmpty { Text(record.parameters.testIdentifiers.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
            if let count = record.errorCount { Text(text("build.errors") + ": \(count)") }
            if let count = record.warningCount { Text(text("build.warnings") + ": \(count)") }
            if let error = record.errorCode { Text(text("build.error." + error)).foregroundStyle(.orange); Button(text("build.bootstrap")) { model.openTool(.bootstrap) } }
            if record.tracking != .live { Text(text("build.tracking." + record.tracking.rawValue)).foregroundStyle(.orange) }
            if record.truncated { Text(text("build.truncated")).font(.system(size: 11)).foregroundStyle(.orange) }
            BuildTerminalContainer(builds: builds, id: record.id).id(record.id).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 8)).mimicImmediate()
            if let log = builds.savedLogURL(record.id) { Button(text("log.open")) { NSWorkspace.shared.open(log) } }
            if let path = record.resultBundlePath { Button(text("build.testResult")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
            if let path = record.resultSummaryPath { Button(text("build.testResult")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
            ViewThatFits { HStack { actions }; VStack(alignment: .leading) { actions } }
            if !diagnostic.isEmpty { TextEditor(text: $diagnostic).frame(height: 180).font(.system(size: 11, design: .monospaced)).accessibilityLabel(text("build.diagnostic.preview")); Button(text("build.diagnostic.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostic, forType: .string) } }
        }.font(.system(size: 12)).accessibilityIdentifier("build.result")
    }
    @ViewBuilder private var actions: some View {
        if record.canCancel { Button(text("build.stop")) { builds.cancel(record.id) } }
        if record.parameters.backend == .xcodeMCP, record.status == .running { Text(text("build.stop.xcode")).font(.system(size: 11)).foregroundStyle(.secondary) }
        if record.diagnosticAvailable { Button(text("build.diagnostic.prepare")) { diagnostic = (try? builds.diagnostic(record.id)) ?? "" } }
        if record.status == .unknown, record.queueReleased != true { Button(text("build.unknown.acknowledge")) { builds.acknowledgeUnknown(record.id) }.help(text("build.unknown.help")) }
    }
}

/// Viewing the compiler output never forwards keystrokes or escape-sequence replies to the process.
struct BuildTerminalContainer: NSViewRepresentable {
    let builds: BuildCoordinator; let id: UUID
    func makeCoordinator() -> BuildTerminalDelegate { .init(builds: builds) }
    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero); terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = .textBackgroundColor; terminal.nativeForegroundColor = .textColor; terminal.backgroundOpacity = 1
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular); terminal.getTerminal().changeScrollback(10000)
        terminal.feed(byteArray: Array(builds.output(id))[...]); terminal.setAccessibilityLabel(text("build.output"))
        builds.attachTerminal(owner: context.coordinator.owner) { [weak terminal, id] operation, data in if operation == id { terminal?.feed(byteArray: Array(data)[...]) } }
        return terminal
    }
    func updateNSView(_ view: TerminalView, context: Context) { }
    static func dismantleNSView(_ view: TerminalView, coordinator: BuildTerminalDelegate) { view.terminalDelegate = nil; coordinator.builds.detachTerminal(owner: coordinator.owner) }
}
final class BuildTerminalDelegate: NSObject, TerminalViewDelegate {
    let builds: BuildCoordinator; let owner = UUID()
    init(builds: BuildCoordinator) { self.builds = builds }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { }
    func setTerminalTitle(source: TerminalView, title: String) { }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { }
    func scrolled(source: TerminalView, position: Double) { }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { }
    func clipboardCopy(source: TerminalView, content: Data) { }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { }
}
