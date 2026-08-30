//  ChartController+Plugins.swift — the plugin surface the shell reaches.
//
//  Settings, the consent flow, install and uninstall, and the grants. The app
//  knows nothing about what a plugin is for, only what it declared.

import Foundation

@MainActor
extension ChartController {
    // MARK: - Plugin settings

    /// Every loaded plugin with its settings schema, as JSON. The settings pane
    /// renders straight from this: the app knows nothing about what a plugin is
    /// for, only what controls it asked for.
    func pluginsJSON() -> String? {
        guard let h = handle else { return nil }
        var len = 0
        guard let p = lookout_plugins_json(h, &len), len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }

    /// One plugin's settings object, or nil when the id is not loaded.
    func pluginConfigJSON(_ id: String) -> String? {
        guard let h = handle else { return nil }
        var len = 0
        guard let p = lookout_plugin_config_get(h, id, &len), len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }

    /// Offer a file the mariner opened to the plugins. True when one claims
    /// that file type and now holds the file.
    ///
    /// False for a chart, for a type nobody claims, and for a build with no
    /// plugin layer — so the caller has one fallback, not three.
    func openFileForPlugins(_ path: String) -> Bool {
        guard let h = handle else { return false }
        let took = lookout_open_file(h, path) == 1
        if took { kick() }
        return took
    }

    /// Push settings to a plugin. Applied live — the plugin redraws inside the
    /// call, so the chart is kicked to show it.
    @discardableResult
    func setPluginConfig(_ id: String, _ json: String) -> Bool {
        guard let h = handle else { return false }
        let ok = lookout_plugin_config_set(h, id, json) == 0
        if ok { kick() }
        return ok
    }

    // MARK: - Plugin install and consent

    /// The plugin set that travels inside the app: Contents/Resources/Plugins,
    /// filled by the "Bundle the core plugins" build phase out of
    /// zig-out/plugins-bundled. Loaded through the ordinary directory call, so
    /// the host gives it origin `bundled`: anything that is not the directory
    /// LOOKOUT_PLUGINS names is bundled by definition.
    ///
    /// False when the app carries no such directory, which is a build without
    /// the phase, not a mariner's problem: the log says so and the installed
    /// set still loads.
    @discardableResult
    func loadBundledPlugins() -> Bool {
        guard let h = handle,
              let dir = Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.path)
        else {
            lkLog("no bundled plugins in this build (Resources/Plugins is absent)")
            return false
        }
        return lookout_plugins_load(h, dir.path) == 0
    }

    /// Load the installed plugin set — what Install put under Application
    /// Support — creating the plugin layer when the environment brought none.
    @discardableResult
    func loadInstalledPlugins() -> Bool {
        guard let h = handle else { return false }
        return lookout_plugins_load_installed(h) == 0
    }

    /// Everything the consent sheet shows for a .lkplug, as JSON, without
    /// installing it. Nil only when no plugin layer can come up.
    func inspectPlugin(_ path: String) -> String? {
        guard let h = handle else { return nil }
        var len = 0
        guard let p = lookout_plugin_inspect(h, path, &len), len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }

    /// Install a consented .lkplug. Nil on success — the plugin is already
    /// drawing — else the one sentence to show the mariner.
    func installPlugin(_ path: String) -> String? {
        guard let h = handle else { return "Open a chart before installing a plugin." }
        guard let err = lookout_plugin_install(h, path) else {
            kick()
            return nil
        }
        return String(cString: err)
    }

    /// Remove an installed plugin and everything it owns. False for a bundled
    /// or developer plugin, which install never wrote.
    @discardableResult
    func uninstallPlugin(_ id: String) -> Bool {
        guard let h = handle else { return false }
        let ok = lookout_plugin_uninstall(h, id) == 0
        if ok { kick() }
        return ok
    }

    /// Switch one granted capability on or off, live. The plugin keeps
    /// running; a revoked capability simply answers it -1 from here on.
    @discardableResult
    func setPluginGrant(_ id: String, _ cap: String, _ on: Bool) -> Bool {
        guard let h = handle else { return false }
        let ok = lookout_plugin_grant_set(h, id, cap, on ? 1 : 0) == 0
        if ok { kick() }
        return ok
    }
}
