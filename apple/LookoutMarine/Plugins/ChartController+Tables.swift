//  ChartController+Tables.swift — the tables and alerts the plugins declare.
//
//  Both are cross-platform. An iPad mariner hears the plugins, so they must
//  also be able to see what raised the alarm.

import Foundation

@MainActor
extension ChartController {
    // MARK: - Plugin tables

    /// Every table the loaded plugins declare. The shell builds a menu item
    /// and a window per declaration and knows nothing about the plugins.
    func tableSpecs() -> [PluginTableSpec] {
        guard let h = handle, let read = lookout_tables_read(h) else { return [] }
        defer { lookout_tables_free(read) }
        var n = 0
        guard let all = lookout_tables_all(read, &n) else { return [] }
        return (0..<n).compactMap { i in
            guard let t = all[i] else { return nil }
            var cn = 0
            var columns: [PluginTableColumn] = []
            if let cols = lookout_table_columns(t, &cn) {
                columns = (0..<cn).compactMap { k in cols[k].map { PluginTableColumn($0.pointee) } }
            }
            return PluginTableSpec(t.pointee, columns: columns)
        }
    }

    /// One table's rows, already ordered by the plugin's bands and then by the
    /// column asked for. `seq` moves when the plugin has fed the table since
    /// the last read. `columns` is the declaration's count, so a row that
    /// carried fewer cells than the table has columns still lines up.
    func tableRows(plugin: String, key: String, sortKey: String, ascending: Bool, columns: Int)
        -> (seq: Int, rows: [PluginTableRow])? {
        guard let h = handle else { return nil }
        let read = plugin.withCString { p in
            key.withCString { k in
                sortKey.withCString { s in
                    lookout_table_rows_read(h, p, k, s, ascending ? 1 : 0)
                }
            }
        }
        guard let read else { return nil }
        defer { lookout_table_rows_free(read) }
        var n = 0
        guard let all = lookout_table_rows_all(read, &n) else {
            return (Int(lookout_table_rows_seq(read)), [])
        }
        let rows: [PluginTableRow] = (0..<n).compactMap { i in
            guard let r = all[i] else { return nil }
            var cn = 0
            var cells: [PluginCell] = []
            if let cs = lookout_table_row_cells(r, &cn) {
                cells = (0..<cn).compactMap { k in cs[k].map { PluginCell($0.pointee) } }
            }
            return PluginTableRow(r.pointee, cells: cells, columns: columns)
        }
        return (Int(lookout_table_rows_seq(read)), rows)
    }


    // The alert bridge is cross-platform: an iPad mariner hears the plugins
    // too. The declared-table queries above are macOS-only (they feed NSWindow
    // dialogs), so the guard closes before these and reopens after.

    /// Every alert the plugins have raised, already ordered: what nobody has
    /// answered first, then the loudest, then the oldest. `seq` moves when the
    /// set has changed since the last read.
    func pluginAlerts() -> (seq: Int, alerts: [PluginAlert])? {
        guard let h = handle, let read = lookout_alerts_read(h) else { return nil }
        defer { lookout_alerts_free(read) }
        let seq = Int(lookout_alerts_seq(read))
        var n = 0
        guard let all = lookout_alerts_all(read, &n) else { return (seq, []) }
        return (seq, (0..<n).compactMap { i in all[i].map { PluginAlert($0.pointee) } })
    }

    /// Silence one alert. It stays listed until the condition clears.
    @discardableResult
    func acknowledgeAlert(_ id: UInt64) -> Bool {
        guard let h = handle else { return false }
        return lookout_plugin_alert_ack(h, id) == 0
    }

    /// Tell the plugin its table is on screen, or is not.
    func setTableOpen(plugin: String, key: String, _ open: Bool) {
        guard let h = handle else { return }
        _ = plugin.withCString { p in
            key.withCString { k in lookout_plugin_table_open(h, p, k, open ? 1 : 0) }
        }
        kick()
    }

    /// Put a place at the centre of the chart and hand back whatever plugin
    /// object draws there, for the bubble. Follow is switched off first: a
    /// chart that slides back to own ship a moment later has not shown the
    /// mariner the target they asked for.
    @discardableResult
    func reveal(lon: Double, lat: Double) -> OverlayPin? {
        guard let h = handle else { return nil }
        if lookout_follow_active(h) != 0 { lookout_follow_set(h, 0) }
        var v = currentView
        v.lon = lon
        v.lat = lat
        setView(v)
        // The camera has moved, so the row's own position is the middle of the
        // view: the object under that point is the row's symbol.
        return overlayHit(atPoint: screenPoint(forGeoLon: lon, lat: lat))
    }
}
