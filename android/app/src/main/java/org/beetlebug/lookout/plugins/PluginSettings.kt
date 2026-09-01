package org.beetlebug.lookout.plugins


import org.beetlebug.lookout.Lookout
import org.json.JSONArray
import org.json.JSONObject

/**
 * The plugin settings registry: what `lookout_plugins_read` states, as Kotlin.
 *
 * A shell renders a settings pane from this and knows nothing about what any
 * plugin does — the manifest declares the controls, the core hands back the
 * schema with the values in force, and the pane is a function of the two. This
 * file is the model and the filing; the composables that draw it live in
 * SettingsSheet.kt.
 *
 * The Android counterpart of macOS's PluginSettings.swift, and deliberately the
 * same shape: both read one typed contract, so a field the core adds appears in
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
/**
 * One DNS-SD service a list is browsed for. [set] is the columns a discovered
 * row takes beyond its name, address and port: a Signal K server announces its
 * websocket, so a row added from one arrives with that column on. The values
 * are text, like every other cell this shell holds.
 */
data class PluginDiscover(val service: String, val set: Map<String, String>)

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
    /**
     * What a shell browses the boat's network for on this list's behalf, so a
     * source already running can be added without typing its address.
     */
    val discover: List<PluginDiscover>,
    /**
     * How many rows the HOST will keep. Anything past it is dropped on the way
     * in, so the editor stops offering Add at the cap rather than letting the
     * mariner type a ninth gateway that silently never connects.
     */
    val maxRows: Int,
) {
    /** The switch column: the one the manifest named, else the first toggle. */
    val switchField: PluginField?
        get() = itemFields.firstOrNull { it.key == switchKey && it.kind == PluginField.Kind.TOGGLE }
            ?: itemFields.firstOrNull { it.kind == PluginField.Kind.TOGGLE }

    /**
     * The three columns a row's summary line is built from, found by what the
     * schema DECLARES rather than by name: the optional text column is the
     * mariner's own label for the row, the required one is the address, and the
     * first number is the port. A plugin that declares a different shape still
     * renders — the summary just falls back to whatever it does declare.
     */
    val nameField: PluginField?
        get() = itemFields.firstOrNull { it.kind == PluginField.Kind.TEXT && it.optional }
    val addressField: PluginField?
        get() = itemFields.firstOrNull { it.kind == PluginField.Kind.TEXT && !it.optional }
    val portField: PluginField?
        get() = itemFields.firstOrNull { it.kind == PluginField.Kind.NUMBER }

    /**
     * The columns a plugin declared BEYOND the standard four — Signal K's
     * WebSocket flag is the first. They are rendered from their kind and their
     * label like any other control, so a manifest that adds one needs no shell
     * change.
     */
    val extraFields: List<PluginField>
        get() = itemFields.filter {
            it != nameField && it != addressField && it != portField && it != switchField
        }
}

/**
 * One row in force, its cells keyed by item-field key.
 *
 * Cells are TEXT whatever the column's kind: a row editor binds them to text
 * controls, and [PluginListSchema.rowsJson] types them again on the way back to
 * the core, which clamps and coerces whatever it is sent.
 */
data class PluginRow(val id: String, val cells: Map<String, String>) {
    fun text(key: String): String = cells[key].orEmpty()

    /** A toggle cell. The core writes JSON booleans; "1" is taken too. */
    fun on(key: String): Boolean = cells[key] == "true" || cells[key] == "1"
}

/**
 * What the plugin says ONE row is doing, echoed back under the id the shell
 * assigned when it added the row. See `plugins/common/conn.zig`, which is where
 * every connection-holding plugin gets these from.
 */
data class PluginStatusItem(val id: String, val state: String, val detail: String) {
    /** "Connected · 44 msg/s". */
    val line: String
        get() {
            val word = words[state] ?: state.ifEmpty { "Waiting" }
            return if (detail.isEmpty()) word else "$word · $detail"
        }

    /**
     * How the line should read at a glance. The shell maps these to Material
     * colours; the meanings are the plugin's.
     */
    enum class Tone { GOOD, TRYING, BAD, OFF }

