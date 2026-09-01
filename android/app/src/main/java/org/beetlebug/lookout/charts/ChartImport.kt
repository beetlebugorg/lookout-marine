// The import pipeline: scan a folder or archive, bake what is raw into the
// app's own library, and hand the library back to open. The Android twin of
// ChartBake.swift / lk_bake.cpp: same phase order (cells, sheets, lift), same
// coarse-band-first sort — a cancel leaves passage-scale coverage, not one
// river's berths — and the same skip of outputs that already exist, so
// re-importing one chart never re-bakes the rest.
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
    )

    var state by mutableStateOf<State?>(null)
        private set

    private val main = Handler(Looper.getMainLooper())

    @Volatile private var job = 0L

    /** Ask the bake to stop; tile57 stops at the next chart boundary. */
    fun cancel() {
        val j = job
        if (j != 0L) Lookout.bakeCancel(j)
    }

    /**
     * Scan and bake [source], then call [onDone] on the main thread with the
     * baked library's directory — or null when nothing could be prepared.
     * A folder that is a library already skips straight to done.
     */
    fun start(source: File, onDone: (File?) -> Unit) {
        if (state?.running == true) return
        state = State(source.name, 0, 0, running = true, failed = false)
        Thread {
            val zip = source.isFile && source.name.endsWith(".zip", ignoreCase = true)
            // The two scan entry points share one buffer in the core and are
            // NOT reentrant; this thread is the only scanner (state gates a
            // second import).
            val scan = Lookout.scanRead(source.absolutePath, zip)
            if (scan == null) {
                finish(source, null, onDone, failed = true)
                return@Thread
            }
            val plan = plan(scan, source, zip)
            if (plan.ins.isEmpty()) {
                // Nothing raw: what stands here (or was baked before) opens.
                finish(source, plan.chartsOut, onDone, failed = false)
                return@Thread
            }
            val j = Lookout.bakeStart(
                source.absolutePath,
                plan.ins.toTypedArray(), plan.outs.toTypedArray(),
                plan.cells, plan.sheets, plan.lifts, zip,
            )
            if (j == 0L) {
                finish(source, null, onDone, failed = true)
                return@Thread
            }
            job = j
            val buf = IntArray(4)
            while (Lookout.bakePoll(j, buf)) {
                val s = State(source.name, buf[0], buf[1], running = true, failed = false)
                main.post { state = s }
                Thread.sleep(200)
            }
            Lookout.bakePoll(j, buf)
            Lookout.bakeFree(j)
            job = 0L
            val landed = buf[2] > 0 || buf[3] != 0
            Log.i(TAG, "import ${source.name}: baked ${buf[2]} of ${buf[1]}, ok=${buf[3]}")
            // A cancelled or partly-failed bake is not a dead end: whatever
            // landed is a usable library.
            finish(source, if (landed) plan.chartsOut else null, onDone, failed = !landed)
        }.start()
    }

    private fun finish(source: File, out: File?, onDone: (File?) -> Unit, failed: Boolean) {
        main.post {
            state = State(source.name, 0, 0, running = false, failed = failed)
            onDone(out)
        }
    }

    private class Plan(
        val ins: List<String>,
        val outs: List<String>,
        val cells: Int,
        val sheets: Int,
        val lifts: Int,
        val chartsOut: File,
    )

    /**
     * The scan's cells, in the order the core bakes them, each with the path
     * the core lays it out at. THE ORDER AND THE PATHS ARE THE CORE'S
     * (lookout_bake_order and lookout_bake_output_path): four shells had four
     * copies of both, and the layout has teeth in it.
     *
     * Pictures go under a root of their own, so the vector open's .pmtiles
     * walk never swallows them.
     */
    private fun plan(scan: Array<String>, source: File, zip: Boolean): Plan {
        val chartsOut = ChartBake.preparedDirectory(appContext, source)
        val rasterOut = ChartBake.preparedDirectory(appContext, source, raster = true)

        val read = ChartScanRead.decode(scan)
        val needs = read?.files.orEmpty()
            .filter { zip || it.kind == ChartScanRead.SOURCE || it.kind == ChartScanRead.RASTER_SOURCE }
        if (needs.isEmpty()) return Plan(emptyList(), emptyList(), 0, 0, 0, chartsOut)

        val works = needs.map { prepare(it.kind) }.toIntArray()
        val order = Lookout.bakeOrder(
            needs.map { it.name }.toTypedArray(),
            needs.map { it.band }.toIntArray(),
            works,
        )

        val ins = ArrayList<String>()
        val outs = ArrayList<String>()
        var cells = 0
        var sheets = 0
        var lifts = 0
        for (i in order) {
            val c = needs[i]
            val work = works[i]
            val raster = c.kind == ChartScanRead.RASTER || c.kind == ChartScanRead.RASTER_SOURCE
            val dir = if (raster) rasterOut else chartsOut
            val out = Lookout.bakeOutputPath(
                dir.absolutePath, source.absolutePath, c.path, c.name, c.band, work,
            )
            if (out.isEmpty()) continue
            val file = File(out)
            // Already made: a source reports its cells as raw however many
            // times it is scanned; re-importing must not re-bake the rest.
            if (file.exists()) continue
            file.parentFile?.mkdirs()
            ins.add(c.path)
            outs.add(out)
            when (work) {
                PREPARE_CELL -> cells++
                PREPARE_SHEET -> sheets++
                else -> lifts++
            }
        }
        return Plan(ins, outs, cells, sheets, lifts, chartsOut)
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
