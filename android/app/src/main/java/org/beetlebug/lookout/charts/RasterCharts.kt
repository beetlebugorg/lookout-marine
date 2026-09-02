package org.beetlebug.lookout.charts

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File
import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.store.Store

/**
 * The raster charts the mariner has installed, and which of them are switched
 * on. The Android twin of AppModel's raster list.
 *
 * A raster chart is a chart made of pictures the mariner supplies: MBTiles of
 * satellite imagery, or another vendor's chart rendered to tiles. The engine
 * draws them BELOW the ENC and the ENC drops its opaque depth and land fills
 * wherever one covers, so the mariner keeps the contours, buoys, lights and
 * soundings and sees the water as well.
 *
 * WHY THE LIST LIVES HERE AND NOT IN THE ENGINE. The engine holds what is open
 * NOW. A chart set has to outlive both a change of ENC and a restart — it is
 * the mariner's own material, gathered for a coast, and losing it on every open
 * would make the feature useless. So the list is persisted here and replayed
 * into each chart the engine opens.
 */
class RasterCharts(appContext: Context) {

    /** Installed charts, in the order added. */
    var paths by mutableStateOf<List<String>>(emptyList())
        private set

    /**
     * Charts switched OFF but still installed. Off keeps the file and stops
     * drawing it: a mariner carrying four providers for one coast wants three
     * of them quiet, not deleted — they are half-gigabyte downloads.
     */
    var off by mutableStateOf<Set<String>>(emptySet())
        private set

    /**
     * Set NAMES the mariner turned off where they cover, drawn back at the
     * next open. By NAME, not path: an unplugged drive is not a change of
     * mind, so an entry survives its files being absent for a launch.
     */
    var hidden: Set<String> = emptySet()
        private set

    /** The ENC hidden under the picture, put back at the next open. */
    var chartHidden: Boolean = false
        private set

    init {
        // A list keeps the order it was written in, because "order added" IS
        // the contract.
        paths = Store.list(Store.Group.RASTER, KEY_PATHS)
        off = Store.list(Store.Group.RASTER, KEY_OFF).toSet()
        hidden = Store.list(Store.Group.RASTER, KEY_HIDDEN).toSet()
        chartHidden = Store.flag(Store.Group.RASTER, KEY_CHART_HIDDEN)
    }

    fun add(newPaths: List<String>): List<String> {
        val added = newPaths.filter { it !in paths }
        if (added.isEmpty()) return emptyList()
        paths = paths + added
        save()
        return added
    }

    fun remove(path: String) {
        paths = paths.filterNot { it == path }
        off = off - path
        save()
    }

    fun setEnabled(path: String, on: Boolean) {
        off = if (on) off - path else off + path
        save()
    }

    fun isEnabled(path: String) = path !in off

    /**
     * Record which sets are drawn, from the engine's own answers — the engine
     * owns the election; the shell never tracks it, only remembers it.
     * Entries for sets not installed this launch are KEPT (see [hidden]).
     */
    fun noteShown(sets: List<Pair<String, Boolean>>) {
        val seen = sets.map { it.first }.toSet()
        val nowHidden = sets.filter { !it.second }.map { it.first }.toSet()
        val merged = (hidden - seen) + nowHidden
        if (merged == hidden) return
        hidden = merged
        save()
    }

    fun setChartHidden(on: Boolean) {
        if (chartHidden == on) return
        chartHidden = on
        save()
    }

    private fun save() {
        Store.setList(Store.Group.RASTER, KEY_PATHS, paths)
        Store.setList(Store.Group.RASTER, KEY_OFF, off.toList())
        Store.setList(Store.Group.RASTER, KEY_HIDDEN, hidden.toList())
        Store.setFlag(Store.Group.RASTER, KEY_CHART_HIDDEN, chartHidden)
    }

    /**
     * Charts grouped the way the engine groups them into sets: by the provider
     * token in the file name. The settings screen shows one switch per group
     * and one per file, because a provider is what the mariner chooses between
     * and a file is what they downloaded.
     */
    val groups: List<Pair<String, List<String>>>
        get() = paths.groupBy { providerLabel(it) }.toList()

    companion object {
        private const val KEY_PATHS = "paths"
        private const val KEY_OFF = "off"
        private const val KEY_HIDDEN = "hidden"
        private const val KEY_CHART_HIDDEN = "chart_hidden"

        /**
         * The name of the set this file belongs to, from the engine. The
         * engine groups the files it draws by this name and the pill shows it,
         * so a settings row grouped by any other rule disagrees with the pill.
         * Needs no chart open.
         */
        fun providerLabel(path: String): String = Lookout.rasterSetNameFor(path)

        /**
         * Every raster chart under [dir]. `.mbtiles` today; the extension is a
         * hint only — the engine decides by what the file IS. BSB/KAP sheets are
         * deliberately not matched: they must be baked first.
         */
        fun under(dir: File): List<String> =
            dir.walkTopDown()
                .onFail { f, e -> Log.w("lookout", "skip $f: $e") }
                .filter { it.isFile && it.extension.equals("mbtiles", ignoreCase = true) }
                .map { it.absolutePath }
                .sorted()
                .toList()
    }
}

/** One set the engine reports: charts of one provider, drawn as one picture. */
data class RasterSet(
    val id: Int,
    val name: String,
    val inView: Boolean,
    /** Drawn where it covers — the engine's answer, never the shell's. */
    val shown: Boolean = false,
)

/**
 * What the HUD pill needs, read from the engine every pushed frame because
 * `inView` changes as the mariner sails.
 */
data class RasterState(
    /** Which set is drawn here, or -1. */
    val active: Int = -1,
    val sets: List<RasterSet> = emptyList(),
    /** The ENC is hidden wherever a raster chart covers. */
    val chartHidden: Boolean = false,
) {
    /** The sets with charts in view. The pill exists for these. */
    val visible: List<RasterSet> get() = sets.filter { it.inView }
}