    val tone: Tone
        get() = when (state) {
            "connected" -> Tone.GOOD
            "paused" -> Tone.OFF
            "reconnecting" -> Tone.TRYING
            "" -> Tone.OFF
            else -> Tone.BAD // unreachable, refused, no_address
        }

    private companion object {
        val words = mapOf(
            "connected" to "Connected",
            "paused" to "Paused",
            "reconnecting" to "Reconnecting",
            "unreachable" to "Unreachable",
            "refused" to "Refused",
            "no_address" to "No address",
        )
    }
}

/** One capability a manifest asks for, and whether the mariner left it granted. */
data class PluginCapability(
    val cap: String,
    /** The core's own plain sentence for it, ready to show beside a switch. */
    val sentence: String,
    /**
   * The addresses a grant reaches, or the topics it publishes on. The core
   * writes them so a shell can show the reach beside the sentence; no shell
   * does, this one included. Kept because the gap is a decision nobody has
   * made rather than a field nobody wants, and deleting it would hide that.
   * The same is true of a capability's `ports`, and of a settings field's
   * `placeholder` and `max_len`, none of which are read here.
   */
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
    val status: String,
    val capabilities: List<PluginCapability>,
    val fields: List<PluginField>,
    val lists: List<PluginListSchema>,
    val rows: Map<String, List<PluginRow>>,
    /**
     * What the plugin says about each row of its lists, by row id. Decoded from
     * [status], which is a JSON line the plugin wrote:
     * `{"state":…,"detail":…,"items":[{"id":…,"state":…,"detail":…},…]}`.
     */
    val statusItems: Map<String, PluginStatusItem> = emptyMap(),
) {
    val bundled: Boolean get() = origin == "bundled"
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

    /** The rows of one list, as the core holds them. */
    fun rows(list: PluginListSchema): List<PluginRow> =
        plugins.firstOrNull { it.id == list.pluginId }?.rows?.get(list.key).orEmpty()

    /** The plugin's line for one row: what that connection is doing now. */
    fun status(list: PluginListSchema, rowId: String): PluginStatusItem? =
        plugins.firstOrNull { it.id == list.pluginId }?.statusItems?.get(rowId)

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

        /**
         * The registry as the core states it, read typed.
         *
         * A READ OF NULL IS NOT AN EMPTY REGISTRY. The core returns no snapshot
         * with no chart open and in a build with the plugin layer compiled out;
         * a core holding no plugins returns a snapshot with no rows. A caller
         * that reads the two the same way empties the whole settings screen the
         * moment one read comes back short.
         */
        fun read(l: Lookout): PluginRegistry? {
            val p = l.pluginsRead()
            if (p == 0L) return null
            try {
                val n = Lookout.pluginCount(p)
                return PluginRegistry((0 until n).mapNotNull { plugin(p, it) })
            } finally {
                Lookout.pluginsFree(p)
            }
        }

        private fun plugin(p: Long, i: Int): PluginInfo? {
            val id = Lookout.pluginText(p, i, TEXT_ID).ifEmpty { return null }
            val status = Lookout.pluginText(p, i, TEXT_STATUS)
            val settings = (0 until Lookout.settingCount(p, i))
            return PluginInfo(
                id = id,
                name = Lookout.pluginText(p, i, TEXT_NAME).ifEmpty { id },
                version = Lookout.pluginText(p, i, TEXT_VERSION),
                origin = ORIGINS.getOrElse(Lookout.pluginInt(p, i, INT_ORIGIN)) { "bundled" },
                status = status,
                capabilities = (0 until Lookout.capCount(p, i)).map { capability(p, i, it) },
                fields = settings.mapNotNull { field(p, i, it, -1) },
                lists = settings.mapNotNull { listSchema(p, i, it, id) },
                rows = settings.mapNotNull { rowsOf(p, i, it) }.toMap(),
                statusItems = statusItems(status),
            )
        }

        private fun capability(p: Long, i: Int, c: Int): PluginCapability {
            val cap = Lookout.capText(p, i, c, TEXT_CAP_NAME)
            return PluginCapability(
                cap = cap,
                sentence = Lookout.capText(p, i, c, TEXT_CAP_SENTENCE).ifEmpty { cap },
                hosts = Lookout.capAllows(p, i, c).toList(),
                granted = Lookout.capGranted(p, i, c),
            )
        }

        /** One setting as a control, or null when it is a list. */
        private fun field(p: Long, i: Int, s: Int, fi: Int): PluginField? {
            val key = Lookout.settingText(p, i, s, fi, TEXT_KEY).ifEmpty { return null }
            val kind = when (Lookout.settingInt(p, i, s, fi, INT_KIND)) {
                KIND_NUMBER -> PluginField.Kind.NUMBER
                KIND_TOGGLE -> PluginField.Kind.TOGGLE
                KIND_TEXT -> PluginField.Kind.TEXT
                else -> return null
            }
            return PluginField(
                key = key,
                label = Lookout.settingText(p, i, s, fi, TEXT_LABEL).ifEmpty { key },
                desc = Lookout.settingText(p, i, s, fi, TEXT_DESC),
                kind = kind,
                unit = Lookout.settingText(p, i, s, fi, TEXT_UNIT),
                group = Lookout.settingText(p, i, s, fi, TEXT_GROUP),
                tab = tabOf(Lookout.settingInt(p, i, s, fi, INT_SECTION)),
                min = Lookout.settingNumber(p, i, s, fi, NUM_MIN),
                max = Lookout.settingNumber(p, i, s, fi, NUM_MAX),
                defaultValue = Lookout.settingNumber(p, i, s, fi, NUM_DEFAULT),
                defaultText = if (kind == PluginField.Kind.TEXT)
                    Lookout.settingText(p, i, s, fi, TEXT_DEFAULT_TEXT) else "",
                optional = Lookout.settingInt(p, i, s, fi, INT_OPTIONAL) != 0,
                value = Lookout.settingNumber(p, i, s, fi, NUM_VALUE),
            )
        }

        /** One setting as a repeating group, or null when it is a control. */
        private fun listSchema(p: Long, i: Int, s: Int, pluginId: String): PluginListSchema? {
            if (Lookout.settingInt(p, i, s, -1, INT_KIND) != KIND_LIST) return null
            val key = Lookout.settingText(p, i, s, -1, TEXT_KEY).ifEmpty { return null }
            return PluginListSchema(
                pluginId = pluginId,
                key = key,
                group = Lookout.settingText(p, i, s, -1, TEXT_GROUP),
                tab = tabOf(Lookout.settingInt(p, i, s, -1, INT_SECTION)),
                itemFields = itemFields(p, i, s),
                footer = Lookout.settingText(p, i, s, -1, TEXT_FOOTER),
                empty = Lookout.settingText(p, i, s, -1, TEXT_EMPTY),
                addLabel = Lookout.settingText(p, i, s, -1, TEXT_ADD_LABEL),
                switchKey = Lookout.settingText(p, i, s, -1, TEXT_SWITCH_KEY),
                discover = discover(p, i, s),
                maxRows = Lookout.settingInt(p, i, s, -1, INT_MAX_ITEMS),
            )
        }

        private fun itemFields(p: Long, i: Int, s: Int): List<PluginField> =
            (0 until Lookout.settingFieldCount(p, i, s)).mapNotNull { field(p, i, s, it) }

        private fun discover(p: Long, i: Int, s: Int): List<PluginDiscover> =
            Lookout.services(p, i, s).mapIndexed { sv, service ->
                PluginDiscover(service, pairs(Lookout.serviceSet(p, i, s, sv)))
            }

        /** The rows in force for one list setting, keyed by its key. */
        private fun rowsOf(p: Long, i: Int, s: Int): Pair<String, List<PluginRow>>? {
            if (Lookout.settingInt(p, i, s, -1, INT_KIND) != KIND_LIST) return null
            val key = Lookout.settingText(p, i, s, -1, TEXT_KEY).ifEmpty { return null }
            val rows = (0 until Lookout.itemCount(p, i, s)).mapNotNull { it ->
                val id = Lookout.itemId(p, i, s, it).ifEmpty { return@mapNotNull null }
                PluginRow(id, pairs(Lookout.itemValues(p, i, s, it)))
            }
            return key to rows
        }

        /** A {key, text, key, text, ...} run as a map. */
        private fun pairs(flat: Array<String>): Map<String, String> {
            val out = LinkedHashMap<String, String>(flat.size / 2)
            var k = 0
            while (k + 1 < flat.size) {
                out[flat[k]] = flat[k + 1]
                k += 2
            }
            return out
        }

        /**
         * The per-row lines out of one plugin's status. The core hands the
         * status over as the TEXT the plugin wrote, so a plugin that writes a
         * plain sentence rather than the JSON line simply has none.
         */
        private fun statusItems(status: String): Map<String, PluginStatusItem> {
            if (status.isEmpty() || !status.startsWith("{")) return emptyMap()
            return try {
                val items = JSONObject(status).optJSONArray("items") ?: return emptyMap()
                (0 until items.length()).mapNotNull { k ->
                    val it = items.optJSONObject(k) ?: return@mapNotNull null
                    val id = it.optString("id").ifEmpty { return@mapNotNull null }
                    id to PluginStatusItem(id, it.optString("state"), it.optString("detail"))
                }.toMap()
            } catch (e: Exception) {
                emptyMap()
            }
        }

        /** lookout_section as one of [SettingsSection]'s ids. */
        private fun tabOf(section: Int): String = TABS.getOrElse(section) { "advanced" }

        private val ORIGINS = listOf("bundled", "installed", "developer")
        private val TABS = listOf(
            "display", "depths", "text", "charts",
            "vessels", "alarms", "connections", "advanced",
        )

        // The ordinals the natives take. They mirror Lookout.java.
        private const val TEXT_ID = 0
        private const val TEXT_NAME = 1
        private const val TEXT_VERSION = 2
        private const val TEXT_STATUS = 3
        private const val INT_ORIGIN = 0

        private const val TEXT_CAP_NAME = 0
        private const val TEXT_CAP_SENTENCE = 1

        private const val TEXT_KEY = 0
        private const val TEXT_LABEL = 1
        private const val TEXT_DESC = 2
        private const val TEXT_GROUP = 3
        private const val TEXT_UNIT = 4
        private const val TEXT_DEFAULT_TEXT = 5
        private const val TEXT_FOOTER = 7
        private const val TEXT_EMPTY = 8
        private const val TEXT_ADD_LABEL = 9
        private const val TEXT_SWITCH_KEY = 10

        private const val NUM_MIN = 0
        private const val NUM_MAX = 1
        private const val NUM_DEFAULT = 2
        private const val NUM_VALUE = 3

        private const val INT_KIND = 0
        private const val INT_SECTION = 1
        private const val INT_OPTIONAL = 2
        private const val INT_MAX_ITEMS = 4

        private const val KIND_NUMBER = 0
        private const val KIND_TOGGLE = 1
        private const val KIND_TEXT = 2
        private const val KIND_LIST = 3
    }
}

