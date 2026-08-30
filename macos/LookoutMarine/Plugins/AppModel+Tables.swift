//  AppModel+Tables.swift — the tables the plugins declare.
//
//  macOS only: each declaration becomes a menu item and an NSWindow. The
//  reveal-on-chart path is shell-side; the plugin is not told.

import Foundation

@MainActor
extension AppModel {
    #if os(macOS)
    /// Open one declared table's window, or bring it forward.
    func showPluginTable(_ spec: PluginTableSpec) {
        _ = PluginTableWindowController.show(spec, model: self)
    }

    /// Pin one declared table row on the chart by its id, for the screenshot
    /// protocol's LOOKOUT_SHOW=target:<id>. The empty id takes the first row
    /// of the declared sort, which for the AIS targets is the nearest
    /// approach. This is the locate-on-chart path a double-click takes, minus
    /// the dialog, so the frame holds the chart and the bubble alone.
    func revealTableRow(_ id: String) {
        guard let c = controller, let spec = c.tableSpecs().first(where: { $0.locatable })
        else { return }
        // A plugin builds no rows until it is told the dialog is open, so the
        // dialog is opened to make them, read, and shut again. What is wanted
        // is the bubble on the chart, not the dialog over it.
        let window = PluginTableWindowController.show(spec, model: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            defer { window.dismiss() }
            guard let self,
                  let got = c.tableRows(plugin: spec.plugin, key: spec.key,
                                        sortKey: spec.sortKey, ascending: spec.sortAscending,
                                        columns: spec.columns.count) else { return }
            let row = id.isEmpty ? got.rows.first : got.rows.first { $0.id == id }
            guard let row, let lat = row.lat, let lon = row.lon else { return }
            self.revealOnChart(lon: lon, lat: lat)
        }
    }

    /// Show a place a plugin table row named: centre the chart on it and pin
    /// the bubble of whatever the plugin draws there. A row with no position
    /// never gets here.
    func revealOnChart(lon: Double, lat: Double) {
        guard let c = controller else { return }
        if let hit = c.reveal(lon: lon, lat: lat) { pin(hit) } else { closePin() }
    }

    /// Open one declared table, for the screenshot protocol's
    /// LOOKOUT_SHOW=table[:key[:sort[:asc|desc[:activate]]]]. The first
    /// declaration when no key is named, and the declared sort unless one is
    /// asked for — which is the same choice a mariner makes by clicking a
    /// column heading. `activate` opens the top row the way a double-click
    /// does, so the locate-on-chart path can be photographed.
    func openPluginTable(_ spec: String) {
        guard let c = controller else { return }
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let key = parts.first ?? ""
        let specs = c.tableSpecs()
        let want = key.isEmpty ? specs.first : specs.first { $0.key == key }
        guard let want else { return }
        let window = PluginTableWindowController.show(want, model: self,
                                                      sortKey: parts.count > 1 ? parts[1] : nil,
                                                      ascending: parts.count < 3 || parts[2] != "desc")
        guard parts.count > 3, parts[3] == "activate" else { return }
        // A moment for the plugin's first batch: it builds no rows until it is
        // told the dialog is open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { window.activateTopRow() }
    }
    #endif
}
