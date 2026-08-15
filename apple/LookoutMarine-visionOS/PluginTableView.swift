//
//  A plugin's declared table, beside the chart.
//
//  The AIS plugin declares one: every target it is tracking, closest approach
//  first. The flags standing on the sheet say where the traffic is; this says
//  what it is, in the order that matters, and it is what a mariner reads when
//  something is closing.
//
//  Everything here comes from the declaration. The columns, their types, the
//  order and the band that holds an alarmed row at the top are the plugin's;
//  the formatting is PluginTableFormat's, shared with the Mac. Nothing in this
//  file knows what a plugin does.
//

import SwiftUI

/// Which table is on screen, and the rows in it. The plugin only builds rows
/// while something is reading them, so this tells it when the window opens and
/// when it closes.
@MainActor
@Observable
final class PluginTableModel {
    private(set) var specs: [PluginTableSpec] = []
    private(set) var rows: [PluginTableRow] = []
    var selected: String?
    var sortKey = ""
    var ascending = true

    private weak var host: (any PluginTableHost)?
    private var openKey: String?
    private var seq = -1

    var spec: PluginTableSpec? {
        specs.first { $0.id == selected } ?? specs.first
    }

    func start(host: any PluginTableHost) {
        self.host = host
        specs = host.tableSpecs()
        if selected == nil { selected = specs.first?.id }
        if let spec, sortKey.isEmpty {
            sortKey = spec.sortKey
            ascending = spec.sortAscending
        }
        openTable()
        refresh()
    }

    func stop() {
        closeTable()
        rows = []
        seq = -1
    }

    /// Read again. A table is fed from the plugin's own thread, so this runs
    /// on a timer while the window is up.
    func refresh() {
        guard let host, let spec else { return }
        openTable()
        guard let got = host.tableRows(plugin: spec.plugin, key: spec.key,
                                       sortKey: sortKey, ascending: ascending,
                                       columns: spec.columns.count)
        else { return }
        // The seq moves when the plugin has fed the table. The rows are
        // rebuilt only then, except after a sort, which reorders what is
        // already there.
        if got.seq != seq || rows.count != got.rows.count {
            seq = got.seq
        }
        rows = got.rows
    }

    /// Sort by a column, or reverse it when it is already the sorted one. The
    /// core does the sorting: it holds the plugin's bands, which a sort here
    /// would break.
    func sort(by key: String) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = true
        }
        seq = -1
        refresh()
    }

    func show(_ id: String) {
        guard id != selected else { return }
        closeTable()
        selected = id
        if let spec {
            sortKey = spec.sortKey
            ascending = spec.sortAscending
        }
        seq = -1
        refresh()
    }

    private func openTable() {
        guard let spec, openKey != spec.id else { return }
        closeTable()
        host?.setTableOpen(plugin: spec.plugin, key: spec.key, true)
        openKey = spec.id
    }

    private func closeTable() {
        guard let openKey, let spec = specs.first(where: { $0.id == openKey }) else { return }
        host?.setTableOpen(plugin: spec.plugin, key: spec.key, false)
        self.openKey = nil
    }
}

struct PluginTableView: View {
    let model: TableModel
    @State private var tables = PluginTableModel()
    /// The plugin feeds its own table, so nothing else would bring a new row
    /// to the screen.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if let spec = tables.spec {
                header(spec)
                Divider()
                table(spec)
            } else {
                ContentUnavailableView("No tables",
                                       systemImage: "tablecells",
                                       description: Text("A plugin declares a table and it appears here. The AIS plugin declares one for its targets."))
            }
        }
        .onAppear { tables.start(host: model.engine) }
        .onDisappear { tables.stop() }
        .onReceive(tick) { _ in tables.refresh() }
    }

    /// The title, and the picker when more than one plugin declares a table.
    @ViewBuilder
    private func header(_ spec: PluginTableSpec) -> some View {
        HStack {
            Text(spec.title).font(.title2.bold())
            Spacer()
            if tables.specs.count > 1 {
                Picker("Table", selection: Binding(
                    get: { tables.selected ?? spec.id },
                    set: { tables.show($0) })) {
                    ForEach(tables.specs) { s in Text(s.title).tag(s.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text("\(tables.rows.count)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func table(_ spec: PluginTableSpec) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(tables.rows.enumerated()), id: \.offset) { _, row in
                        rowView(row, spec: spec)
                    }
                } header: {
                    headerRow(spec)
                }
            }
        }
    }

    private func headerRow(_ spec: PluginTableSpec) -> some View {
        HStack(spacing: 12) {
            ForEach(spec.columns, id: \.key) { column in
                Button {
                    tables.sort(by: column.key)
                } label: {
                    HStack(spacing: 3) {
                        Text(column.label)
                        if tables.sortKey == column.key {
                            Image(systemName: tables.ascending ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity,
                           alignment: column.type.numeric ? .trailing : .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func rowView(_ row: PluginTableRow, spec: PluginTableSpec) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(spec.columns.enumerated()), id: \.offset) { i, column in
                Text(PluginTableFormat.text(row.cell(i), column.type))
                    .font(column.type.numeric ? .body.monospacedDigit() : .body)
                    .frame(maxWidth: .infinity,
                           alignment: column.type.numeric ? .trailing : .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        // A plugin colors a row by its flag column: an alarmed vessel is red
        // wherever it is shown, on the chart and here.
        .background(background(row, spec: spec))
    }

    private func background(_ row: PluginTableRow, spec: PluginTableSpec) -> Color {
        guard let i = spec.columns.firstIndex(where: { $0.type == .flag }) else { return .clear }
        switch row.cell(i).string {
        case "alarm": return Color.red.opacity(0.22)
        case "warning": return Color.orange.opacity(0.18)
        default: return .clear
        }
    }
}
