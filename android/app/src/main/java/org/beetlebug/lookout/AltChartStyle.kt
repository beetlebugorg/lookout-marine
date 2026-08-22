// An online map AS the chart: the shell fetches a publisher's MapLibre style,
// hands lookout the JSON, and then serves that style's tiles. The Android
// twin of AltChartStyle.swift.
//
// WHY THE FETCHING IS UP HERE. lookout does no networking (see lookout.h,
// lookout_set_tile_provider). It reports the SOURCE NAME and z/x/y of a tile
// it wants; this file resolves that against the style's own url template and
// answers with the app's own HTTP stack. The asks arrive through a JNI poll
// (the render thread must not touch the JVM), drained by one thread that
// hands each fetch to a small pool.
//
// WHY THE STYLE IS REWRITTEN ON THE WAY IN. A source may name its tiles
// inline (`"tiles": [...]`) or point at a TileJSON document (`"url": ...`).
// Only the first is something lookout can act on, so a TileJSON source is
// resolved HERE, once, and its answer inlined before the style goes down.
package org.beetlebug.lookout

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.abs

/** Where one source's tiles come from, by the name the style gave it. */
data class AltTileSource(
    /** The style's url templates, with {z}/{x}/{y} still in them. */
    val templates: List<String>,
    /** TMS counts y from the south; the style spec counts from the north. */
    val flipY: Boolean,
)

/** One sprite pack a style declares: the pack id as the icon-name prefix
 *  ("" for the spec's "default"), and the base url `.json`/`.png` append to. */
class SpritePack(val prefix: String, val url: String)

/** A sprite pack fetched whole, ready for the engine. */
class FetchedSpritePack(val prefix: String, val json: ByteArray, val png: ByteArray)