// ---- writing a list back ----------------------------------------------------
//
// A list is replaced WHOLE on every edit — that is the core's contract (see
// `normalizeRows` in src/plugin/host.zig) — so every editor action, add, remove,
// a typed character committed or a switch flipped, sends the entire array.

/**
 * A fresh row on the schema's own defaults, with the id the plugin will echo in
 * its status items. The id is minted HERE and never changes again: it is what
 * ties "connected, 44 msg/s" to the line the mariner is looking at.
 */
fun PluginListSchema.newRow(): PluginRow {
    val cells = itemFields.associate { f ->
        f.key to when (f.kind) {
            PluginField.Kind.TEXT -> f.defaultText
            PluginField.Kind.TOGGLE -> if (f.defaultValue != 0.0) "true" else "false"
            PluginField.Kind.NUMBER -> trimmed(f.defaultValue)
        }
    }
    // Short and unique: the host keeps 32 bytes of it, and it only has to be
    // distinct within one plugin's list.
    return PluginRow("row-" + java.util.UUID.randomUUID().toString().take(8), cells)
}

/**
 * A row filled in from what the network answered: the schema's defaults, the
 * address the service answered on, its name and port, and whatever else the
 * service type says a row of this list takes.
 */
fun PluginListSchema.rowFrom(service: DiscoveredService): PluginRow {
    val fresh = newRow()
    val cells = fresh.cells.toMutableMap()
    for ((key, value) in discover.firstOrNull { it.service == service.service }?.set.orEmpty()) {
        if (itemFields.any { it.key == key }) cells[key] = value
    }
    addressField?.let { cells[it.key] = service.host }
    portField?.let { cells[it.key] = service.port.toString() }
    nameField?.let { cells[it.key] = service.name }
    return fresh.copy(cells = cells)
}

