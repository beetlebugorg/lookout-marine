// The bake of one chart set: prepare what the core lists for it into the
// app's own library. The Android twin of ChartBake.swift / lk_bake.cpp: same
// phase order (cells, sheets, lift) and the same coarse-band-first sort, so a
// cancel leaves passage-scale coverage.
package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File

class ChartImport(private val appContext: Context) {

    /** What the Charts pane draws while an import runs, and after. */
    data class State(
        val name: String,
        val done: Int,
        val total: Int,
        val running: Boolean,
        val failed: Boolean,
        /** How many charts fall in each usage band, coarse band first. The
         *  bake runs in that order, so `done` walks down this list and says
         *  which band it has reached. */
        val bands: List<Band> = emptyList(),
    ) {
        /** Each band with the part of it that is done, from the one count the
         *  bake reports. */
        val bandProgress: List<Band>
            get() {
                var left = done
                return bands.map { b ->
                    val n = minOf(left, b.total)
                    left -= n
                    b.copy(done = n)
                }
            }
    }

    /** One usage band of the charts being prepared. */
    data class Band(val band: Int, val name: String, val total: Int, val done: Int = 0)

    var state by mutableStateOf<State?>(null)
        private set

    private val main = Handler(Looper.getMainLooper())

    @Volatile private var job = 0L

    /** The set being prepared. */
    @Volatile private var source: String? = null

    /** Stops the core's prepare while [state] shows it. */
    private var coreStop: (() -> Unit)? = null

    /**
     * Show the core's prepare of a NOAA download as [state], so the Charts
     * pane and setup draw it as they draw a bake. [stop] is what [cancel]
     * calls while it runs. A bake of the shell's own keeps the state.
     */
    fun showCorePrepare(s: State, stop: () -> Unit) {
        if (job != 0L || source != null) return
        coreStop = if (s.running) stop else null
        state = s
    }

    /** Stop the bake. tile57 stops at the next chart boundary. The core
     *  records the stop, so the set does not resume on its own. */
    fun cancel() {
        coreStop?.invoke()
        source?.let { ChartSets.noteCancel(it) }
        val j = job
        if (j != 0L) Lookout.bakeCancel(j)
    }

    /**
     * Prepare what the core lists for the set at [set]. Once the bake stops,
     * the core records how it ended and reads the set again, and [onDone]
     * runs on the main thread.
     *
     * False when a bake is already running or the core lists no file to
     * prepare. No bake starts then.
     */
    fun start(set: String, onDone: () -> Unit): Boolean {
        if (state?.running == true) return false
        val row = ChartSets.all().firstOrNull { it.path == set }
        val name = row?.title ?: File(set).name
        val plan = plan(ChartSets.toPrepare(set), set)
        if (plan.ins.isEmpty()) {
            state = State(name, 0, 0, running = false, failed = false)
            return false
        }
        val bands = plan.bands
        state = State(name, 0, plan.ins.size, running = true, failed = false, bands = bands)
        source = set
        Thread {
            val zip = set.endsWith(".zip", ignoreCase = true)
            val j = Lookout.bakeStart(
                set, plan.ins.toTypedArray(), plan.outs.toTypedArray(),
                plan.cells, plan.sheets, plan.lifts, zip,
            )
            if (j == 0L) {
                finish(name, onDone, failed = true)
                return@Thread
            }
            job = j
            val buf = IntArray(4)
            while (Lookout.bakePoll(j, buf)) {
                val s = State(name, buf[0], buf[1], running = true, failed = false, bands = bands)
                main.post { state = s }
                Thread.sleep(200)
            }
            Lookout.bakePoll(j, buf)
            ChartSets.noteBake(set, j)
            job = 0L
            Lookout.bakeFree(j)
            ChartSets.rescan(set)
            Log.i(TAG, "import $name: baked ${buf[2]} of ${buf[1]}, ok=${buf[3]}")
            // A cancelled or partly failed bake is a usable library: what was
            // prepared draws.
            finish(name, onDone, failed = buf[2] == 0 && buf[3] == 0)
        }.start()
        return true
    }

    private fun finish(name: String, onDone: () -> Unit, failed: Boolean) {
        main.post {
            source = null
            state = State(name, 0, 0, running = false, failed = failed)
            onDone()
        }
    }

    private class Plan(
        val ins: List<String>,
        val outs: List<String>,
        val cells: Int,
        val sheets: Int,
        val lifts: Int,
        val bands: List<Band>,
    )

    /**
     * The files the core lists, in the order the core bakes them, each with
     * the path the core lays it out at (lookout_bake_order and
     * lookout_bake_output_path). Everything goes under the set's prepared
     * directory, which the core scans beside the set.
     */
    private fun plan(files: List<ChartScanRead.ChartFile>, set: String): Plan {
        val out = ChartBake.preparedDirectory(appContext, File(set)).absolutePath
        val works = files.map { prepare(it.kind) }.toIntArray()
        val order = if (files.isEmpty()) IntArray(0) else Lookout.bakeOrder(
            files.map { it.name }.toTypedArray(),
            files.map { it.band }.toIntArray(),
            works,
        )
        val ins = ArrayList<String>()
        val outs = ArrayList<String>()
        val bands = ArrayList<Band>()
        var cells = 0
        var sheets = 0
        var lifts = 0
        for (i in order) {
            val c = files[i]
            val work = works[i]
            val path = Lookout.bakeOutputPath(out, set, c.path, c.name, c.band, work)
            if (path.isEmpty()) continue
            File(path).parentFile?.mkdirs()
            ins.add(c.path)
            outs.add(path)
            val at = bands.indexOfFirst { it.band == c.band }
            if (at < 0) bands.add(Band(c.band, c.bandName.ifEmpty { "Other" }, 1))
            else bands[at] = bands[at].copy(total = bands[at].total + 1)
            when (work) {
                PREPARE_CELL -> cells++
                PREPARE_SHEET -> sheets++
                else -> lifts++
            }
        }
        return Plan(ins, outs, cells, sheets, lifts, bands)
    }

    /**
     * What has to happen to one file before it draws. Inside an archive even a
     * baked chart has to come out, which is a lift.
     */
    private fun prepare(kind: Int): Int = when (kind) {
        ChartScanRead.SOURCE -> PREPARE_CELL
        ChartScanRead.RASTER_SOURCE -> PREPARE_SHEET
        else -> PREPARE_LIFT
    }

    companion object {
        private const val TAG = "lookout"

        // lookout_prepare
        private const val PREPARE_CELL = 0
        private const val PREPARE_SHEET = 1
        private const val PREPARE_LIFT = 2
    }
}