/** A chart style the host supplies, with its tile sources resolved. */
class AltChartStyle(
    /** The style JSON to hand to lookout: the publisher's, with every
     *  TileJSON source inlined. */
    val json: String,
    val sources: Map<String, AltTileSource>,
    /** Every distinct source attribution, tags stripped, joined for display.
     *  Public tile hosts require visible credit — OSM's tile usage policy
     *  makes it a condition of service, not a courtesy. */
    val attribution: String? = null,
    /** The style's sprite packs, still unfetched (network work is the
     *  caller's, off the main thread — fetchSpritePacks). */
    val spritePacks: List<SpritePack> = emptyList(),
) {
    companion object {
        private const val TAG = "lookout"

        /** Read a style and resolve every source in it. Network work — call
         *  off the main thread. */
        fun resolve(raw: String, localStyle: Boolean = false): AltChartStyle? {
            val top = try { JSONObject(raw) } catch (_: Exception) { return null }
            val declared = top.optJSONObject("sources") ?: return null
            val resolved = HashMap<String, AltTileSource>()
            for (name in declared.keys().asSequence().toList()) {
                val src = declared.optJSONObject(name) ?: continue
                // A TileJSON source names a document, not tiles. Read it and
                // fold what it says into the source itself.
                if (!src.has("tiles")) {
                    val link = src.optString("url")
                    // Only a style loaded from disk may read files its
                    // sources name; one fetched from the network may not.
                    val doc = if (link.isNotEmpty()) fetchJson(link, localStyle) else null
                    if (doc != null) {
                        for (key in listOf("tiles", "minzoom", "maxzoom", "bounds", "scheme", "attribution")) {
                            if (doc.has(key)) src.put(key, doc.get(key))
                        }
                        // TileJSON says `tileSize` nowhere; raster tiles are
                        // 256 unless the style already said otherwise, and
                        // getting this wrong draws the imagery one zoom off.
                        if (!src.has("tileSize") && src.optString("type") == "raster") {
                            src.put("tileSize", 256)
                        }
                        src.remove("url")
                    }
                }
                val templates = src.optJSONArray("tiles") ?: continue
                val list = (0 until templates.length()).mapNotNull { templates.optString(it).ifEmpty { null } }
                if (list.isEmpty()) continue
                resolved[name] = AltTileSource(
                    templates = list,
                    flipY = src.optString("scheme").lowercase() == "tms",
                )
            }
            return AltChartStyle(top.toString(), resolved, attributionOf(declared), spritePacksOf(top))
        }

        /** The style's `sprite` root: one base url, or the array form of
         *  {id, url} packs whose icons resolve as "id:name" ("default" gives
         *  bare names). */
        private fun spritePacksOf(top: JSONObject): List<SpritePack> {
            val v = top.opt("sprite") ?: return emptyList()
            if (v is String) return if (v.isEmpty()) emptyList() else listOf(SpritePack("", v))
            if (v !is JSONArray) return emptyList()
            val out = ArrayList<SpritePack>()
            for (i in 0 until v.length()) {
                val o = v.optJSONObject(i) ?: continue
                val url = o.optString("url")
                if (url.isEmpty()) continue
                val id = o.optString("id")
                out.add(SpritePack(if (id == "default") "" else id, url))
            }
            return out
        }

        /** Fetch a style's sprite packs whole, preferring the @2x sheet on a
         *  dense display (with the other density as the fallback — a pack
         *  publisher may ship only one). Network work — call off the main
         *  thread. A pack that will not fetch is skipped, not fatal: the
         *  chart draws, short its icons. */
        fun fetchSpritePacks(packs: List<SpritePack>): List<FetchedSpritePack> {
            if (packs.isEmpty()) return emptyList()
            val hidpi = android.content.res.Resources.getSystem().displayMetrics.density > 1.3f
            val suffixes = if (hidpi) listOf("@2x", "") else listOf("", "@2x")
            val out = ArrayList<FetchedSpritePack>()
            for (p in packs) {
                var got: FetchedSpritePack? = null
                for (s in suffixes) {
                    val j = fetchBytes(spriteVariant(p.url, s, ".json")) ?: continue
                    val b = fetchBytes(spriteVariant(p.url, s, ".png")) ?: continue
                    got = FetchedSpritePack(p.prefix, j, b)
                    break
                }
                if (got != null) out.add(got)
                else Log.w(TAG, "sprite pack ${p.url}: fetch failed; its icons will be missing")
            }
            return out
        }

        /** "…/sprite" + "@2x" + ".json", keeping a query string at the
         *  end: an API-keyed host serves …/sprite@2x.json?key=K, never
         *  …?key=K@2x.json. */
        private fun spriteVariant(base: String, density: String, ext: String): String {
            val q = base.indexOf('?')
            if (q < 0) return base + density + ext
            return base.substring(0, q) + density + ext + base.substring(q)
        }

        /** Accept only web urls. A fetched style must not be able to point
         *  a sub-resource at file:///data/... or another local scheme. The
         *  HttpURLConnection cast below would already fail for those; this
         *  makes the rule explicit. */
        fun allowedUrl(link: String): Boolean =
            link.startsWith("https://") || link.startsWith("http://")

        fun fetchBytes(link: String): ByteArray? {
            if (!allowedUrl(link)) return null
            return try {
                val conn = URL(link).openConnection() as HttpURLConnection
                identify(conn)
                conn.connectTimeout = 20_000
                conn.readTimeout = 20_000
                try {
                    if (conn.responseCode != 200) null
                    else conn.inputStream.use { it.readBytes() }
                } finally {
                    conn.disconnect()
                }
            } catch (e: Exception) {
                Log.w(TAG, "fetch $link: $e")
                null
            }
        }

        /** The credit line the sources ask for: distinct attributions in
         *  source order, HTML markup reduced to its text. An attribution
         *  CONTAINED in another is dropped — sources repeat each other's
         *  credits inside composite strings, and keeping both made the line
         *  longer than the scale bar it sits under. */
        private fun attributionOf(declared: JSONObject): String? {
            val seen = LinkedHashSet<String>()
            for (name in declared.keys().asSequence().toList()) {
                val src = declared.optJSONObject(name) ?: continue
                val raw = src.optString("attribution")
                if (raw.isEmpty()) continue
                val text = raw
                    .replace(Regex("<[^>]*>"), "")
                    .replace("&copy;", "©")
                    .replace("&lt;", "<")
                    .replace("&gt;", ">")
                    .replace("&quot;", "\"")
                    .replace("&#39;", "'")
                    .replace("&nbsp;", " ")
                    .replace("&amp;", "&")
                    .trim()
                if (text.isNotEmpty()) seen.add(text)
            }
            val kept = seen.filter { s -> seen.none { t -> t !== s && t.contains(s) } }
            return if (kept.isEmpty()) null else kept.joinToString(" · ")
        }

        /**
         * Read a link and work out what chart it is: a whole MapLibre style
         * (keep the url and fetch it each time), or a TileJSON — tiles with
         * no style of their own, which get a generated wrapper. A publisher
         * shipping a TileJSON almost always ships the style beside it, so the
         * sibling `style.json` is probed first. A file:// or plain path is a
         * mariner's own style off the disk, carried as TEXT.
         *
         * Returns (url, name, doc-or-null), or null when nothing is there.
         */
        fun probeChartLink(raw: String): Triple<String, String, String?>? {
            val trimmed = raw.trim()
            val fileText = readFileLink(trimmed)
            if (fileText != null) {
                val obj = try { JSONObject(fileText) } catch (_: Exception) { return null }
                if (!obj.has("layers") || !obj.has("version")) return null
                val stem = File(trimmed.removePrefix("file://")).nameWithoutExtension
                val n = obj.optString("name").ifEmpty { stem }
                return Triple(trimmed, n, fileText)
            }
            val obj = fetchJson(trimmed, allowFile = true) ?: return null
            val host = try { URL(trimmed).host ?: trimmed } catch (_: Exception) { trimmed }
            val named = obj.optString("name").ifEmpty { host }
            if (obj.has("layers") && obj.has("version")) return Triple(trimmed, named, null)
            if (obj.has("tiles") || obj.has("tilejson")) {
                siblingStyle(trimmed)?.let { return Triple(it.first, it.second, null) }
                return Triple(trimmed, named, tileJsonWrapperStyle(trimmed, obj))
            }
            return null
        }

        /** The style.json living beside a TileJSON, when the publisher
         *  shipped one. Only if it parses as a MapLibre style. */
        private fun siblingStyle(link: String): Pair<String, String>? {
            val url = try { URL(link) } catch (_: Exception) { return null }
            val path = url.path.substringBeforeLast('/', "")
            val candidate = URL(url.protocol, url.host, url.port, "$path/style.json").toString()
            if (candidate == link) return null
            val obj = fetchJson(candidate, allowFile = false) ?: return null
            if (!obj.has("layers") || !obj.has("version")) return null
            return candidate to obj.optString("name").ifEmpty { url.host ?: candidate }
        }

        /**
         * A style for a bare tile source. Raster tiles draw as imagery.
         * Vector tiles draw each advertised layer in a legible generic scheme
         * — honest geometry, not the publisher's portrayal (a tile source
         * doesn't carry one). The look matches the reference shell's wrapper.
         */
        fun tileJsonWrapperStyle(link: String, tilejson: JSONObject): String {
            val vectorLayers = tilejson.optJSONArray("vector_layers")
            val layers = JSONArray()
            layers.put(JSONObject().put("id", "bg").put("type", "background")
                .put("paint", JSONObject().put("background-color", "#c9e2f0")))
            val source = JSONObject().put("url", link)
            if (vectorLayers == null || vectorLayers.length() == 0) {
                source.put("type", "raster")
                layers.put(JSONObject().put("id", "tiles").put("type", "raster").put("source", "tiles"))
            } else {
                source.put("type", "vector")
                val hues = listOf(210.0, 30.0, 120.0, 275.0, 0.0, 165.0, 55.0, 320.0)
                for (i in 0 until vectorLayers.length()) {
                    val lid = vectorLayers.optJSONObject(i)?.optString("id")?.ifEmpty { null } ?: continue
                    val low = lid.lowercase()
                    val hue = hues[i % hues.size]
                    var fill = "hsla($hue,55%,62%,0.35)"
                    var line = "hsl($hue,60%,38%)"
                    var point = "hsl($hue,65%,40%)"
                    var pointRadius = 2.5
                    if ("depare" in low || "depth" in low || "bathy" in low) {
                        fill = "hsla(205,60%,70%,0.5)"; line = "hsl(205,45%,55%)"; point = "hsl(205,45%,45%)"
                    } else if ("contour" in low) {
                        fill = "hsla(205,30%,60%,0.15)"; line = "hsl(205,35%,55%)"; point = "hsl(205,35%,45%)"
                    } else if ("sound" in low) {
                        point = "hsl(210,25%,35%)"; pointRadius = 1.5
                        fill = "hsla(210,25%,55%,0.2)"; line = "hsl(210,25%,55%)"
                    } else if ("land" in low || "coast" in low) {
                        fill = "hsla(45,45%,70%,0.9)"; line = "hsl(45,30%,40%)"; point = "hsl(45,30%,40%)"
                    }
                    fun filter(kind: String) = JSONArray().put("==").put(JSONArray().put("geometry-type")).put(kind)
                    layers.put(JSONObject().put("id", "$lid-fill").put("type", "fill").put("source", "tiles")
                        .put("source-layer", lid).put("filter", filter("Polygon"))
                        .put("paint", JSONObject().put("fill-color", fill)))
                    layers.put(JSONObject().put("id", "$lid-line").put("type", "line").put("source", "tiles")
                        .put("source-layer", lid).put("filter", filter("LineString"))
                        .put("paint", JSONObject().put("line-color", line).put("line-width", 1.0)))
                    layers.put(JSONObject().put("id", "$lid-pt").put("type", "circle").put("source", "tiles")
                        .put("source-layer", lid).put("filter", filter("Point"))
                        .put("paint", JSONObject().put("circle-radius", pointRadius).put("circle-color", point)))
                }
            }
            return JSONObject()
                .put("version", 8)
                .put("name", tilejson.optString("name").ifEmpty { "Tiles" })
                .put("sources", JSONObject().put("tiles", source))
                .put("layers", layers)
                .toString()
        }

        /** A style document off the disk, for a file:// link or a plain path;
         *  null when the link is not a file. */
        private fun readFileLink(link: String): String? {
            val path = when {
                link.startsWith("file://") -> link.removePrefix("file://")
                link.startsWith("/") -> link
                else -> return null
            }
            return try { File(path).readText() } catch (_: Exception) { null }
        }

        fun fetchJson(link: String, allowFile: Boolean): JSONObject? {
            val text = fetchText(link, allowFile) ?: return null
            return try { JSONObject(text) } catch (_: Exception) { null }
        }

        /** allowFile marks a link the user typed, or one derived from it.
         *  Only those may read the disk; a url found inside a document
         *  fetched from the network must never reach the file branch. */
        fun fetchText(link: String, allowFile: Boolean = true): String? {
            if (allowFile) readFileLink(link)?.let { return it }
            return try {
                val conn = URL(link).openConnection() as HttpURLConnection
                identify(conn)
                conn.connectTimeout = 20_000
                conn.readTimeout = 20_000
                try {
                    if (conn.responseCode != 200) null
                    else conn.inputStream.use { it.readBytes() }.toString(Charsets.UTF_8)
                } finally {
                    conn.disconnect()
                }
            } catch (e: Exception) {
                Log.w(TAG, "chart link $link: $e")
                null
            }
        }

        /**
         * Say who is asking, on every chart-link request. Public tile hosts
         * serve "access blocked" placeholder tiles to anonymous or
         * platform-default agents — openstreetmap.org's tile usage policy
         * (osm.wiki/Blocked_tiles) wants a unique, identifiable User-Agent
         * with a way to reach the developer, and the Referer names the app's
         * home for hosts that key on it.
         */
        fun identify(conn: HttpURLConnection) {
            conn.setRequestProperty("User-Agent", USER_AGENT)
            conn.setRequestProperty("Referer", REFERER)
        }

        const val USER_AGENT =
            "LookoutMarine/1.0 (Android; org.beetlebug.lookout; contact jeremy.collins@beetlebug.org)"
        const val REFERER = "https://beetlebug.org/"
    }
}