/**
 * The rows as the core takes them: every column the schema declares, typed by
 * its kind, with the shell's row id. A cell the row does not carry falls back to
 * the schema's default rather than being omitted — the core would default it
 * anyway, and sending it keeps what was written and what is in force the same
 * shape.
 */
fun PluginListSchema.rowsJson(rows: List<PluginRow>): String {
    val arr = JSONArray()
    for (r in rows) {
        val o = JSONObject()
        o.put("id", r.id)
        for (f in itemFields) {
            val cell = r.cells[f.key]
            when (f.kind) {
                PluginField.Kind.TEXT -> o.put(f.key, cell ?: f.defaultText)
                PluginField.Kind.TOGGLE -> o.put(
                    f.key,
                    if (cell == null) f.defaultValue != 0.0 else (cell == "true" || cell == "1"),
                )
                PluginField.Kind.NUMBER -> {
                    val v = cell?.trim()?.toDoubleOrNull() ?: f.defaultValue
                    // A whole number goes over as an integer: a port written
                    // "10110.0" reads oddly in a log, and the core takes either.
                    if (v == Math.floor(v) && !v.isInfinite()) o.put(f.key, v.toLong())
                    else o.put(f.key, v)
                }
            }
        }
        arr.put(o)
    }
    return arr.toString()
}

