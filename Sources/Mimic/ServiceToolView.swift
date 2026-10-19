// Created by Василий Маслов on 16.10.2026.
import AppKit
import SwiftUI
import MimicCore

/// Draft ownership matches the desktop surface; network results never become a serialized task.
@MainActor final class ServiceToolForm: ObservableObject {
    @Published var uid = ""
    @Published var actionID: String
    @Published var variantID: String
    @Published var drafts: [String: [String: String]] = [:]
    @Published var recent: [BridgeValue] = []
    @Published var context: ServiceToolContext
    @Published var result: BridgeValue = .null
    @Published var pending = false
    @Published var message = ""
    let tool: ServiceTool
    private unowned let model: TaskCoordinator
    private let project: ProjectContext
    private let snapshot: ProfileSnapshot
    private var scope: String { ServiceToolCoordinator.scope(owner: "desktop", tool: tool.id, context: context) }
    var action: ServiceTool.Action { tool.actions.first { $0.id == actionID } ?? tool.actions[0] }
    var variant: ServiceTool.Variant { action.variants.first { $0.id == variantID } ?? action.variants[0] }
    var key: String { action.id + ":" + variant.id }
    init(model: TaskCoordinator, tool: ServiceTool, project: ProjectContext, snapshot: ProfileSnapshot) {
        self.model = model; self.tool = tool; self.project = project; self.snapshot = snapshot
        actionID = tool.actions[0].id; variantID = tool.actions[0].variants[0].id
        context = model.serviceContext(tool: tool, project: project, snapshot: snapshot, selection: model.serviceSettingsSelection(checkout: project.path, panelID: tool.source.panelID))
        load()
    }
    private func load() {
        let value = model.serviceTools.state(scope: scope)
        uid = value["uid"].string ?? ""; recent = value["recent"].array ?? []; result = value["result"]
        drafts = value["drafts"].object?.mapValues { $0.object?.compactMapValues(\.string) ?? [:] } ?? [:]
    }
    func refresh() {
        guard model.project == project, model.activeProfile == snapshot else { return }
        let next = model.serviceContext(tool: tool, project: project, snapshot: snapshot, selection: model.serviceSettingsSelection(checkout: project.path, panelID: tool.source.panelID))
        if next != context { context = next; message = ""; load() }
    }
    func save(clearRecent: Bool = false) {
        do { try model.serviceTools.save(scope: scope, tool: tool, uid: uid.trimmingCharacters(in: .whitespacesAndNewlines), drafts: drafts, clearRecent: clearRecent); if clearRecent { recent = [] } }
        catch { message = text("service.invalid") }
    }
    func value(_ field: ServiceTool.Field) -> String { drafts[key]?[field.id] ?? (field.source == "appVersion" ? context.appVersion : field.defaultValue) }
    func binding(_ field: ServiceTool.Field) -> Binding<String> { Binding(get: { self.value(field) }, set: { self.drafts[self.key, default: [:]][field.id] = $0; self.save() }) }
    var valid: Bool { !context.namespace.isEmpty && (!action.usesUID || ServiceToolCoordinator.validUID(uid)) && variant.fields.allSatisfy { $0.accepts(value($0)) } }
    func chooseRecent(_ value: BridgeValue) {
        uid = value["uid"].string ?? ""
        let contact = value["contact"].string ?? ""
        if !contact.contains("@"), !contact.isEmpty {
            for action in tool.actions { for variant in action.variants where variant.fields.contains(where: { $0.id == "phone" }) { drafts[action.id + ":" + variant.id, default: [:]]["phone"] = contact } }
        }
        save()
    }
    func run() async {
        guard !pending, !model.admissionsClosed, valid else { return }
        pending = true; message = ""; defer { pending = false }
        let captured = context, capturedScope = scope, id = UUID()
        do {
            try model.verifyServiceProfile(snapshot)
            var next = try model.serviceTools.start(owner: "desktop", tool: tool, context: captured, actionID: action.id, variantID: variant.id, uid: uid, values: drafts[key] ?? [:], requestID: id) { [weak self] in
                guard let self, self.model.project == self.project, self.model.activeProfile == self.snapshot else { return false }
                return self.model.serviceContext(tool: self.tool, project: self.project, snapshot: self.snapshot, selection: self.model.serviceSettingsSelection(checkout: self.project.path, panelID: self.tool.source.panelID)) == captured
            }
            while next["phase"].string == "pending" {
                try await Task.sleep(for: .milliseconds(200))
                next = model.serviceTools.result(scope: capturedScope, requestID: id)
            }
            refresh(); guard context == captured else { return }
            result = next; load()
            if let selected = recent.first(where: { $0["uid"].string == uid }) { chooseRecent(selected) }
        } catch { message = text("service.invalid") }
    }
}