/**
 * Answers lookout's asks for an alt style's tiles: one thread drains the JNI
 * ring, a small pool fetches, and every ask is ANSWERED — bytes, "no tile
 * there", or "failed" — because a tile nobody answers is a hole in the chart
 * that never fills.
 *
 * The poll runs ONLY while a style is active (started with the style, stopped
 * with it), so an idle chart on lookout's own portrayal costs nothing.
 */
class AltChartTiles {
    @Volatile private var live = false
    /** Serializes tileRespond against stop(). A fetch that has passed the
     *  live check must finish its JNI call before stop() returns, so the
     *  engine handle cannot be freed while an answer is still in flight. The
     *  network read happens before the lock is taken, so stop() waits
     *  milliseconds at most. */
    private val respondLock = Any()
    @Volatile private var sources: Map<String, AltTileSource> = emptyMap()
    private var engine: Lookout? = null
    private var pool: ExecutorService? = null
    private var poller: Thread? = null
    /** One line per source, not one per tile: enough to see the template
     *  resolved and the server answered. */
    private val loggedAsk = HashSet<String>()
    private val loggedFail = HashSet<String>()

    // start and stop are called from the main thread in the push flows and
    // from the render thread when a controller is replaced, so both are
    // synchronized.
    @Synchronized
    fun start(l: Lookout, s: Map<String, AltTileSource>) {
        sources = s
        synchronized(loggedAsk) { loggedAsk.clear() }
        synchronized(loggedFail) { loggedFail.clear() }
        if (live && engine === l) return
        stop()
        engine = l
        live = true
        // A level change asks ~50 tiles across several hosts; six workers keep
        // the tail short. No per-host throttle: a couple of slow or dead
        // requests to one host (a base map asked past the zoom it serves) must
        // not hold a lane and starve the rest.
        pool = Executors.newFixedThreadPool(6)
        poller = Thread({
            val ids = LongArray(64)
            val zxy = IntArray(192)
            val names = arrayOfNulls<String>(64)
            while (live) {
                val n = l.tilePoll(ids, zxy, names)
                if (n == 0) {
                    try { Thread.sleep(POLL_MS) } catch (_: InterruptedException) { break }
                    continue
                }
                for (i in 0 until n) {
                    val id = ids[i]
                    val name = names[i] ?: ""
                    val z = zxy[i * 3]; val x = zxy[i * 3 + 1]; val y = zxy[i * 3 + 2]
                    pool?.execute { fetch(l, name, id, z, x, y) }
                }
            }
        }, "lookout-alt-tiles").also { it.start() }
    }