/** A number with no trailing ".0" — what a text control should start out with. */
internal fun trimmed(v: Double): String =
    if (v == Math.floor(v) && !v.isInfinite()) v.toLong().toString() else v.toString()

/**
 * Where the mariner's connection lists live between launches.
 *
 * The rows are stored as the JSON array the plugin will be given, under one key
 * per plugin and list — the Android twin of macOS's `plugins.lists.v1`
 * UserDefaults key, and stored the same way and for the same reason: a schema
 * belongs to its plugin and may change, and a saved column the schema no longer
 * declares is simply dropped by the core on the way in.
 *
 * Without this a gateway typed at the helm would be gone at the next launch,
 * which is the whole reason the launch intent existed.
 */
object PluginPrefs {
    private const val PREFS = "plugins.lists.v1"
    private const val SCALARS = "plugins.v1"

    private fun key(pluginId: String, listKey: String) = "$pluginId/$listKey"

    fun saveRows(ctx: android.content.Context, list: PluginListSchema, json: String) {
        ctx.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
            .edit().putString(key(list.pluginId, list.key), json).apply()
    }

    /** The saved array, or null when the mariner has never edited this list. */
    fun savedRows(ctx: android.content.Context, list: PluginListSchema): String? =
        ctx.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
            .getString(key(list.pluginId, list.key), null)

    /**
     * One scalar field — the Android twin of macOS's `plugins.v1`. Toggles
     * ride as 1.0/0.0; the field's kind, read from the live schema at restore,
     * decides the JSON shape the core is given back. Stored as raw double bits
     * because SharedPreferences has no double.
     */
    fun saveScalar(ctx: android.content.Context, pluginId: String, fieldKey: String, value: Double) {
        ctx.getSharedPreferences(SCALARS, android.content.Context.MODE_PRIVATE)
            .edit().putLong(key(pluginId, fieldKey), java.lang.Double.doubleToRawLongBits(value)).apply()
    }

    /** Every saved scalar, keyed `pluginId/fieldKey`. */
    fun savedScalars(ctx: android.content.Context): Map<String, Double> =
        ctx.getSharedPreferences(SCALARS, android.content.Context.MODE_PRIVATE)
            .all.mapNotNull { (k, v) -> (v as? Long)?.let { k to java.lang.Double.longBitsToDouble(it) } }
            .toMap()
}
