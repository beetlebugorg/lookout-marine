// A plugin's declared table, as a dialog. The Android twin of the reference's
// PluginTable.swift: the core hands the declaration over through
// lookout_plugin_tables_json and the rows through lookout_plugin_table_rows,
// already in the order they are to be shown; this file builds the dialog and
// knows nothing about what any plugin does.
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
// A null cell is a dash. Never heard and heard as zero are different values,
// and the table says which one it has.
package org.beetlebug.lookout.plugins

import org.beetlebug.lookout.chart.ChartController
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
import org.json.JSONObject
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

/** Parse `{"tables":[…]}` into specs. Anything malformed is skipped whole. */
fun parseTableSpecs(json: String?): List<ChartController.TableSpec> {
    if (json == null) return emptyList()
    val out = ArrayList<ChartController.TableSpec>()
    val arr = try { JSONObject(json).optJSONArray("tables") } catch (_: Exception) { null } ?: return out
    for (i in 0 until arr.length()) {
        val o = arr.optJSONObject(i) ?: continue
        val plugin = o.optString("plugin")
        val key = o.optString("key")
        val cols = o.optJSONArray("columns") ?: continue
        if (plugin.isEmpty() || key.isEmpty() || cols.length() == 0) continue
        val columns = ArrayList<ChartController.TableColumn>()
        for (c in 0 until cols.length()) {
            val co = cols.optJSONObject(c) ?: continue
            val k = co.optString("key")
            if (k.isEmpty()) continue
            columns.add(ChartController.TableColumn(k, co.optString("label"), co.optString("type", "text")))
        }
        if (columns.isEmpty()) continue
        val sort = o.optJSONObject("sort")
        out.add(ChartController.TableSpec(
            plugin = plugin,
            key = key,
            title = o.optString("title", key),
            menu = o.optString("menu", "Vessels"),
            columns = columns,
            sortKey = sort?.optString("key") ?: "",
            sortAscending = sort?.optBoolean("ascending", true) ?: true,
            locatable = o.has("at"),
        ))
    }
    return out
}

/** Parse one rows batch: `{"seq":n,"rows":[{"id":…,"band":…,"at":[lon,lat],
 *  "cells":[…]},…]}`. A row that carried fewer cells than the table has
 *  columns still lines up. */
fun parseTableRows(json: String, columns: Int): ChartController.TableBatch? {
    val top = try { JSONObject(json) } catch (_: Exception) { return null }
    val arr = top.optJSONArray("rows") ?: return null
    val rows = ArrayList<ChartController.TableRow>(arr.length())
    for (i in 0 until arr.length()) {
        val o = arr.optJSONObject(i) ?: continue
        val id = o.optString("id")
        if (id.isEmpty()) continue
        val at = o.optJSONArray("at")
        val cellsIn = o.optJSONArray("cells")
        val cells = ArrayList<Any?>(columns)
        for (c in 0 until (cellsIn?.length() ?: 0)) {
            val v = cellsIn!!.opt(c)
            cells.add(if (v == JSONObject.NULL) null else v)
        }
        while (cells.size < columns) cells.add(null)
        rows.add(ChartController.TableRow(
            id = id,
            band = o.optInt("band"),
            lon = if (at != null && at.length() == 2) at.optDouble(0) else null,
            lat = if (at != null && at.length() == 2) at.optDouble(1) else null,
            cells = cells,
        ))
    }
    return ChartController.TableBatch(top.optInt("seq"), rows)
}

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
fun PluginTableDialog(controller: ChartController) {
    val spec = controller.openTable ?: return
    LaunchedEffect(spec.id) {
        while (true) {
            controller.pollTable()
            delay(REFRESH_MS)
        }
    }
    val batch = controller.tableBatch
    val scroll = rememberScrollState()
    AlertDialog(
        onDismissRequest = { controller.dismissTable() },
        title = { Text(spec.title) },
        text = {
            // One horizontal scroll for the header and every row together:
            // eight columns do not fit a portrait tablet, and a header that
            // scrolls apart from its rows lines nothing up.
            Row(modifier = Modifier.horizontalScroll(scroll)) {
                Column {
                    Row(modifier = Modifier.padding(bottom = 4.dp)) {
                        for (col in spec.columns) {
                            val active = controller.tableSortKey == col.key
                            Text(
                                col.label + when {
                                    !active -> ""
                                    controller.tableSortAscending -> " ▲"
                                    else -> " ▼"
                                },
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.SemiBold,
                                textAlign = if (col.numeric) TextAlign.End else TextAlign.Start,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier
                                    .width(columnWidth(col.type))
                                    .clickable { controller.setTableSort(col.key) }
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
                                TableRowLine(spec, row, controller)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { controller.dismissTable() }) { Text("Close") }
        },
    )
}

@Composable
private fun TableRowLine(
    spec: ChartController.TableSpec,
    row: ChartController.TableRow,
    controller: ChartController,
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
                    m.clickable { controller.revealOnChart(row.lon, row.lat) }
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