    @Synchronized
    fun stop() {
        live = false
        poller?.let { p -> p.interrupt(); try { p.join(1_000) } catch (_: InterruptedException) {} }
        poller = null
        pool?.shutdownNow()
        pool = null
        // After this point no new respond can start, because live is read
        // under the lock, and none is mid-call, because taking the lock
        // waits for the last one to finish. Without this barrier a pool
        // thread could call into an engine handle the caller is about to
        // free.
        synchronized(respondLock) {}
        engine = null
    }

    /** Every answer funnels through here; see respondLock. */
    private fun respond(l: Lookout, id: Long, bytes: ByteArray?, status: Int) {
        synchronized(respondLock) {
            if (!live) return
            l.tileRespond(id, bytes, status)
        }
    }

    private fun fetch(l: Lookout, name: String, id: Long, z: Int, x: Int, y: Int) {
        val src = sources[name]
        val link = src?.let { url(it, z, x, y) }?.takeIf { AltChartStyle.allowedUrl(it) }
        if (link == null) {
            if (noteFirst(loggedFail, name)) {
                Log.w(TAG, "alt tiles: $name has no source, no url template, or not a web url; failing its tiles")
            }
            respond(l, id, null, FAILED)
            return
        }
        if (noteFirst(loggedAsk, name)) Log.i(TAG, "alt tiles: $name -> $link")
        try {
            fetchInto(l, name, id, z, x, y, link)
        } catch (e: Exception) {
            if (noteFirst(loggedFail, name)) Log.w(TAG, "alt tiles: $name z$z/$x/$y -> $e")
            respond(l, id, null, FAILED)
        }
    }

