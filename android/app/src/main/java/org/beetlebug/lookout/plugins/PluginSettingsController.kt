package org.beetlebug.lookout.plugins

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.engine.EngineAccess

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File

/**
 * Everything about the plugins the mariner can see and change: what is loaded,
 * what each one declares, the values in force, the grants, and installing and
 * removing one.
 *
 * THE CORE IS AUTHORITATIVE. Every write goes straight to it and the registry
 * is re-read, because the core clamps a number to the range the schema
 * published and drops a key the schema does not declare — so the value that
 * comes back is the value in force, which is not always the one asked for.
 *
 * `onTables` is how the declared tables follow the loaded set: they ride the
 * same registry refresh, so a plugin that unloads takes its table with it.
 */
class PluginSettingsController(
    private val appContext: Context,
    private val access: EngineAccess,
    private val onTables: (List<TableSpec>) -> Unit,
) {

    /**
     * Where the wasm plugin set was extracted to (filesDir/plugins), or null in
     * a build that ships none. Set by the Activity before the first surface, so
     * it is written once on the main thread and read on the render thread.
     */
    @Volatile var pluginDir: String? = null

    /** "host:port" for the NMEA source, from the launch intent. */
    @Volatile var nmeaAddress: String? = null

    /**
     * The plugin settings registry — every loaded plugin with its schema and
     * the values in force. What the settings screen renders its plugin-declared
     * sections from; empty until the layer is up, and re-read whenever a change
     * is applied, since the core answers with the values as clamped.
     */
    var pluginRegistry by mutableStateOf(PluginRegistry())
        private set

    /** Re-read the registry from the core. Safe to call on any thread. */
    fun refreshPlugins() = access.onEngine { l -> republish(l) }

    /**
     * Apply one plugin's settings and re-read the registry, because the core
     * clamps a number outside its range and ignores a key the schema does not
     * declare — so what the mariner asked for is not always what is in force.
     */
    fun setPluginConfig(id: String, json: String) = access.onEngine { l ->
        if (!l.pluginConfigSet(id, json)) Log.w(TAG, "plugin config refused: $id $json")
        republish(l)
    }

    /**
     * Apply one scalar field and persist it, so an alarm range raised at the
     * helm survives the next launch and the next library switch. Lists have
     * [setPluginList]; this is their twin for toggles and numbers.
     */
    fun setPluginScalar(pluginId: String, field: PluginField, value: Double) {
        PluginPrefs.saveScalar(appContext, pluginId, field.key, value)
        val body = org.json.JSONObject()
            .put(field.key, if (field.kind == PluginField.Kind.TOGGLE) value != 0.0 else value)
            .toString()
        setPluginConfig(pluginId, body)
    }

    /**
     * Replace one repeating list whole and persist it — the shape the core takes
     * (see `normalizeRows` in src/plugin/host.zig): every edit sends the entire
     * array, and what comes back is what is in force after the host clamped it.
     *
     * Saved as well as sent, because a gateway typed at the helm has to survive
     * the next launch.
     */
    fun setPluginList(list: PluginListSchema, rows: List<PluginRow>) {
        val json = list.rowsJson(rows)
        PluginPrefs.saveRows(appContext, list, json)
        setPluginConfig(list.pluginId, org.json.JSONObject().put(list.key, org.json.JSONArray(json)).toString())
    }

    /**
     * Re-read the registry and publish it, but only when the JSON actually
     * moved. The settings screen polls this at 1 Hz for the connection lines,
     * and republishing an identical registry would recompose the whole pane on
     * every tick.
     *
     * RENDER THREAD only: [lastPluginsJson] is its own.
     */
    /**
     * Republish into a registry nobody has seen. A new Activity over a process
     * that kept running has already-loaded plugins and no registry of its own.
     * RENDER THREAD.
     */
    fun forgetLastRegistry() {
        lastRegistry = null
    }

    private var lastRegistry: PluginRegistry? = null
    private var registryUnread = false

    fun republish(l: Lookout) {
        val reg = PluginRegistry.read(l)
        if (reg == null) {
            // No snapshot is the plugin layer mid-restart. An empty registry
            // here empties Vessels, Alarms and Connections until the next good
            // read, so keep the last one and log it once each way.
            if (!registryUnread) Log.w(TAG, "plugins registry unreadable; keeping the last one")
            registryUnread = true
            return
        }
        if (registryUnread) {
            Log.w(TAG, "plugins registry is back")
            registryUnread = false
        }
        if (reg == lastRegistry) return
        lastRegistry = reg
        // The declared tables ride the same refresh: they follow the loaded
        // set, so a plugin that unloads takes its table with it.
        val specs = parseTableSpecs(l.pluginTables())
        access.onMain {
            pluginRegistry = reg
            onTables(specs)
        }
    }

    // ---- live plugin status -------------------------------------------------
    //
    // A connection's line has to move on its own: "Reconnecting" that never
    // becomes "Connected" is how a mariner learns the address is wrong. The
    // plugins rebuild their status every two seconds; this samples it while the
    // settings screen is on, and stops when it closes.

    @Volatile private var polling = false

    private val pollTick = object : Runnable {
        override fun run() {
            if (!polling) return
            refreshPlugins()
            access.postMainDelayed(PLUGIN_POLL_MS, this)
        }
    }

    fun startPluginPolling() {
        if (polling) return
        polling = true
        access.postMain(pollTick)
    }

    fun stopPluginPolling() {
        polling = false
        access.cancelMain(pollTick)
    }

    /**
     * Bring the wasm plugin layer up on the chart just opened. Like the raster
     * charts above this runs on every open, not once: the layer belongs to the
     * engine handle, and switching chart library makes a new one.
     *
     * The set is the one LookoutActivity extracted out of the APK assets, loaded
     * through the ordinary directory call — nothing sets LOOKOUT_PLUGINS here,
     * so the host files them as `bundled` and the ids belong to the application.
     */
    fun loadPlugins(l: Lookout) {
        val dir = pluginDir ?: return
        // Android's files dir has no path in the environment, so the core
        // cannot resolve an install root itself. Before the layer comes up.
        l.pluginsInstallRoot(File(appContext.filesDir, "plugins").absolutePath)
        if (!l.pluginsLoad(dir)) {
            Log.w(TAG, "plugins: none loaded from $dir (no host in this build?)")
            return
        }
        // Then the set the mariner installed: bundled first, installed after,
        // so on an id collision the application's copy wins (the documented
        // precedence every shell follows).
        l.pluginsLoadInstalled()
        // What actually came up, by id — the answer to "did the module load"
        // that a screenshot cannot give.
        val loadedReg = PluginRegistry.read(l) ?: PluginRegistry()
        Log.i(TAG, "plugins: active=${l.pluginsActive()} ${summarize(loadedReg)}")
        val restored = restoreLists(l, loadedReg)
        restoreScalars(l, loadedReg)
        // The developer override, and only where the mariner has said nothing:
        // a list they have edited is the truth, empty or not.
        nmeaAddress?.let { addr ->
            if (restored.contains("org.beetlebug.nmea0183/connections")) {
                Log.i(TAG, "plugins: -e nmea ignored; the saved connection list wins")
            } else {
                configureNmea(l, addr)
            }
        }
        // After the restore, so the registry the settings screen first sees
        // already holds the mariner's own connections.
        val reg = PluginRegistry.read(l) ?: PluginRegistry()
        Log.i(
            TAG,
            "plugins: sections ${reg.sections.joinToString(", ") { it.id }}" +
                " | managed ${reg.managed.size} of ${reg.plugins.size}",
        )
        lastRegistry = reg
        access.onMain { pluginRegistry = reg }
    }

    /**
     * Push the mariner's saved connection lists into the plugins that just came
     * up, and answer which lists had one. Like the raster charts, this runs on
     * every open: the plugin layer belongs to the engine handle, and a new chart
     * library makes a new one with the manifests' defaults back in place.
     *
     * A saved list REPLACES whatever the host seeded, which is what makes the
     * editor authoritative over the launch intent.
     */
    private fun restoreLists(l: Lookout, reg: PluginRegistry): Set<String> {
        val done = mutableSetOf<String>()
        for (p in reg.plugins) {
            for (list in p.lists) {
                val saved = PluginPrefs.savedRows(appContext, list) ?: continue
                val body = org.json.JSONObject()
                    .put(list.key, org.json.JSONArray(saved))
                    .toString()
                val ok = l.pluginConfigSet(p.id, body)
                Log.i(TAG, "plugins: ${p.id}/${list.key} restored ${if (ok) "ok" else "REFUSED"}")
                if (ok) done.add("${p.id}/${list.key}")
            }
        }
        return done
    }

    /**
     * Push the mariner's saved toggles and numbers back into the plugins that
     * just came up, one composed body per plugin. Runs on every open for the
     * same reason [restoreLists] does: a new engine handle starts from the
     * manifests' defaults. The live schema decides each field's JSON shape —
     * a toggle must arrive as a bool — and a key the schema no longer declares
     * is dropped by the core on the way in.
     */
    private fun restoreScalars(l: Lookout, reg: PluginRegistry) {
        val saved = PluginPrefs.savedScalars(appContext)
        if (saved.isEmpty()) return
        for (p in reg.plugins) {
            val body = org.json.JSONObject()
            for (f in p.fields) {
                val v = saved["${p.id}/${f.key}"] ?: continue
                when (f.kind) {
                    PluginField.Kind.TOGGLE -> body.put(f.key, v != 0.0)
                    PluginField.Kind.NUMBER -> body.put(f.key, v)
                    else -> {}
                }
            }
            if (body.length() == 0) continue
            val ok = l.pluginConfigSet(p.id, body.toString())
            Log.i(TAG, "plugins: ${p.id} scalars restored ${if (ok) "ok" else "REFUSED"}")
        }
    }

    /**
     * Point the NMEA 0183 source at one gateway from the launch intent:
     *
     *     adb shell am start -n … -e nmea 127.0.0.1:10110
     *
     * DEVELOPER ONLY. The mariner's route is Settings › Connections, which
     * writes the same list and persists it; this only seeds a machine that has
     * never had a connection typed into it, so a test rig can come up pointing
     * at a replay without anybody touching the screen. It never overrides a
     * saved list — see the caller.
     */
    private fun configureNmea(l: Lookout, addr: String) {
        val host = addr.substringBeforeLast(':', addr)
        val port = addr.substringAfterLast(':', "").toIntOrNull() ?: 10110
        val row = """{"connections":[{"id":"adb","name":"","host":"$host","port":$port,"enabled":true}]}"""
        val ok = l.pluginConfigSet("org.beetlebug.nmea0183", row)
        Log.i(TAG, "plugins: -e nmea (developer) -> $host:$port ${if (ok) "set" else "REFUSED"}")
    }

    /**
     * The loaded ids out of the plugins JSON. Parsed rather than pattern
     * matched: a plugin's settings can carry list ROWS with their own "id", and
     * scanning the text for one reported a gateway row ("lookout-nmea") as
     * though it were a sixth plugin.
     */
    private fun summarize(reg: PluginRegistry): String =
        if (reg.plugins.isEmpty()) "(none loaded)"
        else "loaded: ${reg.plugins.joinToString(", ") { it.id }}"

    /** What the source plugins' connection rows say between them. */
    data class Connections(val live: Boolean, val trying: Boolean)

    /**
     * `live` is a session actually open to a gateway; `trying` also covers the
     * ones being dialled,
     * which is the difference between a boat under way and one whose gateway is
     * switched off. A paused, address-less or refused row is neither.
     *
     * The core walks its own registry for this. Building it here to read a
     * handful of strings was, on the background path, the only work the
     * process did, once a second, for as long as the app was away.
     *
     * RENDER THREAD: the native call takes the api lock.
     */
    fun connections(l: Lookout): Connections {
        val bits = l.pluginsConnectionState()
        return Connections(live = bits and 1 != 0, trying = bits and 2 != 0)
    }

    //
    // NOTHING IS INSTALLED BEFORE ITS PERMISSIONS ARE SHOWN. The sentences
    // come from the core, so every shell shows the same words.

    /** What the consent sheet shows for a .lkplug the mariner picked. */
    data class PluginPackage(
        val path: String,
        val id: String,
        val name: String,
        val version: String,
        val sentences: List<String>,
        val installedVersion: String?,
        val installedOrigin: String?,
        val adds: List<String>,
        val drops: List<String>,
        val downgrade: Boolean,
    )

    var pluginConsent by mutableStateOf<PluginPackage?>(null)
        private set

    /** One sentence from the core, ready to show. */
    var installError by mutableStateOf<String?>(null)

    /**
     * A file another app opened into us, by NAME: a .lkplug is a plugin
     * package and goes to the consent sheet; anything else is offered to the
     * plugins, which take what they already claim (a GPX to a route plugin).
     *
     * A file that arrives BEFORE the engine is up — the usual case, since an
     * opened file often launches the app — is parked and routed again the
     * moment the open finishes.
     */
    fun openFile(path: String) {
        if (!access.isOpen) {
            synchronized(pendingOpenFiles) { pendingOpenFiles.add(path) }
            return
        }
        if (path.endsWith(".lkplug", ignoreCase = true)) {
            beginPluginInstall(path)
            return
        }
        access.onEngine { l ->
            when (l.openFile(path)) {
                1 -> Log.i(TAG, "opened file taken by a plugin: $path")
                -1 -> Log.w(TAG, "opened file claimed but not taken: $path")
                else -> Log.i(TAG, "opened file claimed by nothing: $path")
            }
        }
    }

    private val pendingOpenFiles = mutableListOf<String>()

    /** Route what arrived while there was no engine. Main thread, post-attach. */
    fun drainOpenFiles() {
        val parked = synchronized(pendingOpenFiles) {
            val copy = pendingOpenFiles.toList()
            pendingOpenFiles.clear()
            copy
        }
        for (p in parked) openFile(p)
    }

    fun beginPluginInstall(path: String) = access.onEngine { l ->
        val json = l.pluginInspect(path)
        if (json == null) {
            access.onMain { installError = "The plugin layer could not start." }
            return@onEngine
        }
        try {
            val o = org.json.JSONObject(json)
            val err = o.optString("error")
            if (err.isNotEmpty()) {
                access.onMain { installError = err }
                return@onEngine
            }
            fun arr(a: org.json.JSONArray?): List<String> =
                if (a == null) emptyList() else List(a.length()) { a.optString(it) }
            val inst = o.optJSONObject("installed")
            val pkg = PluginPackage(
                path = path,
                id = o.optString("id"),
                name = o.optString("name"),
                version = o.optString("version"),
                sentences = arr(o.optJSONArray("sentences")),
                installedVersion = inst?.optString("version"),
                installedOrigin = inst?.optString("origin"),
                adds = arr(inst?.optJSONArray("adds")),
                drops = arr(inst?.optJSONArray("drops")),
                downgrade = inst?.optBoolean("downgrade") ?: false,
            )
            access.onMain { pluginConsent = pkg }
        } catch (e: Exception) {
            access.onMain { installError = "That file is not a plugin package." }
        }
    }

    /** The Install button; nothing touched disk before this. */
    fun confirmPluginInstall() {
        val pkg = pluginConsent ?: return
        pluginConsent = null
        access.onEngine { l ->
            val msg = l.pluginInstall(pkg.path)
            if (msg != null) access.onMain { installError = msg }
            republish(l)
        }
    }

    fun cancelPluginInstall() {
        pluginConsent = null
    }

    fun dismissInstallError() {
        installError = null
    }

    fun uninstallPlugin(id: String) = access.onEngine { l ->
        if (!l.pluginUninstall(id)) Log.w(TAG, "uninstall refused: $id")
        republish(l)
    }

    /** A live grant flip; the registry re-read carries the new truth. */
    fun setPluginGrant(id: String, cap: String, on: Boolean) = access.onEngine { l ->
        if (!l.pluginGrantSet(id, cap, on)) Log.w(TAG, "grant flip refused: $id/$cap")
        republish(l)
    }

    private companion object {
        const val TAG = "lookout"

        /**
         * How often the settings screen re-reads the plugin status. The plugins
         * rebuild theirs every two seconds, so this is twice their cadence:
         * fast enough that a rate never looks stuck, and the republish is
         * skipped whenever nothing changed.
         */
        const val PLUGIN_POLL_MS = 1_000L
    }
}
