package org.beetlebug.lookout.plugins

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.engine.EngineAccess

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

// A plugin's declared table: which one is open, the sort the mariner chose,
// and the seq-gated poll that keeps it fed.
//
// A plugin declares a table in its manifest: a key, a title, typed columns. The
// core hands the declaration and the rows over as JSON, and the shell knows
// nothing about what any plugin does. PluginTable.kt formats and draws; this
// owns the state behind it.

data class TableColumn(val key: String, val label: String, val type: String) {
    /** True when the column holds a number, which is what gets right
     *  aligned and what the mariner scans down a column of. */
    val numeric: Boolean get() = type != "text" && type != "flag"
}

/** One table a plugin declares. */
data class TableSpec(
    val plugin: String,
    val key: String,
    val title: String,
    val menu: String,
    val columns: List<TableColumn>,
    val sortKey: String,
    val sortAscending: Boolean,
    /** True when the declaration's `at` named a position, so a row can be
     *  found on the chart. */
    val locatable: Boolean,
) {
    val id: String get() = "$plugin/$key"
}

data class TableRow(
    val id: String,
    val band: Int,
    val lon: Double?,
    val lat: Double?,
    val cells: List<Any?>,
)

data class TableBatch(val seq: Int, val rows: List<TableRow>)

/**
 * The tables the loaded plugins declare, and the one on screen.
 *
 * `onReveal` centres the chart on a row's position. That is the chart's to do,
 * not this class's, and it is the only thing here that reaches past the
 * plugins.
 */
class TableController(
    private val access: EngineAccess,
    private val onReveal: (lon: Double, lat: Double) -> Unit,
) {

/** Every table the loaded plugins declare, in declaration order. The
 *  Vessels pane lists them, so a plugin that unloads takes its row too. */
var tableSpecs by mutableStateOf<List<TableSpec>>(emptyList())
    private set

/** The declared table on screen, or null. */
var openTable by mutableStateOf<TableSpec?>(null)
    private set
var tableBatch by mutableStateOf<TableBatch?>(null)
    private set
var tableSortKey by mutableStateOf("")
    private set
var tableSortAscending by mutableStateOf(true)
    private set

/** The last batch the core reported. Rows are rebuilt only when it moves,
 *  so a table nobody is feeding does not churn once a second. */
@Volatile private var tableSeq = -1

fun showTable(spec: TableSpec) {
    openTable = spec
    tableBatch = null
    tableSortKey = spec.sortKey
    tableSortAscending = spec.sortAscending
    tableSeq = -1
    // The plugin is told before the first read: it builds no rows until
    // somebody is looking, so the first read would otherwise find none.
    access.onEngine { l ->
        l.pluginTableOpen(spec.plugin, spec.key, true)
        refreshTableRows(l, force = true)
    }
}

fun dismissTable() {
    val spec = openTable ?: return
    openTable = null
    tableBatch = null
    access.onEngine { l -> l.pluginTableOpen(spec.plugin, spec.key, false) }
}

/** A header tap: same column flips the way, a new column starts
 *  ascending. The core sorts WITHIN each band; this only says which
 *  column and which way. */
fun setTableSort(key: String) {
    tableSortAscending = if (key == tableSortKey) !tableSortAscending else true
    tableSortKey = key
    access.onEngine { l -> refreshTableRows(l, force = true) }
}

/** The dialog's once-a-second read. Skipped when the batch has not moved. */
fun pollTable() = access.onEngine { l -> refreshTableRows(l, force = false) }

private fun refreshTableRows(l: Lookout, force: Boolean) {
    val spec = openTable ?: return
    val batch = readTableRows(l, spec, tableSortKey, tableSortAscending)
    if (batch == null) {
        // The plugin has gone, and the table with it. Better an empty
        // dialog than a picture nobody is keeping up to date.
        tableSeq = -1
        access.onMain { if (openTable?.id == spec.id) tableBatch = TableBatch(0, emptyList()) }
        return
    }
    if (!force && batch.seq == tableSeq) return
    tableSeq = batch.seq
    access.onMain { if (openTable?.id == spec.id) tableBatch = batch }
}

/**
 * Centre the chart on a table row and shut the dialog over it. The camera
 * move is the chart's, so it goes back out through `onReveal`.
 */
fun revealOnChart(lon: Double, lat: Double) {
    dismissTable()
    onReveal(lon, lat)
}

    /**
     * The declared tables, from the registry re-read. They follow the loaded
     * set, so a plugin that unloads takes its table with it — and its dialog,
     * if that was the one on screen. MAIN THREAD.
     */
    fun adopt(specs: List<TableSpec>) {
        tableSpecs = specs
        if (openTable?.let { o -> specs.none { it.id == o.id } } == true) {
            openTable = null
            tableBatch = null
        }
    }

    /** The chart is going, and the plugins' declared tables with it. */
    fun clear() {
        tableSpecs = emptyList()
        openTable = null
        tableBatch = null
    }
}
