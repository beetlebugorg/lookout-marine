package org.beetlebug.lookout.pick

import org.beetlebug.lookout.Lookout

/**
 * What one pick result shows.
 *
 * The ENGINE composes the report. lookout_picks_read hands the composed page
 * over beside the payload the cell states, and this walks it. Nothing here
 * decides what a mariner reads: tile57_s57_report does that once, for every
 * shell.
 */
data class PickDecoded(
    /** The S-57 class and the cell, as the engine reported them. */
    val cls: String,
    val chart: String,
    val title: String,
    val subtitle: String?,
    val chip: String,
    val notes: List<String>,
    val reportRows: List<ReportRow>,
    val footnote: String,
    val empty: EmptyKind?,
    /** The payload as the cell states it, for the fold and the clipboard. */
    val rawRows: List<ReportRow>,
    /** The same payload in metres, for the clipboard. */
    val raw: String,
) {
    /** One row of the engine's report, or one of the source fold. */
    data class ReportRow(
        val label: String,
        val value: String,
        val depth: Int,
        val file: Boolean = false,
        val picture: Boolean = false,
    )

    /** Why the body has nothing to read, when it does not. */
    enum class EmptyKind { NO_ATTRIBUTES, SOURCE_ONLY }

    /**
     * The report as plain text for the clipboard. It uses the source fold, so a
     * chart problem is reported in the cell's own words.
     */
    val plainText: String
        get() {
            val sb = StringBuilder("$cls  $chart\n")
            for (row in rawRows) {
                val indent = "  ".repeat(row.depth)
                if (row.value.isEmpty()) sb.append("$indent${row.label}:\n")
                else sb.append("$indent${row.label}: ${row.value}\n")
            }
            return sb.toString()
        }

    companion object {
        /** The features under a point, best first. */
        fun read(l: Lookout, lon: Double, lat: Double): List<PickDecoded> =
            decode(l.pickRead(lon, lat))

        /**
         * The flat array the native hands back. `internal` so the suite drives
         * the same walk with no chart open.
         */
        internal fun decode(flat: Array<String>?): List<PickDecoded> {
            if (flat == null) return emptyList()
            val out = ArrayList<PickDecoded>()
            var k = 0
            while (k + HEADER <= flat.size) {
                val noteCount = flat[k + 8].toIntOrNull() ?: 0
                val rowCount = flat[k + 9].toIntOrNull() ?: 0
                val sourceCount = flat[k + 10].toIntOrNull() ?: 0
                var at = k + HEADER
                val body = noteCount + (rowCount + sourceCount) * ROW
                if (at + body > flat.size) break

                val notes = ArrayList<String>(noteCount)
                for (n in 0 until noteCount) notes.add(flat[at + n])
                at += noteCount

                val rows = rowsAt(flat, at, rowCount)
                at += rowCount * ROW
                val source = rowsAt(flat, at, sourceCount)
                at += sourceCount * ROW

                val cls = flat[k]
                out.add(PickDecoded(
                    cls = cls,
                    chart = flat[k + 1],
                    title = flat[k + 2].ifEmpty { cls },
                    subtitle = flat[k + 3].ifEmpty { null },
                    chip = flat[k + 4].ifEmpty { cls },
                    notes = notes,
                    reportRows = rows,
                    footnote = flat[k + 5].ifEmpty { flat[k + 1] },
                    empty = emptyKind(flat[k + 6].toIntOrNull() ?: 0),
                    rawRows = source,
                    raw = flat[k + 7],
                ))
                k = at
            }
            return out
        }

        private fun rowsAt(flat: Array<String>, at: Int, count: Int): List<ReportRow> =
            (0 until count).map { r ->
                val i = at + r * ROW
                ReportRow(
                    label = flat[i],
                    value = flat[i + 1],
                    depth = flat[i + 2].toIntOrNull() ?: 0,
                    file = flat[i + 3] != "0",
                    picture = flat[i + 4] != "0",
                )
            }

        /** lookout_pick_empty. 0 is a body with something to read. */
        private fun emptyKind(empty: Int): EmptyKind? = when (empty) {
            1 -> EmptyKind.NO_ATTRIBUTES
            2 -> EmptyKind.SOURCE_ONLY
            else -> null
        }

        private const val HEADER = 11
        private const val ROW = 5
    }
}
