package org.beetlebug.lookout

/**
 * The JSON the core hands the shell, as files.
 *
 * PROVENANCE. These are transcribed from the writers, not captured from a run:
 * `Host.pluginsJson` at src/plugin/host.zig, `writeFieldCore` and
 * `writeFieldJson` at src/plugin/host/settings_json.zig, and `alertsJson` and
 * `tablesJson` at src/plugin/broker.zig. The plugin content is the shipped
 * manifests verbatim (plugins/nmea0183, plugins/signalk, plugins/ais); the two
 * non-bundled plugins are invented, because the shipped set has no `installed`
 * or `developer` entry to copy and the management section exists for those.
 *
 * The harness has no flag that dumps these, so a capture would have meant
 * adding one to src/plugin_dev_main.zig, which is out of scope for this branch.
 * Transcription is the weaker of the two: it can agree with a writer that has
 * since changed. Anything asserted here that the core stops emitting will pass
 * on a fixture and fail on a boat, so treat a core change to any of those four
 * writers as a change to these files.
 */
internal object Fixtures {

    fun read(name: String): String =
        requireNotNull(Fixtures::class.java.classLoader?.getResourceAsStream(name)) {
            "missing test fixture: $name"
        }.use { it.readBytes().toString(Charsets.UTF_8) }

    /** Five plugins: three bundled, one installed, one developer override. */
    val registry: String get() = read("plugins-registry.json")

    /** Four alerts: two alarms, a warning, an acknowledged notice. */
    val alerts: String get() = read("plugin-alerts.json")

    /** Two declared tables, one locatable and one not. */
    val tables: String get() = read("plugin-tables.json")

    /** One batch for the AIS table, including a short row and null cells. */
    val tableRows: String get() = read("plugin-table-rows.json")
}
