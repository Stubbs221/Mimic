// Created by Василий Маслов on 09.10.2026.
import SwiftUI
import MimicCore

/// The grid supplies the icon/title once. Every compact size owns its launch and cancellation controls.
struct BuildCardView: View {
    @ObservedObject var model: TaskCoordinator
    @ObservedObject var builds: BuildCoordinator
    var full = false
    var extended = false
    @Environment(\.mimicTextScale) private var textScale
    @State private var popup = ""
    @State private var action = "run"
    @State private var search = ""
    @State private var dismissedSuccessID: UUID?
    private struct SuccessStatus: Hashable {
        let id: UUID
        let expiresAt: Date
    }
    private var successStatus: SuccessStatus? {
        guard !extended, let record = builds.panelActivity, record.status == .succeeded else { return nil }
        return SuccessStatus(id: record.id, expiresAt: (record.finishedAt ?? record.createdAt).addingTimeInterval(5))
    }
    /// Only compact feedback expires; the activity and its detailed result remain available.
    private var statusActivity: BuildActivity? {
        guard let record = builds.panelActivity else { return nil }
        if let success = successStatus, success.id == dismissedSuccessID || success.expiresAt <= .now { return nil }
        return record
    }
    private var resourcePlatform: BootstrapPlatform { builds.catalogue.destinations.first { $0.id == builds.draft.destinationID }?.platform ?? builds.draft.platform ?? .ios }
    private var resources: BuildResourceState { model.project.map { model.cachedBuildResources(project: $0, platform: resourcePlatform) } ?? .init() }
    private var resourceActivity: TaskRecord? { model.project.flatMap { model.buildResourceActivity(project: $0, platform: resourcePlatform) } }
    private var resourceBusy: Bool {
        guard let project = model.project else { return false }
        return model.resourceRecoveryAdmissions.contains(model.buildResourceKey(project: project, platform: resourcePlatform))
            || resourceActivity.map { [.queued, .running].contains($0.status) || model.agentMetadataPending.contains($0.id) } == true
    }
    private var resourceFailure: Bool { resources.blocking && resourceActivity?.status == .failed }
    private var presented: Binding<Bool> { Binding(get: { !popup.isEmpty }, set: { if !$0 { popup = "" } }) }
    private struct ContextKey: Hashable {
        let path: String?, branch: String?, commit: String?, developer: String?, target: String?, configuration: String?, profile: String?, revision: String?, platform: String
    }
    private var contextKey: ContextKey {
        ContextKey(path: model.project?.path, branch: model.project?.branch, commit: model.project?.commit,
                   developer: model.project?.developerDirectory, target: model.project?.appleTarget?.path,
                   configuration: model.project?.appleTarget?.configurationProject, profile: model.activeProfile?.id, revision: model.activeProfile?.revision, platform: resourcePlatform.rawValue)
    }

