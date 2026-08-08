package org.beetlebug.lookout

import org.json.JSONArray
import org.json.JSONObject

/**
 * The plugin settings registry: what `lookout_plugins_json` says, as Kotlin.
 *
 * A shell renders a settings pane from this and knows nothing about what any
 * plugin does — the manifest declares the controls, the core hands back the
 * schema with the values in force, and the pane is a function of the two. This
 * file is the model and the filing; the composables that draw it live in
 * SettingsSheet.kt.
 *
 * The Android counterpart of macOS's PluginSettings.swift, and deliberately the
 * same shape: both read one JSON contract, so a field the core adds appears in
 * both shells by the same route. What differs is only the rendering — Material
 * controls here, AppKit ones there.
 */

/** One control a manifest declares. `number` and `toggle` stand alone; `text` only ever appears in a list row. */
data class PluginField(
    val key: String,
    val label: String,
    /** One sentence on what it does for the person at the helm. Empty when the manifest declares none. */
    val desc: String,
    val kind: Kind,
    val unit: String,
    /** The heading this field sits under. */
    val group: String,
    /** The settings section it lands in — one of [SettingsSection] ids. */
    val tab: String,
    val min: Double,
    val max: Double,
    val defaultValue: Double,
    val defaultText: String,
    val optional: Boolean,
    /** The value in force. A toggle is 0 or 1. */
    val value: Double,
) {
    enum class Kind { NUMBER, TOGGLE, TEXT;
        companion object {
            fun parse(s: String?): Kind? = when (s) {
                "number" -> NUMBER
                "toggle" -> TOGGLE
                "text" -> TEXT
                else -> null
            }
        }
    }

    val on: Boolean get() = value != 0.0
}

/** A repeating group's schema — the NMEA gateways, the Signal K servers. */
data class PluginListSchema(
    val pluginId: String,
    val key: String,
    val group: String,
    val tab: String,
    val itemFields: List<PluginField>,
    val footer: String,
    val empty: String,
    val addLabel: String,
    /** The item field that switches a row on and off, if it has one. */
    val switchKey: String,
)

/** One row in force, its cells keyed by item-field key. */
data class PluginRow(val id: String, val cells: Map<String, String>)

/** One capability a manifest asks for, and whether the mariner left it granted. */
data class PluginCapability(
    val cap: String,
    /** The core's own plain sentence for it, ready to show beside a switch. */
    val sentence: String,
    val hosts: List<String>,
    val granted: Boolean,
)

/**
 * One loaded plugin.
 *
 * [origin] is "bundled", "installed" or "developer". It decides what the
 * plugin-management section may offer: only an `installed` plugin can be
 * uninstalled, and the section lists nothing that is `bundled` — the core set
 * is the product, not a thing the mariner manages.
 */
data class PluginInfo(
    val id: String,
    val name: String,
    val version: String,
    val origin: String,
    val live: Boolean,
    val status: String,
    val capabilities: List<PluginCapability>,
    val fields: List<PluginField>,
    val lists: List<PluginListSchema>,
    val rows: Map<String, List<PluginRow>>,
    val fileTypes: List<String>,
) {
    val bundled: Boolean get() = origin == "bundled"
    val installed: Boolean get() = origin == "installed"
}

/** A plugin's fields that share a heading within one section, kept together. */
data class PluginGroup(
    val pluginId: String,
    val title: String,
    val tab: String,
    val fields: List<PluginField>,
)

/**
 * One entry in the settings screen. `core` sections are the app's own and are
 * always listed; the rest appear only while a plugin schema fills them, so a
 * build whose AIS plugin never came up shows no empty Vessels section.
 *
 * The ids are the CORE's section names (`Tab` in src/plugin/host.zig), so a
 * plugin manifest and the shell mean the same thing by "alarms". Advanced is
 * last: it is where anything unclaimed lands, and the core's own parser falls
 * back to it for a group that names no tab.
 */
data class SettingsSection(val id: String, val label: String, val core: Boolean) {
    companion object {
        val all: List<SettingsSection> = listOf(
            SettingsSection("display", "Display", true),
            SettingsSection("depths", "Depths", true),
            SettingsSection("text", "Text", true),
            SettingsSection("charts", "Charts", true),
            SettingsSection("vessels", "Vessels", false),
            SettingsSection("alarms", "Alarms", false),
            SettingsSection("connections", "Connections", false),
            // Plugins is the one section that talks ABOUT plugins: what is
            // installed, what it may reach, and removing it. The app's own
            // section, not a slot a schema fills.
            SettingsSection("plugins", "Plugins", true),
            SettingsSection("advanced", "Advanced", true),
        )
    }
}

/** Everything the registry says, with the lookups the settings screen needs. */
data class PluginRegistry(val plugins: List<PluginInfo> = emptyList()) {

    /**
     * One plugin's fields for a section, gathered under their headings and in
     * declaration order — the order the manifest chose, which is the order the
     * plugin's author meant them to be read in.
     */
    fun groups(tab: String): List<PluginGroup> {
        val out = mutableListOf<PluginGroup>()
        for (p in plugins) {
            for (f in p.fields.filter { it.tab == tab }) {
                val title = f.group.ifEmpty { p.name }
                val last = out.lastOrNull()
                if (last != null && last.pluginId == p.id && last.title == title) {
                    out[out.size - 1] = last.copy(fields = last.fields + f)
                } else {
                    out.add(PluginGroup(p.id, title, tab, listOf(f)))
                }
            }
        }
        return out
    }

    /** The repeating groups that belong on a section (the gateway lists). */
    fun lists(tab: String): List<PluginListSchema> =
        plugins.flatMap { it.lists }.filter { it.tab == tab }

