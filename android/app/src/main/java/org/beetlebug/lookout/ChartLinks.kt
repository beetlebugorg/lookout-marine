package org.beetlebug.lookout

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Charts added by link, and which one is drawn. The Android twin of
 * AppModel's chart links.
 *
 * A link names a whole MapLibre style — a street map, satellite imagery, or
 * another publisher's nautical portrayal — and picking it renders that style
 * INSTEAD of the built-in chart: Lookout's own chart is just the default
 * entry in the same list. A TileJSON link works too: the style the publisher
 * ships beside it is probed first (that is the look the mariner pasted the
 * link expecting), and a truly style-less tile source gets a plain generated
 * wrapper, stored with the link.
 *
 * The list persists here and the pick is replayed into every chart the
 * engine opens, exactly like the raster charts: the engine holds what is
 * open NOW, the mariner's material has to outlive it.
 */
class ChartLinks(appContext: Context) {

    data class Link(val url: String, val name: String, val doc: String?)

    private val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    var links by mutableStateOf(load())
        private set

    /** The picked link's url; null draws the built-in chart. */
    var active by mutableStateOf(prefs.getString(KEY_ACTIVE, null))
        private set

    /** What the engine should be handed: the wrapper document when the link
     *  carries one, else the url itself. Null = the built-in chart. */
    fun activeStyle(): String? {
        val a = active ?: return null
        val link = links.firstOrNull { it.url == a } ?: return null
        return link.doc ?: link.url
    }

    fun select(url: String?) {
        active = if (url != null && links.none { it.url == url }) null else url
        persist()
    }

    fun remove(url: String) {
        links = links.filter { it.url != url }
        if (active == url) active = null
        persist()
    }

    /**
     * Read the link and classify it — a style, a TileJSON (sibling style
     * probed first, wrapper generated otherwise), or nothing usable (null).
     * Blocking: call on an IO dispatcher. The new link is selected: adding
     * it is the request to sail on it.
     */
    fun add(rawUrl: String): Link? {
        val url = rawUrl.trim()
        if (!url.startsWith("http://") && !url.startsWith("https://")) return null
        links.firstOrNull { it.url == url }?.let {
            select(it.url)
            return it
        }
        val body = fetch(url) ?: return null
        val obj = runCatching { JSONObject(body) }.getOrNull() ?: return null
        val link: Link = when {
            obj.has("layers") && obj.has("version") ->
                Link(url, obj.optString("name").ifEmpty { URL(url).host }, null)
            obj.has("tiles") || obj.has("tilejson") -> {
                val sibling = siblingStyle(url)
                sibling ?: Link(
                    url,
                    obj.optString("name").ifEmpty { URL(url).host },
                    wrapperStyle(url, obj),
                )
            }
            else -> return null
        }
        links = links.filter { it.url != link.url } + link
        active = link.url
        persist()
        return link
    }

    /** The style.json living beside a TileJSON, when the publisher shipped one. */
    private fun siblingStyle(tilejsonUrl: String): Link? {
        val u = URL(tilejsonUrl)
        val dir = u.path.substringBeforeLast('/')
        val candidate = URL(u.protocol, u.host, if (u.port == -1) u.defaultPort else u.port, "$dir/style.json").toString()
        if (candidate == tilejsonUrl) return null
        val body = fetch(candidate) ?: return null
        val obj = runCatching { JSONObject(body) }.getOrNull() ?: return null
        if (!obj.has("layers") || !obj.has("version")) return null
        return Link(candidate, obj.optString("name").ifEmpty { u.host }, null)
    }