    private var targets: [BuildTestTarget] { builds.catalogue.testTargets ?? [] }
    private var destination: String { builds.catalogue.destinations.first { $0.id == builds.draft.destinationID }?.name ?? text("build.chooseDevice") }
    private var targetSelection: Binding<String> {
        Binding(get: { builds.draft.testTarget ?? "" }, set: { value in
            builds.draft.testTarget = value.isEmpty ? nil : value
            builds.draft.testIdentifiers = []
            builds.draft.testPlan = targets.first { $0.name == value }?.testPlan ?? ""
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: extended ? 12 : 4) {
            if (resourceBusy || resourceFailure), let project = model.project {
                BuildResourceRecoveryView(model: model, project: project, platform: resourcePlatform, state: resources, record: resourceActivity)
            } else if extended {
                Picker(text("build.action"), selection: $action) {
                    Text(text("build.tab.build")).tag("build"); Text(text("build.tab.run")).tag("run"); Text(text("build.tab.tests")).tag("tests")
                }.pickerStyle(.segmented).mimicSegments(selection: $action, options: [.init(text("build.tab.build"), "build"), .init(text("build.tab.run"), "run"), .init(text("build.tab.tests"), "tests")]).accessibilityIdentifier("build.tabs")
                settings
                if let check = resources.blocker, let project = model.project {
                    BuildResourceReason(check: check)
                    BuildResourceRestoreButton(model: model, project: project, platform: resourcePlatform, check: check)
                } else {
                    if action == "tests" { targetSection }
                    launch(action, primary: true)
                }
            } else if !extended, builds.loading, builds.panelActivity?.status.isPending != true, let progress = builds.catalogueProgress {
                BuildCatalogueProgressView(progress: progress)
            } else if let record = statusActivity, !extended {
                BuildInlineStatus(builds: builds, record: record, compact: true, full: full, chooseProduct: { popup = "products" })
            } else if !extended {
                compactControls
            }
            if extended, let record = statusActivity {
                BuildInlineStatus(builds: builds, record: record, chooseProduct: { popup = "products" })
            }

            if !builds.message.isEmpty, !resources.blocking, !resourceBusy { Text(builds.message).mimicFont(.caption).foregroundStyle(.orange).lineLimit(extended ? nil : 1).mimicHelp(builds.message) }
        }.frame(maxWidth: .infinity, maxHeight: extended ? nil : .infinity, alignment: .topLeading)
            .background(PanelControlRegion())
            .mimicPopover(isPresented: presented) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(text(popup == "products" ? "build.chooseProduct" : "build.parameters.title")).mimicFont(.heading); Spacer(); Button(text("close")) { popup = "" }.buttonStyle(.plain) }
                    if popup == "products" { products } else { settings }
                }.padding(16).frame(width: 400).fixedSize(horizontal: false, vertical: true)
            }
            .task(id: contextKey) {
                guard let project = model.project else { return }
                await builds.restoreDraft(project: project)
                guard model.activeProfile?.profile.buildResources?.contains(where: { $0.platform == resourcePlatform }) == true else { return }
                while !Task.isCancelled {
                    _ = try? await model.refreshBuildResources(project: project, platform: resourcePlatform)
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
            .onChange(of: builds.draft) { _, _ in if let project = model.project { builds.saveDraft(project: project) } }
            .task(id: successStatus) {
                guard let success = successStatus else { return }
                let remaining = success.expiresAt.timeIntervalSinceNow
                if remaining > 0 {
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                dismissedSuccessID = success.id
            }
            .onChange(of: builds.panelActivity?.stage) { _, stage in if stage == .products, builds.panelActivity?.products?.count ?? 0 > 1 { popup = "products" } }
            .onChange(of: builds.panelActivity?.products) { _, value in if builds.panelActivity?.stage == .products, value?.count ?? 0 > 1 { popup = "products" } }
            .onChange(of: builds.panelActivity?.status) { _, value in if popup == "products", value?.isPending != true { popup = "" } }
            .onChange(of: contextKey) { _, _ in popup = "" }
            .accessibilityIdentifier(extended ? "build.extended" : full ? "build.full" : "build.mini")
    }

    // MARK: - Compact launch controls

    @ViewBuilder private var compactControls: some View {
        if full {
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 4) { selections.labelsHidden(); targetPicker.labelsHidden() }.frame(maxWidth: .infinity)
                VStack(spacing: 4) {
                    if let check = resources.blocker, let project = model.project {
                        BuildResourceReason(check: check)
                        BuildResourceRestoreButton(model: model, project: project, platform: resourcePlatform, check: check)
                    } else {
                        launch("tests", primary: true); launch("run"); launch("build")
                    }
                }.frame(maxWidth: .infinity)
            }

        } else {
            Button { popup = "settings" } label: {
                Text((builds.draft.scheme.isEmpty ? text("build.chooseScheme") : builds.draft.scheme) + " · " + destination + " ⌄")
                    .mimicFont(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityIdentifier("build.parameters")
            targetPicker.labelsHidden()
            if let check = resources.blocker, let project = model.project {
                BuildResourceReason(check: check)
                BuildResourceRestoreButton(model: model, project: project, platform: resourcePlatform, check: check)
            } else {
                launch("tests", primary: true)
                HStack(spacing: 8) { launch("run"); launch("build") }
            }
        }
    }
    private func launch(_ value: String, primary: Bool = false) -> some View {
        Button {
            if value == "tests" { builds.perform(.test) }
            else if !builds.draftCompatible { popup = "settings" }
            else { builds.perform(intent: value == "run" ? .run : nil) }
        } label: { Text(text(value == "tests" ? "build.tests.runTarget" : value == "run" && !extended ? "build.action.runShort" : "build.action." + value)).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity) }
            .buttonStyle(MimicAuxiliaryButtonStyle(primary: primary, height: (extended ? 32 : 28) * textScale, horizontalPadding: 8))
            .disabled(builds.panelBusy || model.project == nil || resources.blocking || resourceBusy || value == "tests" && !builds.testsCompatible)
            .accessibilityIdentifier("build.action." + value)
    }
    private var selections: some View {
        VStack(alignment: .leading, spacing: extended ? 8 : 4) {
            selection(text("build.scheme"), binding: parameter(\.scheme), values: builds.catalogue.schemes.map { .init($0, $0) })
                .accessibilityIdentifier("build.scheme")
            selection(text("build.destination"), binding: parameter(\.destinationID), values: builds.catalogue.destinations.map { .init($0.name, $0.id) })
                .accessibilityIdentifier("build.destination")
        }.disabled(builds.panelBusy)
    }
    private func selection(_ label: String, binding: Binding<String>, values: [MimicSelectionOption<String>]) -> some View {
        let empty = text(label == text("build.tests.target") && values.isEmpty ? "build.tests.noTargets" : "build.choose")
        let options = [MimicSelectionOption(empty, "")] + values
        return HStack(spacing: 12) {
            if (extended || !popup.isEmpty) && label != text("build.tests.target") { Text(label).mimicFont(.caption).foregroundStyle(.secondary).frame(width: 88, alignment: .leading) }
            BuildSelectionPopup(title: label, selection: binding, options: options, height: extended || !popup.isEmpty ? 32 : full ? 28 : 24)
                .mimicSelection(label, selection: binding, options: options, labelsHidden: true)
                .accessibilityLabel(label).mimicHelp(values.first { $0.value == binding.wrappedValue }?.title ?? empty)
                .frame(maxWidth: .infinity)
        }
    }
    private var targetPicker: some View {
        selection(text("build.tests.target"), binding: targetSelection, values: targets.map { .init($0.name, $0.name) })
            .disabled(builds.panelBusy || targets.isEmpty).accessibilityIdentifier("build.tests.target")
            .mimicHelp(targets.isEmpty ? text("build.tests.noTargets") : builds.draft.testTarget ?? "")
    }
    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider(); Text(text("build.tests.target")).mimicFont(.heading)
            targetPicker
            if targets.isEmpty { Text(text("build.tests.noTargets")).mimicFont(.caption).foregroundStyle(.secondary) }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text("build.environment")).mimicFont(.heading)
            selections
            DisclosureGroup(text("build.moreSettings")) {
                selection(text("build.configuration"), binding: parameter(\.configuration), values: builds.catalogue.configurations.map { .init($0, $0) })
            }.disabled(builds.panelBusy)
            Button(text("build.refreshSettings")) { Task { if let project = model.project { await builds.refreshCatalogue(project: project, includeTestPlans: true, force: true) } } }
                .buttonStyle(MimicAuxiliaryButtonStyle()).disabled(builds.loading || builds.panelBusy)
            if builds.loading, let progress = builds.catalogueProgress { BuildCatalogueProgressView(progress: progress) }
            if !builds.message.isEmpty { Text(builds.message).mimicFont(.caption).foregroundStyle(.orange) }
        }
    }
    private var products: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let record = builds.panelActivity {
                ForEach(record.products ?? []) { product in Button(product.name) { try? builds.chooseProduct(product.id, activityID: record.id); popup = "" } }
                Button(text("build.stop")) { builds.cancel(record.id); popup = "" }
            }
        }
    }
    private func parameter(_ keyPath: WritableKeyPath<BuildParameters, String>) -> Binding<String> {
        Binding(get: { builds.draft[keyPath: keyPath] }, set: { value in
            builds.draft[keyPath: keyPath] = value; builds.draft.testIdentifiers = []
            if keyPath == \.scheme, let project = model.project { Task { await builds.refreshCatalogue(project: project, scheme: value, includeTestPlans: true) } }
        })
    }
}

