//  StoreImport.swift — the one-time move out of UserDefaults.
//
//  Everything the shell keeps used to live in the defaults domain, under flat
//  keys. It lives in the core store now, in the groups every shell writes. This
//  copies what a mariner already has across, once, and then the defaults domain
//  is dead: nothing else in the shell reads it.
//
//  It runs before anything reads a setting. A launch that finds the store
//  already stamped does nothing, so the copy happens on the first launch after
//  the change and never again.

import Foundation

extension Store {
    /// Set once the copy has run. It lives in the view group because the view
    /// group is the one a store always ends up with.
    private static let stampGroup = Store.Group.view
    private static let stampKey = "imported"

    /// Copy what UserDefaults holds into this store, once.
    func importDefaults(_ defaults: UserDefaults = .standard) {
        if bool(Self.stampGroup, Self.stampKey) == true { return }
        set(true, Self.stampGroup, Self.stampKey)

        // The pose, which was one dictionary.
        if let d = defaults.dictionary(forKey: "chart.view") {
            for (from, to) in [("lon", "lon"), ("lat", "lat"), ("zoom", "zoom"),
                               ("rotationDeg", "rotation_deg")] {
                if let v = d[from] as? Double { set(v, Store.Group.view, to) }
            }
        }

        // The mariner settings, which were another. Every key keeps its name.
        if let d = defaults.dictionary(forKey: "mariner.v1") {
            for (k, v) in d {
                if let s = v as? String { set(s, Store.Group.mariner, k) }
                else if let b = v as? Bool { set(b, Store.Group.mariner, k) }
                else if let n = v as? NSNumber { set(n.doubleValue, Store.Group.mariner, k) }
            }
        }

        copyList(defaults, "lookout.recents", Store.Group.recents, "paths")
        copyList(defaults, "lookout.rastercharts", Store.Group.raster, "paths")
        copyList(defaults, "lookout.rastercharts.off", Store.Group.raster, "off")
        copyList(defaults, "lookout.rastercharts.hidden", Store.Group.raster, "hidden")
        copyFlag(defaults, "lookout.chart.hidden", Store.Group.raster, "chart_hidden")
        copyList(defaults, "lookout.chartsets", Store.Group.chartsets, "paths")
        copyList(defaults, "lookout.chartsets.off", Store.Group.chartsets, "off")
        copyFlag(defaults, "lookout.chartsets.rastermigrated",
                 Store.Group.chartsets, "raster_migrated")

        importPluginConfigs(defaults)
    }

    private func copyList(_ d: UserDefaults, _ from: String, _ group: String, _ key: String) {
        guard let v = d.stringArray(forKey: from), !v.isEmpty else { return }
        set(v, group, key)
    }

    private func copyFlag(_ d: UserDefaults, _ from: String, _ group: String, _ key: String) {
        guard d.object(forKey: from) != nil else { return }
        set(d.bool(forKey: from), group, key)
    }

    /// The plugin settings were two dictionaries: the field values by plugin
    /// and field key, and the list rows by plugin and list key. The store keeps
    /// one config object per plugin now, so the two are joined back into the
    /// object the plugin was handed.
    private func importPluginConfigs(_ d: UserDefaults) {
        let fields = d.dictionary(forKey: "plugins.v1") ?? [:]
        let lists = d.dictionary(forKey: "plugins.lists.v1") ?? [:]
        var ids = Set(fields.keys)
        ids.formUnion(lists.keys)
        for id in ids.sorted() {
            var body: [String] = []
            if let one = fields[id] as? [String: Double] {
                for k in one.keys.sorted() { body.append("\"\(k)\":\(one[k]!)") }
            }
            if let rows = lists[id] as? [String: String] {
                for k in rows.keys.sorted() { body.append("\"\(k)\":\(rows[k]!)") }
            }
            if body.isEmpty { continue }
            set("{" + body.joined(separator: ",") + "}", Store.Group.plugins, id)
        }
    }
}