    /** Which non-core sections have anything in them, and so should be listed. */
    val populatedTabs: Set<String>
        get() = (plugins.flatMap { p -> p.fields.map { it.tab } } +
                 plugins.flatMap { p -> p.lists.map { it.tab } }).toSet()

    /**
     * The plugins the management section lists: what the mariner installed and
     * whatever LOOKOUT_PLUGINS is overriding. Never the bundled set — those ids
     * belong to the application, cannot be uninstalled, and listing them would
     * invite the mariner to manage the chartplotter's own parts.
     */
    val managed: List<PluginInfo> get() = plugins.filterNot { it.bundled }

    /** The sections to show, in order. */
    val sections: List<SettingsSection>
        get() = SettingsSection.all.filter { it.core || populatedTabs.contains(it.id) }

    companion object {
        fun parse(json: String?): PluginRegistry {
            if (json.isNullOrEmpty()) return PluginRegistry()
            return try {
                val list = JSONObject(json).optJSONArray("plugins") ?: return PluginRegistry()
                PluginRegistry((0 until list.length()).mapNotNull { plugin(list.optJSONObject(it)) })
            } catch (e: Exception) {
                PluginRegistry()
            }
        }

        private fun plugin(o: JSONObject?): PluginInfo? {
            if (o == null) return null
            val id = o.optString("id").ifEmpty { return null }
            val lists = o.optJSONArray("lists").objects().mapNotNull { listSchema(it, id) }
            return PluginInfo(
                id = id,
                name = o.optString("name").ifEmpty { id },
                version = o.optString("version"),
                origin = o.optString("origin").ifEmpty { "bundled" },
                live = o.optBoolean("live", false),
                status = o.optString("status"),
                capabilities = o.optJSONArray("capabilities").objects().mapNotNull { capability(it) },
                fields = o.optJSONArray("settings").objects().mapNotNull { field(it) },
                lists = lists,
                rows = rows(o.optJSONArray("lists")),
                fileTypes = o.optJSONArray("file_types").strings(),
            )
        }

        private fun capability(o: JSONObject): PluginCapability? {
            val cap = o.optString("cap").ifEmpty { return null }
            return PluginCapability(
                cap = cap,
                sentence = o.optString("sentence").ifEmpty { cap },
                hosts = o.optJSONArray("hosts").strings(),
                // Absent means granted: a manifest's capability is in force
                // until the mariner switches it off.
                granted = o.optBoolean("granted", true),
            )
        }

        private fun listSchema(o: JSONObject, pluginId: String): PluginListSchema? {
            val key = o.optString("key").ifEmpty { return null }
            return PluginListSchema(
                pluginId = pluginId,
                key = key,
                group = o.optString("group"),
                tab = o.optString("tab").ifEmpty { "advanced" },
                itemFields = o.optJSONArray("item_fields").objects().mapNotNull { field(it) },
                footer = o.optString("footer"),
                empty = o.optString("empty"),
                addLabel = o.optString("add_label"),
                switchKey = o.optString("switch_key"),
            )
        }

        /** The rows in force for every list of one plugin, keyed by list key. */
        private fun rows(lists: JSONArray?): Map<String, List<PluginRow>> {
            val out = mutableMapOf<String, List<PluginRow>>()
            for (l in lists.objects()) {
                val key = l.optString("key")
                if (key.isEmpty()) continue
                val fields = l.optJSONArray("item_fields").objects().mapNotNull { field(it) }
                out[key] = l.optJSONArray("rows").objects().mapNotNull { r ->
                    val id = r.optString("id").ifEmpty { return@mapNotNull null }
                    // Cells are kept as text whatever the field's kind: a row
                    // editor binds them to text controls, and the core clamps
                    // and coerces on the way back in.
                    PluginRow(id, fields.associate { f -> f.key to r.optString(f.key) })
                }
            }
            return out
        }

        private fun field(o: JSONObject): PluginField? {
            val key = o.optString("key").ifEmpty { return null }
            val kind = PluginField.Kind.parse(o.optString("kind")) ?: return null
            // A toggle's value and default are booleans, a number's are
            // numbers, and a text field carries neither — its value lives in
            // the row that holds it.
            val value: Double
            val fallback: Double
            when (kind) {
                PluginField.Kind.TOGGLE -> {
                    value = if (o.optBoolean("value", false)) 1.0 else 0.0
                    fallback = if (o.optBoolean("default", false)) 1.0 else 0.0
                }
                PluginField.Kind.NUMBER -> {
                    value = o.optDouble("value", 0.0).let { if (it.isNaN()) 0.0 else it }
                    fallback = o.optDouble("default", value).let { if (it.isNaN()) value else it }
                }
                PluginField.Kind.TEXT -> { value = 0.0; fallback = 0.0 }
            }
            // A schema that declares no label, description, group or section
            // still renders: the key names the control and Advanced takes it.
            return PluginField(
                key = key,
                label = o.optString("label").ifEmpty { key },
                desc = o.optString("desc"),
                kind = kind,
                unit = o.optString("unit"),
                group = o.optString("group"),
                tab = o.optString("tab").ifEmpty { "advanced" },
                min = o.optDouble("min", 0.0).let { if (it.isNaN()) 0.0 else it },
                max = o.optDouble("max", 1.0).let { if (it.isNaN()) 1.0 else it },
                defaultValue = fallback,
                defaultText = if (kind == PluginField.Kind.TEXT) o.optString("default") else "",
                optional = o.optBoolean("optional", false),
                value = value,
            )
        }

        private fun JSONArray?.objects(): List<JSONObject> =
            if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

        private fun JSONArray?.strings(): List<String> =
            if (this == null) emptyList() else (0 until length()).map { optString(it) }
    }
}
