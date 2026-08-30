package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.engine.EngineAccess

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * The mariner's picture charts: which are installed, which draw, and what the
 * HUD pill says about the water in view.
 *
 * THE ENGINE OWNS THE ELECTION. Showing a set turns off same-water rivals, and
 * which set wins is the engine's to decide; this only remembers the answer and
 * replays it into the next chart that opens. The list itself has to outlive
 * both a change of ENC and a restart, because it is the mariner's own material
 * gathered for a coast, so it is persisted by [RasterCharts] and installed
 * again on every open.
 */
class RasterController(private val access: EngineAccess, val charts: RasterCharts) {

    /** What the HUD pill shows. Refreshed every pushed frame: `inView` moves
     *  as the mariner sails in and out of a chart's coverage. */
    var raster by mutableStateOf(RasterState())
        private set

    @Volatile private var lastRaster: RasterState? = null

    /** A new chart: the pill's last answer belongs to the old one. */
    fun reset() {
        lastRaster = null
    }

    /**
     * Read the pill's state off the engine. RENDER THREAD ONLY, like the
     * readouts: these are native calls, and the api lock is held for a frame.
     */
    /**
     * Put the mariner's per-set choice back after an open, TWO passes — hide
     * first, then show — or the election (showing a set turns off same-water
     * rivals) loses the pick. Then the no-survey override: with no ENC aboard
     * "hidden" no longer means what it meant, and obeying it leaves a blank
     * sea, so the first covering set draws anyway. The SAVED choice is not
     * rewritten (the reference's restoreRasterShown, move for move).
     */
    fun restoreRasterShown(l: Lookout) {
        val hidden = charts.hidden
        if (hidden.isNotEmpty()) {
            val n = l.rasterSetCount()
            for (i in 0 until n) if (l.rasterSetName(i) in hidden) l.rasterSetShown(i, false)
            for (i in 0 until n) if (l.rasterSetName(i) !in hidden) l.rasterSetShown(i, true)
        }
        if (l.chartsCount() == 0) {
            val n = l.rasterSetCount()
            var shownInView = false
            for (i in 0 until n) {
                if (l.rasterSetInView(i) && l.rasterShown(i)) shownInView = true
            }
            if (!shownInView) {
                for (i in 0 until n) {
                    if (l.rasterSetInView(i)) {
                        Log.i(TAG, "no survey aboard; drawing ${l.rasterSetName(i)} over the blank sea")
                        l.rasterSetShown(i, true)
                        break
                    }
                }
            }
        }
    }

    fun pushRaster(l: Lookout) {
        val n = l.rasterSetCount()
        val sets = ArrayList<RasterSet>(n)
        for (i in 0 until n) {
            sets.add(RasterSet(i, l.rasterSetName(i), l.rasterSetInView(i), l.rasterShown(i)))
        }
        // Read back from the engine and remembered, never tracked here: the
        // engine owns the election.
        charts.noteShown(sets.map { it.name to it.shown })
        charts.setChartHidden(l.chartHidden())
        // Only what the pill actually reads. The engine also offers the
        // active and available set NAMES; the pill derives its label from
        // `visible` and `active` instead, so asking for them was two JNI
        // string crossings per push for nothing.
        val s = RasterState(
            active = l.rasterActiveIndex(),
            sets = sets,
            chartHidden = l.chartHidden(),
        )
        if (s == lastRaster) return
        lastRaster = s
        access.onMain { raster = s }
    }

    /**
     * Replay the installed charts into the chart just opened. The engine holds
     * what is open now; the mariner's own material has to survive a change of
     * ENC, so it is installed again on every open. RENDER THREAD.
     */
    fun installAll(l: Lookout) {
        for (p in charts.paths) {
            if (!l.rasterAdd(p)) Log.w(TAG, "raster chart will not open: $p")
            else if (!charts.isEnabled(p)) l.rasterSetEnabled(p, false)
        }
        restoreRasterShown(l)
        if (charts.chartHidden) l.setChartHidden(true)
        pushRaster(l)
    }

    /**
     * Install raster charts and draw the one just added, if it covers this
     * view. The mariner picked those files while looking at this water.
     */
    fun addRasterCharts(newPaths: List<String>) {
        val added = charts.add(newPaths)
        if (added.isEmpty()) return
        access.onEngine { l ->
            var opened = 0
            for (p in added) if (l.rasterAdd(p)) opened++
            if (opened > 0) {
                // The newest covering set is the one the mariner just added
                // while looking at this water. By INDEX from the top — the
                // engine appends sets in add order — not by re-deriving the
                // engine's name from the path: the two label tables disagreed
                // and the pick silently missed.
                val n = l.rasterSetCount()
                for (i in n - 1 downTo 0) {
                    if (l.rasterSetInView(i)) {
                        l.rasterSelect(i)
                        break
                    }
                }
            }
            pushRaster(l)
        }
    }

    /** Step to the next set covering the water in view, then to none. */
    fun cycleRaster() = access.onEngine { l -> l.rasterCycle(); pushRaster(l) }

    /** Draw set [i]. -1 turns off what is drawn over THIS view. */
    fun selectRasterSet(i: Int) = access.onEngine { l -> l.rasterSelect(i); pushRaster(l) }

    /** Hide the ENC wherever a raster chart covers, and show it again. */
    fun toggleChart() = access.onEngine { l -> l.toggleChart(); pushRaster(l) }

    /** Switch one chart off without removing it. */
    fun setRasterEnabled(path: String, on: Boolean) {
        charts.setEnabled(path, on)
        access.onEngine { l -> l.rasterSetEnabled(path, on); pushRaster(l) }
    }

    /** Switch a whole provider's charts together. */
    fun setRasterGroupEnabled(paths: List<String>, on: Boolean) {
        paths.forEach { charts.setEnabled(it, on) }
        access.onEngine { l ->
            paths.forEach { l.rasterSetEnabled(it, on) }
            pushRaster(l)
        }
    }

    /**
     * Forget a chart. The engine keeps it open until the next chart opens,
     * because it has no remove: the list is what is replayed, so dropping it
     * from the list is what removes it.
     */
    fun removeRasterChart(path: String) {
        charts.remove(path)
        access.onEngine { l -> l.rasterSetEnabled(path, false); pushRaster(l) }
    }

    private companion object {
        const val TAG = "lookout"
    }
}
