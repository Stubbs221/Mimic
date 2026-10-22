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
    private var operationTask: Task<Void, Never>?
    private var storageKey: String { "customPanel.draft." + project.path + ":" + panel.block(profileID: snapshot.id).rawValue + ":" + device + ":" + application }
    private var selectionKey: String { "customPanel.target." + project.path + ":" + panel.id }
    var valid: Bool { !device.isEmpty && !application.isEmpty && panel.fields.allSatisfy { $0.accepts(values[$0.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)) } }
    var hasReadRevision: Bool { !revision.isEmpty }
    var dirty: Bool { panel.fields.contains { values[$0.id, default: ""] != baseline[$0.id, default: ""] } }
    init(model: TaskCoordinator, panel: ProfilePanel, project: ProjectContext, snapshot: ProfileSnapshot, defaults: UserDefaults = .standard) {
        self.model = model
        // Layout registration updates asynchronously after an import; the snapshot owns current labels and fields.
        self.panel = snapshot.profile.panels?.first(where: { $0.id == panel.id }) ?? panel
        self.project = project; self.snapshot = snapshot; self.defaults = defaults
        let selection = defaults.stringArray(forKey: selectionKey) ?? []
        device = selection.first ?? ""; application = self.panel.applications[0].id
        restoreDraft()
    }
    private func restoreDraft() {
        let saved = defaults.dictionary(forKey: storageKey) ?? [:]
        values = saved["values"] as? [String: String] ?? [:]
        baseline = saved["baseline"] as? [String: String] ?? [:]
        revision = saved["profileRevision"] as? String == snapshot.revision ? saved["revision"] as? String ?? "" : ""
    }
    func saveDraft() { defaults.set(["values": values, "baseline": baseline, "revision": revision, "profileRevision": snapshot.revision], forKey: storageKey) }
    func select() async {
        guard !busy else { return }
        defaults.set([device, application], forKey: selectionKey)
        result = nil; revision = ""; baseline = [:]; conflict = false
        restoreDraft()
        model.serviceSettingsChanges.send()
        await run("read")
    }
    func start() async {
        await run("catalog")
        if device.isEmpty { device = result?.devices.first?.id ?? "" }
        if !device.isEmpty { await select() }
    }
    func refresh() async {
        guard model.panelVisible, model.panelPage == .home, !busy else { return }
        if result == nil || device.isEmpty { await start() } else { await run("read", discardDraft: conflict) }
    }
    /// The form owns observation independently of the SwiftUI task which displayed it.
    func run(_ operation: String, field: String = "", force: Bool = false, discardDraft: Bool = false) async {
        guard !busy, model.project == project, model.activeProfile == snapshot,
              operation == "catalog" || !device.isEmpty else { return }
        busy = true
        let task = Task { await self.execute(operation, field: field, force: force, discardDraft: discardDraft) }
        operationTask = task
        await task.value
    }

    private func execute(_ operation: String, field: String, force: Bool, discardDraft: Bool) async {
        defer { busy = false; operationTask = nil }
        let target = [device, application]
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
        guard model.project == project, model.activeProfile == snapshot, target == [device, application],
              let record = model.records.first(where: { $0.id == id }), record.status == .succeeded,
              let next = record.panelResult else { message = text("customPanel.failed"); return }
        result = next; message = text("customPanel." + next.status)
        if operation == "catalog" { return }
        if next.status == "conflict" || operation == "read" && !discardDraft && !revision.isEmpty && revision != next.revision && dirty {
            conflict = true; return
        }
        guard ["ready", "shutdown", "saved", "launchFailed"].contains(next.status) else { return }
        let wasDirty = dirty
        baseline = next.values; revision = next.revision; conflict = false
        if operation == "apply" || operation == "resetAll" || operation == "read" && (discardDraft || !wasDirty) { values = next.values }
        if operation == "reset" { values[field] = "" }
        saveDraft()
        model.serviceSettingsChanges.send()
    }
    func reload() async { await run("read", discardDraft: true) }
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
            ForEach(form.panel.fields) { field in
                HStack(spacing: 4) {
                    Text(field.title).lineLimit(1).frame(width: full ? 90 : 62, alignment: .leading).mimicHelp(field.title)
                    TextField(field.placeholder ?? text("customPanel.default"), text: Binding(get: { form.values[field.id, default: ""] }, set: { form.values[field.id] = $0; form.saveDraft() }))
                        .textFieldStyle(.roundedBorder).mimicInput().accessibilityLabel(field.title)
                        .onSubmit { if form.valid && form.hasReadRevision && !form.conflict { Task { await form.run("apply") } } }
                }.controlSize(.mini)
            }
            HStack(spacing: 5) {
                Button(text("customPanel.resetAll")) { Task { await form.run("resetAll") } }
                    .disabled(!form.hasReadRevision || form.conflict)
                Button(text("customPanel.apply")) { Task { await form.run(form.result?.status == "launchFailed" ? "launch" : "apply") } }
                    .disabled(!form.valid || !form.hasReadRevision || form.conflict)
                Button(text("customPanel.refresh")) { Task { await form.refresh() } }
                Spacer(minLength: 0)
            }.buttonStyle(MimicAuxiliaryButtonStyle(height: 20, horizontalPadding: 6)).controlSize(.mini)
            Text(form.busy ? text("customPanel.working") : form.conflict ? text("customPanel.conflict") : form.message.isEmpty && form.result == nil ? text(form.hasReadRevision ? "customPanel.cached" : "customPanel.refreshRequired") : form.message)
                .lineLimit(1).foregroundStyle(.secondary).mimicHelp(form.conflict ? text("customPanel.conflict") : form.message)
        }.mimicFont(.caption).disabled(form.busy).background(PanelControlRegion())
            .accessibilityIdentifier("customPanel." + form.panel.id)

    }
}
