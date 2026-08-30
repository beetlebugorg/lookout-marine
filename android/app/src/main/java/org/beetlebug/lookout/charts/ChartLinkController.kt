package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.engine.EngineAccess

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Charts by link: an online map AS the chart.
 *
 * One chart added by link is a MapLibre style url. Picking it renders that
 * style INSTEAD of the built-in chart — Lookout's own chart is just the default
 * entry in the same list.
 *
 * THE CORE OWNS ALL OF THIS. It probes the link, inlines TileJSON sources,
 * generates a wrapper style for bare tiles, fetches the sprite packs, builds
 * the credit line, templates the tile urls and persists the list. This renders
 * the snapshot; ChartLinkFetch.kt fetches the urls.
 */
class ChartLinkController(appContext: Context, private val access: EngineAccess) {

    //
    // One chart added by link: a MapLibre style url. Picking it renders that
    // style INSTEAD of the built-in chart — Lookout's own chart is just the
    // default entry in the same list.
    //
    // THE CORE OWNS ALL OF THIS. It probes the link, inlines TileJSON sources,
    // generates a wrapper style for bare tiles, fetches the sprite packs,
    // builds the credit line, templates the tile urls and persists the list.
    // This shell renders the snapshot and fetches urls (ChartLinkFetch.kt).

    data class ChartLink(val url: String, val name: String)

    var chartLinks by mutableStateOf<List<ChartLink>>(emptyList())
        private set
    /** The picked link's url; null draws the built-in chart. */
    var activeChartLink by mutableStateOf<String?>(null)
        private set
    var chartLinkBusy by mutableStateOf(false)
        private set
    var chartLinkError by mutableStateOf<String?>(null)
        private set

    /** The active chart link's source credits, shown by the scale bar while
     *  the link draws (tile usage policies make the credit a condition of
     *  service). Null when the Lookout chart is up. */
    var chartLinkAttribution by mutableStateOf<String?>(null)
        private set

    private val linkFetch = ChartLinkFetch()
    private val linkPrefs = appContext.getSharedPreferences("chartlinks.v1", Context.MODE_PRIVATE)

    /**
     * Whether a chart link was the drawn chart last time. One boolean, not a
     * second store: the engine chooses between opening link-first and opening
     * the cell library BEFORE a handle exists, and the list itself is the
     * core's. Rewritten from every snapshot.
     */
    val linkFirstHint: Boolean get() = linkPrefs.getBoolean(LINK_ACTIVE_HINT, false)

    /**
     * Hand the old SharedPreferences list to the core, once, and then drop it.
     *
     * The core ignores the import when it already has a list of its own, so the
     * window between handing it over and clearing the prefs replays harmlessly
     * if the process dies in it.
     *
     * RENDER THREAD, on every open; a no-op once the prefs are gone.
     */
    private fun migrateChartLinks(l: Lookout) {
        val raw = linkPrefs.getString("links", null) ?: return
        val doc = org.json.JSONObject()
        try {
            doc.put("links", org.json.JSONArray(raw))
        } catch (_: Exception) {
            linkPrefs.edit().remove("links").remove("active").apply()
            return
        }
        linkPrefs.getString("active", null)?.let { doc.put("active", it) }
        Log.i(TAG, "chart links: handing ${raw.length} B of the old store to the core")
        l.chartLinksImport(doc.toString())
        linkPrefs.edit().remove("links").remove("active").apply()
    }

    /**
     * Take the core's snapshot, if it changed. RENDER THREAD, off the readout
     * tick: the changed flag has one consumer.
     */
    private fun pollChartLinks(l: Lookout) {
        if (!l.chartLinksChanged()) return
        val json = l.chartLinksJson() ?: return
        val links = ArrayList<ChartLink>()
        var active: String? = null
        var credit: String? = null
        var err: String? = null
        var busy = false
        try {
            val top = org.json.JSONObject(json)
            val arr = top.optJSONArray("links")
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val url = o.optString("url")
                    if (url.isEmpty()) continue
                    links.add(ChartLink(url, o.optString("name")))
                }
            }
            active = if (top.isNull("active")) null else top.optString("active").ifEmpty { null }
            credit = top.optString("attribution").ifEmpty { null }
            err = top.optString("error").ifEmpty { null }
            busy = top.optBoolean("busy")
        } catch (e: Exception) {
            Log.w(TAG, "chart links snapshot: $e")
            return
        }
        val hint = active != null
        access.onMain {
            chartLinks = links
            activeChartLink = active
            chartLinkAttribution = credit
            chartLinkError = err
            chartLinkBusy = busy
            if (linkPrefs.getBoolean(LINK_ACTIVE_HINT, false) != hint) {
                linkPrefs.edit().putBoolean(LINK_ACTIVE_HINT, hint).apply()
            }
        }
    }

    /**
     * Add a chart by its style link. The core reads it once and refuses a dead
     * or non-style link, which surfaces as [chartLinkError]. The new chart is
     * picked immediately: adding it is the request to sail on it.
     */
    fun addChartLink(raw: String) {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return
        chartLinkError = null
        chartLinkBusy = true
        access.onEngine { l -> l.chartLinkAdd(trimmed) }
    }

    fun selectChartLink(url: String?) {
        // Selecting the link that is already drawn is a no-op: the settings row
        // fires on every tap, and re-selecting would re-resolve the style and
        // every sprite pack for nothing. A selection whose last resolve failed
        // does retry.
        if (url != null && url == activeChartLink && chartLinkError == null) return
        chartLinkError = null
        if (url != null) chartLinkBusy = true
        access.onEngine { l -> l.chartLinkSelect(url) }
    }

    fun removeChartLink(url: String) {
        access.onEngine { l -> l.chartLinkRemove(url) }
    }

    /**
     * Read a linked chart again — its tile urls, zooms, sprites and credit. A
     * link that does not answer leaves the chart as it was: a lost connection
     * must not cost the mariner the chart they are sailing on.
     */
    fun refreshChartLink(url: String) {
        chartLinkError = null
        chartLinkBusy = true
        access.onEngine { l -> l.chartLinkRefresh(url) }
    }

    /** Bring the fetcher up against a freshly opened engine. RENDER THREAD. */
    fun start(l: Lookout) {
        migrateChartLinks(l)
        linkFetch.start(l) { access.wake() }
    }

    /** A fetch landing later must find the provider gone, not a dying engine. */
    fun stop() {
        linkFetch.stop()
    }

    /** Off the readout tick: the changed flag has one consumer. */
    fun poll(l: Lookout) = pollChartLinks(l)

    private companion object {
        const val TAG = "lookout"

        /** See linkFirstHint. */
        const val LINK_ACTIVE_HINT = "active_hint"
    }
}
