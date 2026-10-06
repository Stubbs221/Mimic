//
//  InterfaceMapView.swift
//  Mimic
//
//  Created by Василий Маслов on 03.10.2026.
import SwiftUI

/// Stable names for discussing UI changes; this catalogue never reads task output or runs commands.
enum InterfaceTerm: String, CaseIterable, Identifiable {
    case panel, project, home, bootstrap, tools, builds, buildOverlay, simulators, settings, ci, branches, tasks, footer, quickMenu, mini, search, filters, row, details, header, technical, terminal, diagnostic, actions, analysis, map

    var id: String { self.rawValue }
    var title: String { text("interface.term." + self.rawValue + ".title") }
    var detail: String { text("interface.term." + self.rawValue + ".detail") }

    static func matching(_ query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.allCases.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.detail.localizedStandardContains(query) }
    }
}

/// A separate reference window keeps the selected working section and task intact.
struct InterfaceMapView: View {
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("interface.map.title")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(text("interface.map.intro")).font(.callout).foregroundStyle(.secondary)
            TextField(text("interface.map.search"), text: self.$query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("interface.map.search")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.diagram }
                    ForEach(InterfaceTerm.matching(self.query)) { term in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(term.title).font(.headline).accessibilityAddTraits(.isHeader)
                            Text(term.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine).accessibilityIdentifier("interface.term." + term.id)
                        Divider()
                    }
                    if InterfaceTerm.matching(self.query).isEmpty {
                        Text(text("interface.map.empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(text("interface.map.examples")).font(.callout).fixedSize(horizontal: false, vertical: true)
                }.padding(.trailing, 8)
            }.textSelection(.enabled)
        }.padding(20).frame(minWidth: 440, idealWidth: 560, minHeight: 420, idealHeight: 700)
            .background(Color(nsColor: .windowBackgroundColor)).accessibilityIdentifier("interface.map")
    }

    private var diagram: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("interface.map.diagram")).font(.headline)
            self.diagramRow(.project)
            VStack(alignment: .leading, spacing: 6) {
                Text(InterfaceTerm.home.title).font(.callout.weight(.semibold))
                Text(text("interface.map.home.contents")).font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(InterfaceTerm.tasks.title).font(.callout.weight(.semibold))
                    Text(text("interface.map.tasks.contents")).font(.callout).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            self.diagramRow(.settings)
            Text(text("interface.map.settings.contents")).font(.caption).foregroundStyle(.secondary)
            self.diagramRow(.footer)
            Text(text("interface.map.separate")).font(.caption).foregroundStyle(.secondary)
        }.padding(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
    }

    private func diagramRow(_ term: InterfaceTerm) -> some View {
        Text(term.title).font(.callout.weight(.medium)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
