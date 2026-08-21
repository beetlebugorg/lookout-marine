package org.beetlebug.lookout

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File

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

    private val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

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
        // An ordered JSON array, because "order added" IS the contract and a
        // StringSet reloaded .sorted() silently made it alphabetical.
        val ordered = prefs.getString(KEY_PATHS_ORDERED, null)
        paths = if (ordered != null) {
            val arr = org.json.JSONArray(ordered)
            List(arr.length()) { arr.getString(it) }
        } else {
            // The pre-ordered layout, migrated on the next save.
            prefs.getStringSet(KEY_PATHS, null)?.sorted() ?: emptyList()
        }
        off = prefs.getStringSet(KEY_OFF, null)?.toSet() ?: emptySet()
        hidden = prefs.getStringSet(KEY_HIDDEN, null)?.toSet() ?: emptySet()
        chartHidden = prefs.getBoolean(KEY_CHART_HIDDEN, false)
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
     * Entries for sets not aboard this launch are KEPT (see [hidden]).
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
        prefs.edit()
            .putString(KEY_PATHS_ORDERED, org.json.JSONArray(paths).toString())
            .putStringSet(KEY_OFF, off)
            .putStringSet(KEY_HIDDEN, hidden)
            .putBoolean(KEY_CHART_HIDDEN, chartHidden)
            .apply()
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
        private const val PREFS = "rastercharts.v1"
        private const val KEY_PATHS = "paths"
        private const val KEY_PATHS_ORDERED = "paths.ordered"
        private const val KEY_OFF = "off"
        private const val KEY_HIDDEN = "hidden.names"
        private const val KEY_CHART_HIDDEN = "chart.hidden"

        /**
         * Providers seen in community charts, longest first so "ArcGIS.Imagery"
         * is not matched as "ArcGIS". The engine does the same thing when it
         * groups files into sets; this only has to AGREE with it well enough to
         * label the settings rows.
         */
        private val PROVIDERS = listOf(
            "ArcGIS.Imagery", "GoogleSatellite", "BingSatellite",
            "OpenSeaMap", "Navionics", "ArcGIS", "Google", "Bing",
            "CMap", "C-Map", "Esri", "Sentinel", "Landsat",
        )

        fun providerLabel(path: String): String {
            val name = File(path).name
            PROVIDERS.firstOrNull { name.contains(it, ignoreCase = true) }?.let { return it }
            return File(path).nameWithoutExtension.substringBefore('.')
        }

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
    /** The set drawn over this view, or "" when this water has no picture. */
    val name: String = "",
    /** A set in view, drawn or not — what the pill offers to turn on. */
    val available: String = "",
    /** Which set is drawn here, or -1. */
    val active: Int = -1,
    val sets: List<RasterSet> = emptyList(),
    /** The ENC is hidden wherever a raster chart covers. */
    val chartHidden: Boolean = false,
) {
    /** The sets with charts in view. The pill exists for these. */
    val visible: List<RasterSet> get() = sets.filter { it.inView }
}
