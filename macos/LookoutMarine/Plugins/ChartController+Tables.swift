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
        guard let h = handle else { return [] }
        var len = 0
        guard let raw = lookout_plugin_tables_json(h, &len), len > 0 else { return [] }
        // Borrowed until the next plugin query, so decode before anything else
        // runs.
        let data = Data(bytes: raw, count: len)
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["tables"] as? [[String: Any]] else { return [] }
        return list.compactMap { PluginTableSpec($0) }
    }

    /// One table's rows, already ordered by the plugin's bands and then by the
    /// column asked for. `seq` moves when the plugin has fed the table since
    /// the last read. `columns` is the declaration's count, so a row that
    /// carried fewer cells than the table has columns still lines up.
    func tableRows(plugin: String, key: String, sortKey: String, ascending: Bool, columns: Int)
        -> (seq: Int, rows: [PluginTableRow])? {
        guard let h = handle else { return nil }
        var len = 0
        let raw = plugin.withCString { p in
            key.withCString { k in
                sortKey.withCString { s in
                    lookout_plugin_table_rows(h, p, k, s, ascending ? 1 : 0, &len)
                }
            }
        }
        guard let raw, len > 0 else { return nil }
        let data = Data(bytes: raw, count: len)
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["rows"] as? [[String: Any]] else { return nil }
        let rows = list.compactMap { PluginTableRow($0, columns: columns) }
        return (top["seq"] as? Int ?? 0, rows)
    }


    // The alert bridge is cross-platform: an iPad mariner hears the plugins
    // too. The declared-table queries above are macOS-only (they feed NSWindow
    // dialogs), so the guard closes before these and reopens after.

    /// Every alert the plugins have raised, already ordered: what nobody has
    /// answered first, then the loudest, then the oldest. `seq` moves when the
    /// set has changed since the last read.
    func pluginAlerts() -> (seq: Int, alerts: [PluginAlert])? {
        guard let h = handle else { return nil }
        var len = 0
        guard let raw = lookout_plugin_alerts_json(h, &len), len > 0 else { return nil }
        // Borrowed until the next plugin query, so decode before anything else
        // runs.
        let data = Data(bytes: raw, count: len)
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["alerts"] as? [[String: Any]] else { return nil }
        return (top["seq"] as? Int ?? 0, list.compactMap { PluginAlert($0) })
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