struct BuildCatalogueProgressView: View {
    let progress: BuildCatalogueProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text("build.catalogue.progress." + progress.phase.rawValue)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if progress.total > 0 { Text("\(progress.step)/\(progress.total)").monospacedDigit().fixedSize() }
                MimicActivityClock(running: true) { now in
                    let seconds = max(0, Int(now.timeIntervalSince(progress.startedAt)))
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).monospacedDigit().fixedSize()
                }
            }.mimicFont(.caption).foregroundStyle(.secondary)
            MimicProgressBar(value: progress.fraction, color: .accentColor, label: text("build.catalogue.progress.label"))
                .accessibilityValue(progress.total > 0 ? String(format: text("build.catalogue.progress.completed"), progress.completed, progress.total) : text("build.catalogue.progress." + progress.phase.rawValue))
        }.mimicHelp(text("build.catalogue.progress." + progress.phase.rawValue))
            .accessibilityIdentifier("build.catalogue.progress")
    }
}

/// Full divides the available content width equally; only its left column contains the progress bar.
struct BuildInlineStatus: View {
    @ObservedObject var builds: BuildCoordinator
    let record: BuildActivity
    var compact = false
    var full = false
    var chooseProduct: (() -> Void)?
    private var presented: BuildActivity { builds.presentation(record) }
    private var identity: String {
        [text(record.actionKey), record.parameters.scheme, record.selectedTestCount.map { String(format: text("build.workflow.methods"), $0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var context: String {
        var fields = [record.project.commit.isEmpty ? nil : String(record.project.commit.prefix(7)), record.source.isEmpty ? nil : record.source].compactMap { $0 }
        if let position = presented.queuePosition { fields.append(String(format: text("build.workflow.queuePosition"), position)) }
        else if let count = presented.workflowPendingCount, count > 0 { fields.append(String(format: text("build.workflow.pending"), count)) }
        return fields.joined(separator: " · ")
    }
    private var caseCoverage: String? {
        guard let summary = record.verificationSummary else { return nil }
        return text(summary.caseCoverage == "unknown" ? "build.workflow.casesUnknown" : summary.caseCoverage == "incomplete" ? "build.workflow.casesIncomplete" : "build.workflow.casesComplete")
    }
    var body: some View {
        Group {
            if compact && full {
                HStack(alignment: .center, spacing: 12) {
                    progress.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    actions.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) { progress; actions }
            }
        }.accessibilityElement(children: .contain)
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            Text(identity).mimicFont(.caption).lineLimit(compact ? 1 : nil).truncationMode(.middle).mimicHelp(identity)
            if !context.isEmpty { Text(context).mimicFont(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : nil).truncationMode(.middle).mimicHelp(context).accessibilityIdentifier("build.workflow.context") }
            Text(record.errorCode.map { text("build.error." + $0) } ?? text(record.phase)).mimicFont(.caption).foregroundStyle(buildColor(record)).lineLimit(compact ? 1 : nil).mimicHelp(record.errorCode.map { text("build.error." + $0) } ?? text(record.phase))
            BuildProgressView(record: record)
            if !compact, let error = record.errorCode { Text(text("build.error." + error)).mimicFont(.caption).foregroundStyle(.orange) }
        }
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caseCoverage, !record.status.isPending {
                Text(caseCoverage).mimicFont(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : nil).mimicHelp(caseCoverage + " · " + buildDuration(record)).accessibilityIdentifier("build.workflow.caseCoverage")
            } else {
                MimicActivityClock(running: record.status.isPending) { _ in Text(buildDuration(record)).monospacedDigit() }.mimicFont(.caption)
            }
            if record.stage == .products, record.status.isPending, record.products?.count ?? 0 > 1 {
                Button(text("build.chooseProduct")) { chooseProduct?() }.buttonStyle(MimicAuxiliaryButtonStyle(height: 28, horizontalPadding: 8))
            }
            if record.canCancel {
                Button(text(buildStopLabel(record))) { builds.cancel(record.id) }.buttonStyle(MimicAuxiliaryButtonStyle(height: 28)).accessibilityIdentifier("build.cancel")
            } else {
                Button(text("build.output")) { builds.showResult(record.id) }.buttonStyle(MimicAuxiliaryButtonStyle(height: 28)).accessibilityIdentifier("build.error.open")
            }
        }
    }
}

struct BuildProgressView: View {
    private var theme = MimicTheme()
    let record: BuildActivity
    var body: some View {
        Group {
            if let value = record.progressFraction { MimicProgressBar(value: value, color: buildColor(record), label: text("build.progress")) }
            else if record.status.isPending && theme.retro { MimicProgressBar(value: nil, color: buildColor(record), label: text("build.progress.active")) }
            else if record.status.isPending { ProgressView().progressViewStyle(.linear).tint(.accentColor).frame(height: 6).accessibilityLabel(text("build.progress.active")) }
            else { MimicProgressBar(value: 0, color: buildColor(record), label: text("build.progress")) }
        }.accessibilityIdentifier("build.progress")
    }
}
