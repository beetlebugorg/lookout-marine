package org.beetlebug.lookout

/**
 * The JSON the core hands the shell, as files.
 *
 * PROVENANCE. These are transcribed from the writers, not captured from a run:
 * `alertsJson` and `tablesJson` at src/plugin/broker.zig. The plugin content is
 * the shipped manifests verbatim (plugins/nmea0183, plugins/signalk,
 * plugins/ais).
 *
 * The harness has no flag that dumps these, so a capture would have meant
 * adding one to src/plugin_dev_main.zig, which is out of scope for this branch.
 * Transcription is the weaker of the two: it can agree with a writer that has
 * since changed. Anything asserted here that the core stops emitting passes on
 * a fixture and fails on a boat, so treat a core change to either writer as a
 * change to these files.
 */
internal object Fixtures {

    fun read(name: String): String =
        requireNotNull(Fixtures::class.java.classLoader?.getResourceAsStream(name)) {
            "missing test fixture: $name"
        }.use { it.readBytes().toString(Charsets.UTF_8) }


    /** Four alerts: two alarms, a warning, an acknowledged notice. */
    val alerts: String get() = read("plugin-alerts.json")

    /** Two declared tables, one locatable and one not. */
    val tables: String get() = read("plugin-tables.json")

    /** One batch for the AIS table, including a short row and null cells. */
    val tableRows: String get() = read("plugin-table-rows.json")
}