    private fun fetchInto(l: Lookout, name: String, id: Long, z: Int, x: Int, y: Int, link: String) {
        try {
            val conn = URL(link).openConnection() as HttpURLConnection
            AltChartStyle.identify(conn)
            // Short timeouts: a tile the chart is drawn without, and a style
            // that asks a base map past the zoom it actually serves (OSM over
            // open water) makes many requests that never answer. A long
            // timeout leaves those holding pool threads and the chart reads
            // as "building" until they expire.
            conn.connectTimeout = 8_000
            conn.readTimeout = 8_000
            try {
                val code = conn.responseCode
                when {
                    // The publisher genuinely has no tile there — a hole in
                    // their coverage, not a fault, and remembered as one.
                    code == 404 || code == 204 -> respond(l, id, null, NONE)
                    code == 200 -> {
                        val bytes = conn.inputStream.use { it.readBytes() }
                        if (bytes.isEmpty()) respond(l, id, null, NONE)
                        else respond(l, id, bytes, BYTES)
                    }
                    else -> {
                        if (noteFirst(loggedFail, name)) {
                            Log.w(TAG, "alt tiles: $name z$z/$x/$y -> $code")
                        }
                        respond(l, id, null, FAILED)
                    }
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            if (noteFirst(loggedFail, name)) Log.w(TAG, "alt tiles: $name z$z/$x/$y -> $e")
            respond(l, id, null, FAILED)
        }
    }

    private fun noteFirst(set: MutableSet<String>, name: String): Boolean =
        synchronized(set) { set.add(name) }

    companion object {
        private const val TAG = "lookout"
        private const val POLL_MS = 50L
        private const val BYTES = 0
        private const val NONE = 1
        private const val FAILED = 2

        /** Fill a style's url template for one tile. The subdomain pick is
         *  deterministic, so the same tile keeps hitting the same host and
         *  stays cached there. */
        fun url(src: AltTileSource, z: Int, x: Int, y: Int): String? {
            if (src.templates.isEmpty()) return null
            val template = src.templates[abs(x + y) % src.templates.size]
            val ty = if (src.flipY) (1 shl z) - 1 - y else y
            return template
                .replace("{z}", z.toString())
                .replace("{x}", x.toString())
                .replace("{y}", ty.toString())
        }
    }
}
