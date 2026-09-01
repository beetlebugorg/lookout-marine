// A plugin's declared table, as a dialog. The Android twin of the reference's
// PluginTable.swift: the core hands the declaration over through
// lookout_tables_read and the rows through lookout_table_rows_read, already in
// the order they are to be shown; this file builds the dialog and knows nothing
// about what any plugin does.
//
// UNITS ARE THE SHELL'S. The column type says what a number means: distance
// is metres, speed metres per second, bearing degrees true, duration seconds,
// and every one is formatted here, in the units of the sea. That is what lets
// the core sort a column numerically while the mariner reads knots and
// nautical miles.
//
// THE ORDER IS THE PLUGIN'S FIRST. Every row carries a band, and the core
// sorts within a band and never across one. A header tap therefore reorders
// the vessels under an alarmed one and never moves it off the top line.
//
// An absent cell is a dash. Never heard and heard as zero are different
// values, and the table says which one it has.
package org.beetlebug.lookout.plugins

import org.beetlebug.lookout.hud.Chrome

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.beetlebug.lookout.Lookout
import java.util.Locale

/** What a cell says, in the mariner's units. */
object PluginTableFormat {
    /** A cell the plugin did not send. Not a zero, and it never reads as one. */
    const val MISSING = "—"

    fun text(cell: Any?, type: String): String = when (cell) {
        null -> MISSING
        is String -> if (type == "flag") cell.uppercase() else cell
        is Number -> number(cell.toDouble(), type)
        else -> MISSING
    }

    private fun number(v: Double, type: String): String {
        if (!v.isFinite()) return MISSING
        return when (type) {
            // Under a tenth of a mile the metres are what matters: a CPA of
            // "0.07 nm" tells a mariner far less than "124 m".
            "distance" -> if (v < 185.2) "${Math.round(v)} m"
                          else String.format(Locale.US, "%.2f nm", v / 1852)
            "speed" -> String.format(Locale.US, "%.1f kn", v * 3600 / 1852)
            "bearing" -> {
                val d = v.mod(360.0)
                String.format(Locale.US, "%03.0f°", d)
            }
            "duration" -> duration(v)
            else -> String.format(Locale.US, "%g", v)
        }
    }

    /** Seconds as a mariner counts them down: minutes and seconds, and hours
     *  once there are any. */
    fun duration(seconds: Double): String {
        val sign = if (seconds < 0) "-" else ""
        val total = Math.round(kotlin.math.abs(seconds)).toInt()
        return if (total >= 3600) {
            String.format(Locale.US, "%s%d:%02d:%02d", sign, total / 3600, (total % 3600) / 60, total % 60)
        } else {
            String.format(Locale.US, "%s%d:%02d", sign, total / 60, total % 60)
        }
    }
}

/**
 * The tables the loaded plugins declare, out of the flat read: eight strings
 * per table, then three per column. A table with no columns is skipped whole.
 *
 * `internal` so the suite drives it from a built array with no core open.
 */
fun readTableSpecs(l: Lookout): List<TableSpec> = decodeTableSpecs(l.tables())

internal fun decodeTableSpecs(flat: Array<String>?): List<TableSpec> {
    if (flat == null) return emptyList()
    val out = ArrayList<TableSpec>()
    var k = 0
    while (k + 8 <= flat.size) {
        val plugin = flat[k]
        val key = flat[k + 1]
        val columnCount = flat[k + 7].toIntOrNull() ?: 0
        val at = k + 8
        if (at + columnCount * 3 > flat.size) break
        val columns = ArrayList<TableColumn>(columnCount)
        for (c in 0 until columnCount) {
            val ck = flat[at + c * 3]
            if (ck.isEmpty()) continue
            columns.add(TableColumn(
                ck,
                flat[at + c * 3 + 1],
                columnType(flat[at + c * 3 + 2].toIntOrNull() ?: COLUMN_TEXT),
            ))
        }
        if (plugin.isNotEmpty() && key.isNotEmpty() && columns.isNotEmpty()) {
            out.add(TableSpec(
                plugin = plugin,
                key = key,
                title = flat[k + 2].ifEmpty { key },
                menu = flat[k + 3].ifEmpty { "Vessels" },
                columns = columns,
                sortKey = flat[k + 4],
                sortAscending = flat[k + 5] != "0",
                locatable = flat[k + 6] != "0",
            ))
        }
        k = at + columnCount * 3
    }
    return out
}

/**
 * One rows batch, out of the flat read: the seq, then six strings per row and
 * two per cell. A row that carried fewer cells than the table has columns
 * still lines up.
 */
fun readTableRows(l: Lookout, spec: TableSpec, sortKey: String, ascending: Boolean): TableBatch? =
    decodeTableRows(l.tableRows(spec.plugin, spec.key, sortKey, ascending), spec.columns.size)

internal fun decodeTableRows(flat: Array<String>?, columns: Int): TableBatch? {
    if (flat == null) return null
    val seq = flat.firstOrNull()?.toIntOrNull() ?: return null
    val rows = ArrayList<TableRow>()
    var k = 1
    while (k + 6 <= flat.size) {
        val id = flat[k]
        val cellCount = flat[k + 5].toIntOrNull() ?: 0
        val at = k + 6
        if (at + cellCount * 2 > flat.size) break
        val cells = ArrayList<Any?>(columns)
        for (c in 0 until cellCount) {
            val value = flat[at + c * 2 + 1]
            cells.add(when (flat[at + c * 2]) {
                // lookout_table_cell_kind. Absent is a cell the plugin did not
                // send, which reads as a dash and never as a zero.
                CELL_NUMBER -> value.toDoubleOrNull()
                CELL_TEXT -> value
                else -> null
            })
        }
        while (cells.size < columns) cells.add(null)
        val located = flat[k + 2] != "0"
        if (id.isNotEmpty()) {
            rows.add(TableRow(
                id = id,
                band = flat[k + 1].toIntOrNull() ?: 0,
                lon = if (located) flat[k + 3].toDoubleOrNull() else null,
                lat = if (located) flat[k + 4].toDoubleOrNull() else null,
                cells = cells,
            ))
        }
        k = at + cellCount * 2
    }
    return TableBatch(seq, rows)
}