struct ServiceToolView: View {
    @StateObject private var form: ServiceToolForm
    private let live: Bool
    @State private var extras = false
    @State private var showingResult = false
    @State private var reveal = false
    init(model: TaskCoordinator, tool: ServiceTool, project: ProjectContext, snapshot: ProfileSnapshot) {
        _form = StateObject(wrappedValue: ServiceToolForm(model: model, tool: tool, project: project, snapshot: snapshot)); live = true
    }
    init(form: ServiceToolForm) { _form = StateObject(wrappedValue: form); live = false }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(form.context.namespace.isEmpty ? text("service.noEnvironment") : form.context.namespace).lineLimit(1).foregroundStyle(.secondary)
                TextField("UID", text: $form.uid).textFieldStyle(.roundedBorder).mimicInput().accessibilityLabel("UID").frame(width: 96).mimicHelp(form.uid)
                    .onChange(of: form.uid) { _, _ in form.save() }
                Menu { ForEach(Array(form.recent.enumerated()), id: \.offset) { _, item in Button(ServiceToolCoordinator.string(item["uid"]) + " · " + ServiceToolCoordinator.string(item["contact"])) { form.chooseRecent(item) } }; Button(text("service.clearRecent")) { form.save(clearRecent: true) } } label: { Image(systemName: "clock") }
                    .mimicHelp(text("service.recent"))
            }
            HStack(spacing: 4) {
                Picker(text("service.action"), selection: $form.actionID) { ForEach(form.tool.actions) { Text($0.title).tag($0.id) } }.labelsHidden()
                    .mimicSelection(text("service.action"), selection: $form.actionID, options: form.tool.actions.map { .init($0.title, $0.id) }, labelsHidden: true)
                if form.action.variants.count > 1 { Picker(text("service.mode"), selection: $form.variantID) { ForEach(form.action.variants) { Text($0.title).tag($0.id) } }.labelsHidden().mimicSelection(text("service.mode"), selection: $form.variantID, options: form.action.variants.map { .init($0.title, $0.id) }, labelsHidden: true) }
            }
            HStack(spacing: 4) { ForEach(form.variant.fields.filter { !$0.advanced }) { field in editor(field) } }
            HStack(spacing: 5) {
                Button { Task { await form.run() } } label: { Text(text("service.run")).lineLimit(1).fixedSize() }.disabled(form.pending || !form.valid)
                Button { extras = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel(text("service.extra")).mimicHelp(text("service.extra")).popover(isPresented: $extras) {
                    ScrollView { VStack(alignment: .leading, spacing: 10) { Text(form.action.hint).foregroundStyle(.secondary); ForEach(form.variant.fields.filter(\.advanced)) { field in editor(field) } }.padding(12) }.frame(width: 360, height: 340)
                }
                Spacer(minLength: 0)
                Button { reveal = false; showingResult = true } label: { Text(text("service.result")).lineLimit(1).fixedSize() }.disabled(form.result == .null)
            }.buttonStyle(MimicAuxiliaryButtonStyle(height: 20, horizontalPadding: 5))
            Text(form.pending ? text("service.pending") : !form.message.isEmpty ? form.message : text("service." + (form.result["phase"].string ?? "ready")))
                .lineLimit(1).foregroundStyle(.secondary).mimicHelp(form.action.hint)
        }.controlSize(.mini).mimicFont(.caption).background(PanelControlRegion())
            .onChange(of: form.actionID) { _, _ in form.variantID = form.action.variants[0].id }
            .popover(isPresented: $showingResult) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text("service." + (form.result["phase"].string ?? "ready")))
                    ForEach(["uid", "email", "phone", "password", "session", "token", "code", "auth_code"], id: \.self) { key in
                        let value = ServiceToolCoordinator.string(form.result["data"][key])
                        if !value.isEmpty { HStack { Text(key); Text(["password", "session", "token"].contains(key) && !reveal ? "••••••" : value).textSelection(.enabled); Spacer(); Button(text("service.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } } }
                    }
                    Toggle(text("service.reveal"), isOn: $reveal)
                    ScrollView { Text(jsonResult).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button(text("service.copyJSON")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(jsonResult, forType: .string) }
                }.padding(12).frame(width: 420, height: 350)
            }
            .task { guard live else { return }; while !Task.isCancelled { form.refresh(); do { try await Task.sleep(for: .seconds(1)) } catch { break } } }
    }
    @ViewBuilder private func editor(_ field: ServiceTool.Field) -> some View {
        if field.kind == .boolean { Toggle(field.title, isOn: Binding(get: { form.value(field) == "true" }, set: { form.binding(field).wrappedValue = String($0) })) }
        else if let choices = field.choices, field.customChoice != true { Picker(field.title, selection: form.binding(field)) { ForEach(choices, id: \.value) { Text($0.title).tag($0.value) } }.mimicSelection(field.title, selection: form.binding(field), options: choices.map { .init($0.title, $0.value) }) }
        else {
            HStack(spacing: 2) {
                if field.secret { SecureField(field.title, text: form.binding(field)).textFieldStyle(.roundedBorder) }
                else { TextField(field.title, text: form.binding(field)).textFieldStyle(.roundedBorder).mimicInput() }
                if let choices = field.choices { Menu { ForEach(choices, id: \.value) { item in Button(item.title) { form.binding(field).wrappedValue = item.value } } } label: { Image(systemName: "chevron.down") } }
            }.accessibilityLabel(field.title).mimicHelp(field.title)
        }
    }
    private var jsonResult: String {
        func redact(_ value: BridgeValue) -> BridgeValue {
            switch value {
            case .object(let fields): return .object(fields.mapValues { redact($0) }.merging(Dictionary(uniqueKeysWithValues: fields.keys.filter { ["password", "session", "token", "auth_code", "code"].contains($0.lowercased()) }.map { ($0, .string("••••••")) })) { _, new in new })
            case .array(let values): return .array(values.map(redact))
            default: return value
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(reveal ? form.result["data"] : redact(form.result["data"]))) ?? Data(), as: UTF8.self)
    }
}
