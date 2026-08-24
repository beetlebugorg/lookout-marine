// The import pipeline: scan a folder or archive, bake what is raw into the
// app's own library, and hand the library back to open. The Android twin of
// ChartBake.swift / lk_bake.cpp: same phase order (cells, sheets, lift), same
// coarse-band-first sort — a cancel leaves passage-scale coverage, not one
// river's berths — and the same skip of outputs that already exist, so
// re-importing one chart never re-bakes the rest.
package org.beetlebug.lookout

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONObject
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
            val json = Lookout.scanCharts(source.absolutePath, zip)
            if (json == null) {
                finish(source, null, onDone, failed = true)
                return@Thread
            }
            val plan = plan(json, source, zip)
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
     * Order the scan's cells the way every shell does and lay the outputs out
     * the way the engine expects them back: each chart in a directory of its
     * own stem (an archive mirrors its entry paths; a lift keeps the entry's
     * own name), pictures under their own root so the vector open's .pmtiles
     * walk never swallows them.
     */
    private fun plan(json: String, source: File, zip: Boolean): Plan {
        data class Cell(val path: String, val name: String, val kind: String, val band: Int)

        val root = JSONObject(json)
        val all = ArrayList<Cell>()
        for (key in listOf("cells", "raster")) {
            val arr = root.optJSONArray(key) ?: continue
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val p = o.optString("path")
                if (p.isEmpty()) continue
                all.add(Cell(p, o.optString("name"), o.optString("kind"), o.optInt("band")))
            }
        }

        fun rank(c: Cell) = when (c.kind) {
            "source" -> 0
            "raster_source" -> 1
            else -> 2 // inside an archive even a baked chart has to come out
        }

        val srcName = source.nameWithoutExtension.ifEmpty { source.name }
        val base = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        val chartsOut = File(base, "Charts/$srcName")
        val rasterOut = File(base, "Rasters/$srcName")

        val needs = all
            .filter { zip || it.kind == "source" || it.kind == "raster_source" }
            .sortedWith(compareBy({ rank(it) }, { it.band }, { it.name }))

        val ins = ArrayList<String>()
        val outs = ArrayList<String>()
        var cells = 0
        var sheets = 0
        var lifts = 0
        for (c in needs) {
            val stem = File(c.name).nameWithoutExtension
            val raster = c.kind == "raster_source" || c.kind == "raster"
            var dirBase = if (raster) rasterOut else chartsOut
            if (zip) {
                val rel = File(c.path).parent
                if (!rel.isNullOrEmpty()) dirBase = File(dirBase, rel)
            }
            val lift = rank(c) == 2
            val dir = if (lift || dirBase.name == stem) dirBase else File(dirBase, stem)
            val name = if (lift) File(c.path).name else "$stem.pmtiles"
            val out = File(dir, name)
            // Already made: a source reports its cells as raw however many
            // times it is scanned; re-importing must not re-bake the rest.
            if (out.exists()) continue
            dir.mkdirs()
            ins.add(c.path)
            outs.add(out.absolutePath)
            when (rank(c)) {
                0 -> cells++
                1 -> sheets++
                else -> lifts++
            }
        }
        return Plan(ins, outs, cells, sheets, lifts, chartsOut)
    }

    companion object {
        private const val TAG = "lookout"
    }
}
