//  PluginTableView.swift: one declared table, on a touch device.
//
//  The Mac gets an NSWindow per declaration, opened from the menu bar. A phone
//  and an iPad have no menu bar, so the same declaration becomes a row in the
//  settings form and a page pushed from it. Same columns, same header sort,
//  same flag tint, same dash for a cell nobody sent, and the same
//  locate-on-chart.
//
//  A page, not a sheet: the form is already a sheet, and a sheet cannot present
//  another one from the view it came up over. The licences screen is pushed
//  from the same form for the same reason.
//
//  THE ORDER IS THE PLUGIN'S FIRST. Every row has a band and the core sorts
//  within a band, never across one, so tapping a heading reorders the vessels
//  under an alarmed one and never moves it off the top line.

#if os(iOS)
import SwiftUI

struct PluginTableView: View {
    var model: AppModel
    let spec: PluginTableSpec

    /// The rows as the core last handed them over.
    @State private var rows: [PluginTableRow] = []
    @State private var sortKey: String = ""
    @State private var ascending = true
    /// The last batch. Rows are rebuilt only when it moves, so a table nobody
    /// is feeding does not flicker once a second.
    @State private var seq = -1

    /// The plugins feed a table at the status cadence, which is a second.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView("Nothing to show yet", systemImage: "list.bullet")
            } else {
                table
            }
        }
        .navigationTitle(spec.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sortKey = spec.sortKey
            ascending = spec.sortAscending
            // The plugin builds no rows until it is told the table is open, so
            // the first read would otherwise find none.
            model.controller?.setTableOpen(plugin: spec.plugin, key: spec.key, true)
            reload(force: true)
        }
        .onDisappear {
            model.controller?.setTableOpen(plugin: spec.plugin, key: spec.key, false)
        }
        .onReceive(tick) { _ in reload(force: false) }
    }

    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ForEach(rows, id: \.id) { row in
                    rowView(row)
                    Divider().opacity(0.4)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(Array(spec.columns.enumerated()), id: \.offset) { _, col in
                Button {
                    // A repeat tap on the same heading flips the direction, as
                    // clicking one does on the Mac.
                    if sortKey == col.key { ascending.toggle() } else {
                        sortKey = col.key
                        ascending = true
                    }
                    reload(force: true)
                } label: {
                    HStack(spacing: 2) {
                        if col.type.numeric { Spacer(minLength: 0) }
                        Text(col.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if sortKey == col.key {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        if !col.type.numeric { Spacer(minLength: 0) }
                    }
                    .frame(width: Self.width(for: col))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(col.label.isEmpty ? col.key : col.label)")
            }
        }
        .padding(.vertical, 8)
    }

    private func rowView(_ row: PluginTableRow) -> some View {
        // A row the plugin never heard a position from cannot be found on the
        // chart, and neither can a table that declared no `at`.
        let locatable = spec.locatable && row.lat != nil && row.lon != nil
        return Button {
            guard let lat = row.lat, let lon = row.lon else { return }
            model.overlay.revealOnChart(lon: lon, lat: lat)
            // The chart is behind the form, so shut the form to show it.
            model.chrome.showSettings = false
        } label: {
            HStack(spacing: 0) {
                ForEach(Array(spec.columns.enumerated()), id: \.offset) { i, col in
                    let cell = row.cell(i)
                    Text(PluginTableFormat.text(cell, col.type))
                        .font(.system(.caption, design: .default).monospacedDigit())
                        .foregroundStyle(tint(cell, col))
                        .lineLimit(1)
                        .frame(width: Self.width(for: col),
                               alignment: col.type.numeric ? .trailing : .leading)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.rowTint(row, spec: spec))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!locatable)
        .accessibilityHint(locatable ? "Shows it on the chart" : "")
    }

    /// A cell nobody sent is greyed, so a value that is missing reads
    /// differently from one that is small. A flag takes its own colour.
    private func tint(_ cell: PluginCell, _ col: PluginTableColumn) -> Color {
        if case .empty = cell { return .secondary.opacity(0.6) }
        guard col.type == .flag else { return .primary }
        switch cell.string?.lowercased() {
        case "alarm": return .red
        case "warning": return .orange
        default: return .primary
        }
    }

    /// The row's own colour, from its flag column. Alarm is the chart's danger
    /// red; a warning is amber. A row with no flag is left alone.
    private static func rowTint(_ row: PluginTableRow, spec: PluginTableSpec) -> Color {
        for (i, col) in spec.columns.enumerated() where col.type == .flag {
            switch row.cell(i).string?.lowercased() {
            case "alarm": return Color.red.opacity(0.16)
            case "warning": return Color.orange.opacity(0.14)
            default: continue
            }
        }
        return .clear
    }

    private static func width(for col: PluginTableColumn) -> CGFloat {
        col.type == .text ? 130 : 76
    }

    private func reload(force: Bool) {
        guard let c = model.controller else { return }
        guard let batch = c.tableRows(plugin: spec.plugin, key: spec.key,
                                      sortKey: sortKey, ascending: ascending,
                                      columns: spec.columns.count)
        else {
            // The plugin has gone, and the table with it. Better an empty sheet
            // than a picture nobody is keeping up to date.
            seq = -1
            if !rows.isEmpty { rows = [] }
            return
        }
        guard force || batch.seq != seq else { return }
        seq = batch.seq
        rows = batch.rows
    }
}

/// The tables a plugin put in this section of the form, as rows that open one.
///
/// The Mac builds a menu item per declaration; a touch device has no menu bar,
/// so the same declaration lands here. A plugin that declares no table
/// contributes nothing and the section shows none.
struct PluginTableRows: View {
    var model: AppModel
    let tab: String

    private var specs: [PluginTableSpec] {
        model.plugins.tables.filter { $0.menu.lowercased() == tab }
    }

    var body: some View {
        if !specs.isEmpty {
            Section {
                ForEach(specs) { spec in
                    NavigationLink {
                        PluginTableView(model: model, spec: spec)
                    } label: {
                        Text(spec.title)
                    }
                    .accessibilityIdentifier("plugin-table-\(spec.key)")
                }
            } footer: {
                Text("What the plugins are tracking right now. A row shows its place on the chart.")
                    .captionFooter()
            }
        }
    }
}

#endif
