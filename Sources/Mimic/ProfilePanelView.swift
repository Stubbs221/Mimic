// Created by Василий Маслов on 16.10.2026.
import SwiftUI
import MimicCore

/// Surface-local drafts survive tile moves; the selected target is always captured before admission.
@MainActor final class ProfilePanelForm: ObservableObject {
    @Published var device = ""
    @Published var application = ""
    @Published var values: [String: String] = [:]
    @Published var result: ProfilePanelResult?
    @Published var busy = false
    @Published var message = ""
    @Published var conflict = false
    let panel: ProfilePanel
    unowned let model: TaskCoordinator
    private let project: ProjectContext
    private let snapshot: ProfileSnapshot
    private let defaults: UserDefaults
    private var baseline: [String: String] = [:]
    private var revision = ""
    private var storageKey: String { "customPanel.draft." + project.path + ":" + panel.block(profileID: snapshot.id).rawValue + ":" + device + ":" + application }
    private var selectionKey: String { "customPanel.target." + project.path + ":" + panel.id }
    var valid: Bool { !device.isEmpty && !application.isEmpty && panel.fields.allSatisfy { $0.accepts(values[$0.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)) } }
    var dirty: Bool { panel.fields.contains { values[$0.id, default: ""] != baseline[$0.id, default: ""] } }
    init(model: TaskCoordinator, panel: ProfilePanel, project: ProjectContext, snapshot: ProfileSnapshot, defaults: UserDefaults = .standard) {
        self.model = model; self.panel = panel; self.project = project; self.snapshot = snapshot; self.defaults = defaults
        let selection = defaults.stringArray(forKey: selectionKey) ?? []
        device = selection.first ?? ""; application = selection.count > 1 ? selection[1] : panel.applications[0].id
    }
    func saveDraft() { defaults.set(["values": values, "baseline": baseline, "revision": revision], forKey: storageKey) }
    func select() async {
        defaults.set([device, application], forKey: selectionKey)
        result = nil; revision = ""; baseline = [:]; conflict = false
        let saved = defaults.dictionary(forKey: storageKey) ?? [:]
        values = saved["values"] as? [String: String] ?? [:]
        baseline = saved["baseline"] as? [String: String] ?? [:]
        revision = saved["revision"] as? String ?? ""
        await run("read")
    }
    func start() async {
        await run("catalog")
        if device.isEmpty { device = result?.devices.first?.id ?? "" }
        if !device.isEmpty { await select() }
    }
    func refresh() async { if model.panelVisible && model.panelPage == .home && !busy && !device.isEmpty { await run("read") } }
    func run(_ operation: String, field: String = "", force: Bool = false) async {
        guard !busy, model.project == project, model.activeProfile == snapshot,
              operation == "catalog" || !device.isEmpty else { return }
        busy = true; defer { busy = false }
        let submitted = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let all = Dictionary(uniqueKeysWithValues: panel.fields.map { ($0.id, submitted[$0.id, default: ""]) })
        let parameters = ["operation": operation, "device": device, "application": application,
                          "values": String(decoding: (try? JSONEncoder().encode(operation == "apply" ? all : [:])) ?? Data("{}".utf8), as: UTF8.self),
                          "field": field, "expectedRevision": revision, "force": force ? "true" : "false"]
        let execution = ProfileExecution(snapshot: snapshot, actionID: panel.actionID, parameters: parameters)
        let id = UUID()
        let admitted: TaskRecord? = await withCheckedContinuation { continuation in
            model.requestProfile(execution: execution, expected: project, recordID: id, reveal: false) { continuation.resume(returning: $0) }
        }
        guard admitted != nil else { message = text("customPanel.failed"); return }
        while let record = model.records.first(where: { $0.id == id }), [.queued, .running].contains(record.status) {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        guard model.project == project, model.activeProfile == snapshot,
              let next = model.records.first(where: { $0.id == id })?.panelResult else { message = text("customPanel.failed"); return }
        result = next; message = text("customPanel." + next.status)
        if operation == "catalog" { return }
        if next.status == "conflict" || operation == "read" && !revision.isEmpty && revision != next.revision && dirty {
            conflict = true; return
        }
        guard ["ready", "shutdown", "saved", "launchFailed"].contains(next.status) else { return }
        let wasDirty = dirty
        baseline = next.values; revision = next.revision; conflict = false
        if operation == "apply" || operation == "resetAll" || operation == "read" && !wasDirty { values = next.values }
        if operation == "reset" { values[field] = "" }
        saveDraft()
    }
    func reload() async { values = [:]; baseline = [:]; revision = ""; conflict = false; await run("read") }
}

struct ProfilePanelView: View {
    @StateObject private var form: ProfilePanelForm
    let full: Bool
    private let live: Bool
    init(form: ProfilePanelForm, full: Bool, live: Bool = false) {
        _form = StateObject(wrappedValue: form); self.full = full; self.live = live
    }
    init(model: TaskCoordinator, panel: ProfilePanel, project: ProjectContext, snapshot: ProfileSnapshot, full: Bool) {
        _form = StateObject(wrappedValue: ProfilePanelForm(model: model, panel: panel, project: project, snapshot: snapshot))
        self.full = full; self.live = true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Picker(text("customPanel.device"), selection: $form.device) {
                    if form.device.isEmpty { Text(text("customPanel.device")).tag("") }
                    ForEach(form.result?.devices ?? []) { Text($0.title).tag($0.id) }
                }.labelsHidden().pickerStyle(.menu)
                    .mimicSelection(text("customPanel.device"), selection: $form.device, options: (form.result?.devices ?? []).map { .init($0.title, $0.id) }, labelsHidden: true).frame(maxWidth: .infinity)
                Picker(text("customPanel.application"), selection: $form.application) {
                    ForEach(form.panel.applications) { Text($0.title).tag($0.id) }
                }.labelsHidden().pickerStyle(.menu)
                    .mimicSelection(text("customPanel.application"), selection: $form.application, options: form.panel.applications.map { .init($0.title, $0.id) }, labelsHidden: true).frame(maxWidth: .infinity)
                Button { Task { await form.refresh() } } label: { Image(systemName: "arrow.clockwise") }.mimicHelp(text("refresh"))
            }.controlSize(.mini)
            ForEach(form.panel.fields) { field in
                HStack(spacing: 4) {
                    Text(field.title).lineLimit(1).frame(width: full ? 90 : 62, alignment: .leading).mimicHelp(field.title)
                    TextField(field.placeholder ?? text("customPanel.default"), text: Binding(get: { form.values[field.id, default: ""] }, set: { form.values[field.id] = $0; form.saveDraft() }))
                        .textFieldStyle(.roundedBorder).mimicInput().accessibilityLabel(field.title)
                        .onSubmit { if form.valid && !form.conflict { Task { await form.run("apply") } } }
                    Button { Task { await form.run("reset", field: field.id) } } label: { Image(systemName: "arrow.uturn.backward") }
                        .mimicHelp(text("customPanel.reset") + " " + field.title).disabled(form.result == nil || form.result?.revision.isEmpty != false)
                }.controlSize(.mini)
            }
            HStack(spacing: 5) {
                if form.conflict {
                    Button(text("customPanel.reload")) { Task { await form.reload() } }
                    Button(text("customPanel.overwrite")) { Task { await form.run("apply", force: true) } }.disabled(!form.valid)
                } else if form.result?.status == "launchFailed" {
                    Button(text("customPanel.retryLaunch")) { Task { await form.run("launch") } }
                } else {
                    Button(text("customPanel.apply")) { Task { await form.run("apply") } }.disabled(!form.valid || form.result?.revision.isEmpty != false)
                    Button(text("customPanel.resetAll")) { Task { await form.run("resetAll") } }.disabled(form.result?.revision.isEmpty != false)
                }
                Spacer(minLength: 0)
            }.buttonStyle(MimicAuxiliaryButtonStyle(height: 20, horizontalPadding: 6)).controlSize(.mini)
            Text(form.busy ? text("customPanel.working") : form.conflict ? text("customPanel.conflict") : form.message)
                .lineLimit(1).foregroundStyle(.secondary).mimicHelp(form.conflict ? text("customPanel.conflict") : form.message)
        }.mimicFont(.caption).disabled(form.busy).background(PanelControlRegion())
            .accessibilityIdentifier("customPanel." + form.panel.id)
            .task { guard live else { return }; await form.start(); while !Task.isCancelled { do { try await Task.sleep(for: .seconds(15)) } catch { break }; await form.refresh() } }
            .onChange(of: form.device) { old, value in if old != value && !form.busy { Task { await form.select() } } }
            .onChange(of: form.application) { old, value in if old != value && !form.busy { Task { await form.select() } } }
    }
}