    /**
     * A style for a bare tile source: raster tiles as imagery, vector tiles
     * per advertised layer by geometry type — familiar marine layer names in
     * a chart-like scheme, everything else a distinct hue. Honest geometry,
     * not the publisher's portrayal.
     */
    private fun wrapperStyle(link: String, tilejson: JSONObject): String {
        val vls = tilejson.optJSONArray("vector_layers")
        val layers = JSONArray()
        layers.put(JSONObject().put("id", "bg").put("type", "background")
            .put("paint", JSONObject().put("background-color", "#c9e2f0")))
        val source = JSONObject().put("url", link)
        if (vls == null || vls.length() == 0) {
            source.put("type", "raster")
            layers.put(JSONObject().put("id", "tiles").put("type", "raster").put("source", "tiles"))
        } else {
            source.put("type", "vector")
            val hues = doubleArrayOf(210.0, 30.0, 120.0, 275.0, 0.0, 165.0, 55.0, 320.0)
            for (i in 0 until vls.length()) {
                val lid = vls.optJSONObject(i)?.optString("id")?.takeIf { it.isNotEmpty() } ?: continue
                val low = lid.lowercase()
                var fill = "hsla(${hues[i % hues.size]},55%,62%,0.35)"
                var line = "hsl(${hues[i % hues.size]},60%,38%)"
                var point = "hsl(${hues[i % hues.size]},65%,40%)"
                var radius = 2.5
                when {
                    low.contains("depare") || low.contains("depth") || low.contains("bathy") -> {
                        fill = "hsla(205,60%,70%,0.5)"; line = "hsl(205,45%,55%)"; point = "hsl(205,45%,45%)"
                    }
                    low.contains("contour") -> {
                        fill = "hsla(205,30%,60%,0.15)"; line = "hsl(205,35%,55%)"; point = "hsl(205,35%,45%)"
                    }
                    low.contains("sound") -> {
                        point = "hsl(210,25%,35%)"; radius = 1.5
                        fill = "hsla(210,25%,55%,0.2)"; line = "hsl(210,25%,55%)"
                    }
                    low.contains("land") || low.contains("coast") -> {
                        fill = "hsla(45,45%,70%,0.9)"; line = "hsl(45,30%,40%)"; point = "hsl(45,30%,40%)"
                    }
                }
                layers.put(JSONObject().put("id", "$lid-fill").put("type", "fill")
                    .put("source", "tiles").put("source-layer", lid)
                    .put("filter", JSONArray(listOf("==", listOf("geometry-type"), "Polygon")))
                    .put("paint", JSONObject().put("fill-color", fill)))
                layers.put(JSONObject().put("id", "$lid-line").put("type", "line")
                    .put("source", "tiles").put("source-layer", lid)
                    .put("filter", JSONArray(listOf("==", listOf("geometry-type"), "LineString")))
                    .put("paint", JSONObject().put("line-color", line).put("line-width", 1.0)))
                layers.put(JSONObject().put("id", "$lid-pt").put("type", "circle")
                    .put("source", "tiles").put("source-layer", lid)
                    .put("filter", JSONArray(listOf("==", listOf("geometry-type"), "Point")))
                    .put("paint", JSONObject().put("circle-radius", radius).put("circle-color", point)))
            }
        }
        return JSONObject()
            .put("version", 8)
            .put("name", tilejson.optString("name").ifEmpty { "Tiles" })
            .put("sources", JSONObject().put("tiles", source))
            .put("layers", layers)
            .toString()
    }

    private fun fetch(url: String): String? = runCatching {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = 10_000
        conn.readTimeout = 10_000
        try {
            if (conn.responseCode != 200) return null
            conn.inputStream.bufferedReader().readText()
        } finally {
            conn.disconnect()
        }
    }.getOrNull()

    private fun load(): List<Link> = runCatching {
        val arr = JSONArray(prefs.getString(KEY_LINKS, "[]") ?: "[]")
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val url = o.optString("url").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            Link(url, o.optString("name").ifEmpty { url }, o.optString("doc").takeIf { it.isNotEmpty() })
        }
    }.getOrDefault(emptyList())

    private fun persist() {
        val arr = JSONArray()
        for (l in links) {
            val o = JSONObject().put("url", l.url).put("name", l.name)
            if (l.doc != null) o.put("doc", l.doc)
            arr.put(o)
        }
        prefs.edit()
            .putString(KEY_LINKS, arr.toString())
            .putString(KEY_ACTIVE, active)
            .apply()
    }

    private companion object {
        const val PREFS = "chartlinks"
        const val KEY_LINKS = "links"
        const val KEY_ACTIVE = "active"
    }
}