/** lookout_column_type as the word the formatter and the layout switch on. */
internal fun columnType(type: Int): String = when (type) {
    0 -> "distance"
    1 -> "speed"
    2 -> "bearing"
    3 -> "duration"
    4 -> "number"
    6 -> "flag"
    else -> "text"
}

private const val COLUMN_TEXT = 5
private const val CELL_NUMBER = "1"
private const val CELL_TEXT = "2"

/** How often the rows are re-read. The plugins feed a table at the status
 *  cadence, which is a second, so this is the same. */
private const val REFRESH_MS = 1_000L

private fun columnWidth(type: String) = if (type == "text") 150.dp else 84.dp

/**
 * The dialog for one declared table. The controller told the plugin the table
 * is open before this composed, and is told again when it leaves the screen;
 * the rows poll rides this composable's lifetime.
 */
@Composable
fun PluginTableDialog(controller: TableController) {
    val spec = controller.openTable ?: return
    LaunchedEffect(spec.id) {
        while (true) {
            controller.pollTable()
            delay(REFRESH_MS)
        }
    }
    PluginTable(
        spec = spec,
        batch = controller.tableBatch,
        sortKey = controller.tableSortKey,
        sortAscending = controller.tableSortAscending,
        onSort = { controller.setTableSort(it) },
        onReveal = { lon, lat -> controller.revealOnChart(lon, lat) },
        onDismiss = { controller.dismissTable() },
    )
}

/**
 * The table itself, as a function of what the core said. Split from the dialog
 * above so it can be shown without an engine open behind it.
 */
@Composable
internal fun PluginTable(
    spec: TableSpec,
    batch: TableBatch?,
    sortKey: String,
    sortAscending: Boolean,
    onSort: (String) -> Unit,
    onReveal: (lon: Double, lat: Double) -> Unit,
    onDismiss: () -> Unit,
) {
    val scroll = rememberScrollState()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(spec.title) },
        text = {
            // One horizontal scroll for the header and every row together:
            // eight columns do not fit a portrait tablet, and a header that
            // scrolls apart from its rows lines nothing up.
            Row(modifier = Modifier.horizontalScroll(scroll)) {
                Column {
                    Row(modifier = Modifier.padding(bottom = 4.dp)) {
                        for (col in spec.columns) {
                            val active = sortKey == col.key
                            Text(
                                col.label + when {
                                    !active -> ""
                                    sortAscending -> " \u25B2"
                                    else -> " \u25BC"
                                },
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.SemiBold,
                                textAlign = if (col.numeric) TextAlign.End else TextAlign.Start,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier
                                    .width(columnWidth(col.type))
                                    .clickable { onSort(col.key) }
                                    .padding(horizontal = 4.dp),
                            )
                        }
                    }
                    HorizontalDivider()
                    if (batch == null || batch.rows.isEmpty()) {
                        Text(
                            "Nothing to show yet.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(16.dp),
                        )
                    } else {
                        LazyColumn(modifier = Modifier.heightIn(max = 420.dp)) {
                            items(batch.rows, key = { it.id }) { row ->
                                TableRowLine(spec, row, onReveal)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}

@Composable
private fun TableRowLine(
    spec: TableSpec,
    row: TableRow,
    onReveal: (lon: Double, lat: Double) -> Unit,
) {
    // The colour of a row, from its flag column. Alarm takes the palette's
    // strongest warning colour, the way the alert banner does; a warning is
    // amber. A row with no flag is left alone.
    val alarmColor = MaterialTheme.colorScheme.error
    var tint: Color? = null
    for ((i, col) in spec.columns.withIndex()) {
        if (col.type != "flag") continue
        when ((row.cells.getOrNull(i) as? String)?.lowercase()) {
            "alarm" -> { tint = alarmColor.copy(alpha = 0.22f); break }
            "warning" -> { tint = Chrome.amber.copy(alpha = 0.20f); break }
        }
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (tint != null) it.background(tint) else it }
            .let { m ->
                // A table that declared no `at` has no rows to find on the
                // chart, and one that did may still hold a row nobody has
                // heard a position from.
                if (spec.locatable && row.lon != null && row.lat != null)
                    m.clickable { onReveal(row.lon, row.lat) }
                else m
            }
            .padding(vertical = 6.dp),
    ) {
        for ((i, col) in spec.columns.withIndex()) {
            val cell = row.cells.getOrNull(i)
            Text(
                PluginTableFormat.text(cell, col.type),
                style = MaterialTheme.typography.bodySmall,
                textAlign = if (col.numeric) TextAlign.End else TextAlign.Start,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                // A cell the plugin never sent is greyed: the mariner can
                // tell a value that is missing from one that is small.
                color = when {
                    cell == null -> MaterialTheme.colorScheme.onSurfaceVariant
                    col.type == "flag" && (cell as? String)?.lowercase() == "alarm" ->
                        MaterialTheme.colorScheme.error
                    col.type == "flag" && (cell as? String)?.lowercase() == "warning" -> Chrome.amber
                    else -> MaterialTheme.colorScheme.onSurface
                },
                modifier = Modifier
                    .width(columnWidth(col.type))
                    .padding(horizontal = 4.dp),
            )
        }
    }
}
