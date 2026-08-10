package org.beetlebug.lookout

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** One feature under the cursor: S-57 object class, its acronym, source cell. */
data class PickFeature(val cls: String, val s57: String, val chart: String)

/**
 * What a plugin overlay symbol says about itself — an AIS target's name, MMSI,
 * speed and closest approach, say. Decoded from the JSON the core's overlay
 * pick returns: {"title":"…","rows":[["key","value"],…]}.
 *
 * The shell renders the rows it is given and knows nothing about what any of
 * them mean; the plugin that drew the symbol chose them.
 */
data class OverlayInfo(val title: String, val rows: List<Pair<String, String>>) {
    companion object {
        fun parse(json: String?): OverlayInfo? {
            if (json.isNullOrEmpty()) return null
            return try {
                val top = org.json.JSONObject(json)
                val title = top.optString("title")
                if (title.isEmpty()) return null
                val arr = top.optJSONArray("rows")
                val rows = buildList {
                    for (i in 0 until (arr?.length() ?: 0)) {
                        val r = arr!!.optJSONArray(i) ?: continue
                        if (r.length() >= 2) add(r.optString(0) to r.optString(1))
                    }
                }
                OverlayInfo(title, rows)
            } catch (e: Exception) {
                null
            }
        }
    }
}

/**
 * One overlay object the mariner pinned: which object it is, what it says now,
 * and where it draws now. Re-read from the core every frame rather than
 * remembered — the target moves, its values change, and it eventually goes.
 */
data class OverlayPin(val id: String, val info: OverlayInfo, val lon: Double, val lat: Double)

/** Everything the HUD shows, refreshed off the frame loop. */
data class Readouts(
    val lon: Double = 0.0,
    val lat: Double = 0.0,
    val zoom: Double = 0.0,
    val rotationDeg: Double = 0.0,
    val overscale: Double = 1.0,
    val scaleDenominator: Double = 0.0,
    val building: Boolean = false,
)

/**
 * The bridge between [ChartEngine] (which owns the handle and the thread it
 * runs on) and the Compose chrome. The Android analogue of ChartController.swift
 * plus AppModel.
 *
 * Threading: every public entry point is called on the main thread, but the
 * native calls are POSTED to the render thread ([engine]) — the api lock is held
 * for a whole frame, so calling in directly froze the UI for that long. Results
 * that drive Compose state hop back via [main]. The engine stops the frame loop
 * before it closes, so queued work always drains against a live handle.
 *
 * It outlives no more than one Activity, while the engine outlives many, so an
 * engine that is already open binds to a fresh controller through [rebind].
 */
class ChartController(private val appContext: Context) {

    @Volatile private var lk: Lookout? = null

    /**
     * Where the wasm plugin set was extracted to (filesDir/plugins), or null in
     * a build that ships none. Set by the Activity before the first surface, so
     * it is written once on the main thread and read on the render thread.
     */
    @Volatile var pluginDir: String? = null

    /** "host:port" for the NMEA source, from the launch intent. See the Activity. */
    @Volatile var nmeaAddress: String? = null

    /**
     * The plugin settings registry — every loaded plugin with its schema and
     * the values in force. What the settings screen renders its plugin-declared
     * sections from; empty until the layer is up, and re-read whenever a change
     * is applied, since the core answers with the values as clamped.
     */
    var pluginRegistry by mutableStateOf(PluginRegistry())
        private set

    /** Re-read the registry from the core. Safe to call on any thread. */
    fun refreshPlugins() = onEngine { l -> republish(l) }

    /**
     * Apply one plugin's settings and re-read the registry, because the core
     * clamps a number outside its range and ignores a key the schema does not
     * declare — so what the mariner asked for is not always what is in force.
     */
    fun setPluginConfig(id: String, json: String) = onEngine { l ->
        if (!l.pluginConfigSet(id, json)) Log.w(TAG, "plugin config refused: $id $json")
        republish(l)
    }

    /**
     * Replace one repeating list whole and persist it — the shape the core takes
     * (see `normalizeRows` in src/plugin/host.zig): every edit sends the entire
     * array, and what comes back is what is in force after the host clamped it.
     *
     * Saved as well as sent, because a gateway typed at the helm has to survive
     * the next launch.
     */
    fun setPluginList(list: PluginListSchema, rows: List<PluginRow>) {
        val json = list.rowsJson(rows)
        PluginPrefs.saveRows(appContext, list, json)
        setPluginConfig(list.pluginId, org.json.JSONObject().put(list.key, org.json.JSONArray(json)).toString())
    }

    /**
     * Re-read the registry and publish it, but only when the JSON actually
     * moved. The settings screen polls this at 1 Hz for the connection lines,
     * and republishing an identical registry would recompose the whole pane on
     * every tick.
     *
     * RENDER THREAD only: [lastPluginsJson] is its own.
     */
    private var lastPluginsJson: String? = null

    private fun republish(l: Lookout) {
        val json = l.pluginsJson()
        if (json != null && json == lastPluginsJson) return
        lastPluginsJson = json
        val reg = PluginRegistry.parse(json)
        main.post { pluginRegistry = reg }
    }

    // ---- live plugin status -------------------------------------------------
    //
    // A connection's line has to move on its own: "Reconnecting" that never
    // becomes "Connected" is how a mariner learns the address is wrong. The
    // plugins rebuild their status every two seconds; this samples it while the
    // settings screen is on, and stops when it closes.

    @Volatile private var polling = false

    private val pollTick = object : Runnable {
        override fun run() {
            if (!polling) return
            refreshPlugins()
            main.postDelayed(this, PLUGIN_POLL_MS)
        }
    }

    fun startPluginPolling() {
        if (polling) return
        polling = true
        main.post(pollTick)
    }

    fun stopPluginPolling() {
        polling = false
        main.removeCallbacks(pollTick)
    }

    private val main = Handler(Looper.getMainLooper())

    /** The render thread's queue; null while detached. */
    @Volatile private var engine: Handler? = null

    /** Run [block] on the render thread, or drop it if there is no engine. */
    private fun onEngine(block: (Lookout) -> Unit) {
        val h = engine ?: return
        h.post { lk?.let(block) }
    }
    private val readoutBuf = DoubleArray(Lookout.READOUTS_LEN)
    private val geoBuf = DoubleArray(2)

    // The pinned bubble is re-read every frame, so its two crossings reuse
    // their buffers rather than allocating on the frame loop. Both are touched
    // only from the render thread (identifyAt and followPin both run there).
    private val pinLonLat = DoubleArray(2)
    private val screenBuf = FloatArray(2)

    /** Live HUD state. */
    var readouts by mutableStateOf(Readouts())
        private set

    /**
     * False until the first frame has rendered. The open is tens of seconds on
     * a real library, and until it ends the surface is bare, so the loader
     * stands over it.
     */
    var rendering by mutableStateOf(false)
        private set

    /** Result of the last tap-to-identify; empty hides the report. */
    var identify by mutableStateOf<List<PickFeature>>(emptyList())

    /**
     * The pinned overlay bubble, and where on screen it is anchored (logical
     * pts). Both are refreshed off the frame loop, so the bubble travels with
     * its target as the vessel moves and as the chart pans, zooms and turns.
     */
    var pinned by mutableStateOf<OverlayPin?>(null)
        private set
    var pinnedPoint by mutableStateOf<Offset?>(null)
        private set

    /**
     * The pinned id as the RENDER thread sees it. `pinned` is Compose state and
     * belongs to the main thread; the frame loop needs the id without reading
     * it, and gets the answer back to Compose with a post.
     */
    @Volatile private var pinnedId: String? = null

    /** What the render thread last told Compose, so it can skip saying it again. */
    private var postedPin: OverlayPin? = null
    private var postedPoint: Offset? = null

    /**
     * Every alert the plugins have raised, most urgent first. The banner over
     * the chart is built from this.
     */
    var alerts by mutableStateOf<List<PluginAlert>>(emptyList())
        private set

    private val siren = AlarmSiren(appContext)

    /**
     * The set the core last reported, as its `seq`. The list is rebuilt only
     * when it moves. [ALERTS_UNREAD] is never a real seq, which is what lets it
     * stand for "the core has not answered".
     */
    private var alertSeq = ALERTS_UNREAD
    private var lastAlertNs = 0L

    /** Which object of the pick the report shows. */
    var identifyIndex by mutableStateOf(0)

    /** Where the pick happened, in logical points, or null when none is open. */
    var identifyPoint by mutableStateOf<Offset?>(null)

    /**
     * The camera pose the open report belongs to, or null when none is open.
     *
     * A report describes the objects under one point of one view. Any move of
     * the chart retires it, so the report never floats over water it does not
     * describe. Read on the render thread by [onFrameRendered], which is what
     * sees every move: a pan runs there, not through this class.
     */
    @Volatile private var pickPose: Readouts? = null

    /** The editable S-52 mariner state the settings sheet binds to. */
    val mariner = MarinerState()

    /** The mariner's installed raster charts, persisted across opens. */
    val rasterCharts = RasterCharts(appContext)

    /** What the pill shows. Refreshed every pushed frame: `inView` moves. */
    var raster by mutableStateOf(RasterState())
        private set

    val isOpen: Boolean get() = lk != null

    // ---- lifecycle (called by LookoutView) ---------------------------------

    /**
     * Called ON THE RENDER THREAD right after the engine opens and before the
     * frame loop starts, so the mariner's saved settings and the saved view are
     * in place before the first tessellation — otherwise the chart builds once
     * at defaults and immediately rebuilds.
     *
     * The native calls and the prefs read belong here; only the form state has
     * to hop to main, Compose state being main-thread-only.
     */
    fun attach(l: Lookout, queue: Handler) {
        lk = l
        engine = queue
        val v = DoubleArray(Lookout.MARINER_LEN)
        l.getMariner(v)                       // the engine's own defaults
        var date = l.getMarinerDate()
        MarinerState.applySavedOverlay(appContext, v)?.let { date = it }
        l.setMariner(v, date)
        lastPushed = null
        alertSeq = ALERTS_UNREAD
        lastAlertNs = 0L
        restoreView(l)
        // Replay the installed raster charts into the chart just opened. The
        // engine holds what is open now; the mariner's own material has to
        // survive a change of ENC, so it is installed again on every open.
        for (p in rasterCharts.paths) {
            if (!l.rasterAdd(p)) Log.w(TAG, "raster chart will not open: $p")
            else if (!rasterCharts.isEnabled(p)) l.rasterSetEnabled(p, false)
        }
        pushRaster(l)
        loadPlugins(l)
        val loaded = date
        main.post { mariner.loadFrom(v, loaded) }
    }

    /**
     * Bring the wasm plugin layer up on the chart just opened. Like the raster
     * charts above this runs on every open, not once: the layer belongs to the
     * engine handle, and switching chart library makes a new one.
     *
     * The set is the one LookoutActivity extracted out of the APK assets, loaded
     * through the ordinary directory call — nothing sets LOOKOUT_PLUGINS here,
     * so the host files them as `bundled` and the ids belong to the application.
     */
    private fun loadPlugins(l: Lookout) {
        val dir = pluginDir ?: return
        if (!l.pluginsLoad(dir)) {
            Log.w(TAG, "plugins: none loaded from $dir (no host in this build?)")
            return
        }
        // What actually came up, by id — the answer to "did the module load"
        // that a screenshot cannot give.
        val json = l.pluginsJson()
        Log.i(TAG, "plugins: active=${l.pluginsActive()} ${summarize(json)}")
        val restored = restoreLists(l, PluginRegistry.parse(json))
        // The developer override, and only where the mariner has said nothing:
        // a list they have edited is the truth, empty or not.
        nmeaAddress?.let { addr ->
            if (restored.contains("org.beetlebug.nmea0183/connections")) {
                Log.i(TAG, "plugins: -e nmea ignored; the saved connection list wins")
            } else {
                configureNmea(l, addr)
            }
        }
        // After the restore, so the registry the settings screen first sees
        // already holds the mariner's own connections.
        val reg = PluginRegistry.parse(l.pluginsJson())
        Log.i(
            TAG,
            "plugins: sections ${reg.sections.joinToString(", ") { it.id }}" +
                " | managed ${reg.managed.size} of ${reg.plugins.size}",
        )
        lastPluginsJson = l.pluginsJson()
        main.post { pluginRegistry = reg }
    }

    /**
     * Push the mariner's saved connection lists into the plugins that just came
     * up, and answer which lists had one. Like the raster charts, this runs on
     * every open: the plugin layer belongs to the engine handle, and a new chart
     * library makes a new one with the manifests' defaults back in place.
     *
     * A saved list REPLACES whatever the host seeded, which is what makes the
     * editor authoritative over the launch intent.
     */
    private fun restoreLists(l: Lookout, reg: PluginRegistry): Set<String> {
        val done = mutableSetOf<String>()
        for (p in reg.plugins) {
            for (list in p.lists) {
                val saved = PluginPrefs.savedRows(appContext, list) ?: continue
                val body = org.json.JSONObject()
                    .put(list.key, org.json.JSONArray(saved))
                    .toString()
                val ok = l.pluginConfigSet(p.id, body)
                Log.i(TAG, "plugins: ${p.id}/${list.key} restored ${if (ok) "ok" else "REFUSED"}")
                if (ok) done.add("${p.id}/${list.key}")
            }
        }
        return done
    }

    /**
     * Point the NMEA 0183 source at one gateway from the launch intent:
     *
     *     adb shell am start -n … -e nmea 127.0.0.1:10110
     *
     * DEVELOPER ONLY. The mariner's route is Settings › Connections, which
     * writes the same list and persists it; this only seeds a machine that has
     * never had a connection typed into it, so a test rig can come up pointing
     * at a replay without anybody touching the screen. It never overrides a
     * saved list — see the caller.
     */
    private fun configureNmea(l: Lookout, addr: String) {
        val host = addr.substringBeforeLast(':', addr)
        val port = addr.substringAfterLast(':', "").toIntOrNull() ?: 10110
        val row = """{"connections":[{"id":"adb","name":"","host":"$host","port":$port,"enabled":true}]}"""
        val ok = l.pluginConfigSet("org.beetlebug.nmea0183", row)
        Log.i(TAG, "plugins: -e nmea (developer) -> $host:$port ${if (ok) "set" else "REFUSED"}")
    }

    /**
     * The loaded ids out of the plugins JSON. Parsed rather than pattern
     * matched: a plugin's settings can carry list ROWS with their own "id", and
     * scanning the text for one reported a gateway row ("lookout-nmea") as
     * though it were a sixth plugin.
     */
    private fun summarize(json: String?): String {
        if (json.isNullOrEmpty()) return "(no plugin json)"
        val ids = try {
            val arr = org.json.JSONObject(json).getJSONArray("plugins")
            (0 until arr.length()).mapNotNull { arr.getJSONObject(it).optString("id").ifEmpty { null } }
        } catch (e: Exception) {
            return "(unreadable plugin json: $e)"
        }
        return if (ids.isEmpty()) "(none loaded)" else "loaded: ${ids.joinToString(", ")}"
    }

    /**
     * Put the camera back where it was left. Runs before the render thread
     * starts, like the mariner state above, so the first tessellation is
     * already at the restored pose instead of building the opening view and
     * immediately rebuilding. With nothing saved, the opening view is the
     * engine's own — the same policy every host gets from lookout_default_view.
     */
    private fun restoreView(l: Lookout) {
        val saved = ViewState.load(appContext)
        if (saved != null) l.setView(saved.lon, saved.lat, saved.zoom, saved.rotationDeg)
        else l.defaultView()
    }

    /**
     * Bind a controller to an engine that is ALREADY open, after the Activity
     * was destroyed and built again over a process that kept running. Every
     * effect [attach] has on the engine is already in place, so this only
     * reads: what is missing is this object's own state and the Compose state
     * behind it.
     *
     * MAIN THREAD; the reading is posted to [queue].
     */
    fun rebind(l: Lookout, queue: Handler) {
        lk = l
        engine = queue
        queue.post {
            lastPluginsJson = null // republish into a registry nobody has seen
            alertSeq = ALERTS_UNREAD
            lastAlertNs = 0L
            lastPushed = null
            lastRaster = null
            val v = DoubleArray(Lookout.MARINER_LEN)
            l.getMariner(v)
            val date = l.getMarinerDate()
            republish(l)
            publishAlerts(l)
            pushRaster(l)
            main.post { mariner.loadFrom(v, date) }
        }
    }

    /**
     * The surface is going but the engine is not. Persist the pose here: the
     * periodic save runs off the frame loop, and there are about to be no
     * frames.
     *
     * RENDER THREAD, inside the detach barrier.
     */
    fun onSurfaceDetached() {
        saveView()
    }

    /**
     * Drop [l]'s handle — but only if it is still the live one. Switching chart
     * library closes the engine and opens another; the outgoing close can land
     * AFTER the incoming open has already attached, and clearing unconditionally
     * would leave the controller detached from a live engine (a frozen HUD,
     * dead settings) until the next surface change.
     */
    fun detach(l: Lookout?) {
        if (l != null && lk !== l) return
        saveView() // last known pose; the handle is about to close
        engine = null
        lk = null
        rendering = false
        identify = emptyList()
        // The chart is going away with the plugins that raised the alarms, so
        // nothing is left to acknowledge and nothing may go on sounding.
        alerts = emptyList()
        siren.setSounding(false)
    }

    /** Persist the last sampled pose. No native call — [lastPushed] has it. */
    private fun saveView() {
        val r = lastPushed ?: return
        ViewState.save(appContext, r.lon, r.lat, r.zoom, r.rotationDeg)
    }

    // ---- readouts (render thread) ------------------------------------------

    @Volatile private var lastPushed: Readouts? = null
    private var lastPushNs = 0L
    private var lastSaveNs = 0L

    /**
     * Sample the engine for the HUD. Throttled and change-gated: the frame loop
     * runs at display rate, and pushing a new Readouts every frame would
     * recompose the HUD 120 times a second to redraw identical text.
     */
    fun onFrameRendered(frameTimeNanos: Long) {
        val l = lk ?: return
        // Before the HUD throttle: the bubble follows its target at frame rate,
        // the readouts at 10 Hz.
        followPin(l)
        sampleAlerts(l, frameTimeNanos)
        if (lastPushNs != 0L && frameTimeNanos - lastPushNs < PUSH_INTERVAL_NS) return
        lastPushNs = frameTimeNanos
        l.readouts(readoutBuf)
        val r = Readouts(
            lon = readoutBuf[Lookout.R_LON],
            lat = readoutBuf[Lookout.R_LAT],
            zoom = readoutBuf[Lookout.R_ZOOM],
            rotationDeg = readoutBuf[Lookout.R_ROTATION_DEG],
            overscale = readoutBuf[Lookout.R_OVERSCALE],
            scaleDenominator = readoutBuf[Lookout.R_SCALE_DENOM],
            building = readoutBuf[Lookout.R_BUILDING] != 0.0,
        )
        // The chart moved under an open report, so retire the report. This
        // covers every move, including the pan and the fling, which run on
        // this thread and never call into this class.
        pickPose?.let { pose ->
            if (r.lon != pose.lon || r.lat != pose.lat ||
                r.zoom != pose.zoom || r.rotationDeg != pose.rotationDeg
            ) {
                pickPose = null
                main.post { dismissIdentify() }
            }
        }
        // The pill appears and goes as the mariner sails in and out of the
        // coverage, so this is read on the frame, not only when something is
        // pressed. Cheap: a handful of calls over a handful of sets.
        pushRaster(l)
        if (r == lastPushed) return
        lastPushed = r
        main.post {
            readouts = r
            rendering = true
        }
        // Persist periodically as well: a swipe-away or a low-memory kill never
        // reaches detach().
        if (frameTimeNanos - lastSaveNs >= SAVE_INTERVAL_NS) {
            lastSaveNs = frameTimeNanos
            saveView()
        }
    }

    // ---- plugin alerts -----------------------------------------------------
    //
    // A plugin raises an alert from its own thread with no gesture behind it,
    // so nothing the mariner does brings one to the screen. The core offers no
    // way to be told: there is no callback for a raise, and the `seq` that says
    // the set moved is only reachable by building the whole alerts JSON. So
    // this SAMPLES, and says so.
    //
    // What it does not do is arm a clock of its own for it. The frame loop is
    // already running and already calls onFrameRendered every frame, so an idle
    // chart gains no wakeup it did not already have; this only decides how
    // often that existing visit crosses into the core. A second matches the
    // reference shell and is a fifth of the repeat, so an alarm is on screen
    // well before it sounds twice.

    /**
     * The engine's one visit with no surface, and so no frame loop. A source
     * plugin keeps receiving while the app is away and can raise a collision
     * alarm from its own thread with nothing on screen; this is what looks.
     *
     * Answers how long until the next visit, or 0 to stop. Nothing held and
     * nothing being chased means nothing can happen, so the visits end and a
     * backgrounded plotter with no instruments plugged in wakes for nothing.
     *
     * RENDER THREAD.
     */
    fun onBackgroundTick(l: Lookout): Long {
        publishAlerts(l)
        val c = connections(l)
        return when {
            c.live -> BACKGROUND_LIVE_MS
            c.trying -> BACKGROUND_TRYING_MS
            else -> 0L
        }
    }

    /** What the source plugins' connection rows say between them. */
    data class Connections(val live: Boolean, val trying: Boolean)

    /**
     * Read the connection rows out of the plugin registry. `live` is a session
     * actually open to a gateway; `trying` also covers the ones being dialled,
     * which is the difference between a boat under way and one whose gateway is
     * switched off. A paused, address-less or refused row is neither.
     *
     * RENDER THREAD: the native call takes the api lock.
     */
    fun connections(l: Lookout): Connections {
        var live = false
        var trying = false
        for (p in PluginRegistry.parse(l.pluginsJson()).plugins) {
            for (s in p.statusItems.values) {
                when (s.state) {
                    "connected" -> { live = true; trying = true }
                    "reconnecting", "unreachable" -> trying = true
                }
            }
        }
        return Connections(live, trying)
    }

    /**
     * Sample the core's alert list. RENDER THREAD, off the frame loop, like the
     * readouts and the pinned bubble.
     */
    private fun sampleAlerts(l: Lookout, frameTimeNanos: Long) {
        if (lastAlertNs != 0L && frameTimeNanos - lastAlertNs < ALERT_INTERVAL_NS) return
        lastAlertNs = frameTimeNanos
        publishAlerts(l)
    }

    /**
     * Read the alerts and hand the list to the UI when it has moved. RENDER
     * THREAD: [alertSeq] is its own, and the native call takes the api lock.
     *
     * Also called straight after an acknowledgement, so the row leaves the
     * chart on the press rather than at the next sample.
     */
    private fun publishAlerts(l: Lookout) {
        val got = PluginAlertSet.parse(l.pluginAlertsJson())
        if (got == null) {
            // Nothing came back. The sampling carries on: giving up here would
            // leave the boat deaf for the rest of the session because the core
            // once had nothing to say.
            if (alertSeq == ALERTS_UNREAD) return
            alertSeq = ALERTS_UNREAD
            main.post { applyAlerts(emptyList()) }
            return
        }
        if (got.seq == alertSeq) return
        alertSeq = got.seq
        main.post { applyAlerts(got.alerts) }
    }

    /** MAIN THREAD. The list and the siren move together. */
    private fun applyAlerts(next: List<PluginAlert>) {
        alerts = next
        // An alarm nobody has answered keeps sounding. A warning is shown and
        // never sounded, so it is not counted here.
        siren.setSounding(next.any { it.severity.audible && !it.acknowledged })
    }

    /**
     * Silence one alert and take it off the chart. ONE alert: a mariner who has
     * seen the vessel crossing ahead has not seen the one coming up astern, and
     * a control for both would hide the second.
     */
    fun acknowledgeAlert(alert: PluginAlert) = onEngine { l ->
        if (!l.pluginAlertAck(alert.id)) Log.w(TAG, "alert ack refused: ${alert.id}")
        publishAlerts(l)
    }

    // ---- raster charts -----------------------------------------------------

    @Volatile private var lastRaster: RasterState? = null

    /**
     * Read the pill's state off the engine. RENDER THREAD ONLY, like the
     * readouts: these are native calls, and the api lock is held for a frame.
     */
    private fun pushRaster(l: Lookout) {
        val n = l.rasterSetCount()
        val sets = ArrayList<RasterSet>(n)
        for (i in 0 until n) {
            sets.add(RasterSet(i, l.rasterSetName(i), l.rasterSetInView(i)))
        }
        val s = RasterState(
            name = l.rasterActiveName(),
            available = l.rasterAvailableName(),
            active = l.rasterActiveIndex(),
            sets = sets,
            chartHidden = l.chartHidden(),
        )
        if (s == lastRaster) return
        lastRaster = s
        main.post { raster = s }
    }

    /**
     * Install raster charts and draw the one just added, if it covers this
     * view. The mariner picked those files while looking at this water.
     */
    fun addRasterCharts(newPaths: List<String>) {
        val added = rasterCharts.add(newPaths)
        if (added.isEmpty()) return
        onEngine { l ->
            var opened = 0
            for (p in added) if (l.rasterAdd(p)) opened++
            if (opened > 0) {
                val name = RasterCharts.providerLabel(added.last())
                val n = l.rasterSetCount()
                for (i in 0 until n) {
                    if (l.rasterSetName(i) == name && l.rasterSetInView(i)) {
                        l.rasterSelect(i)
                        break
                    }
                }
            }
            pushRaster(l)
        }
    }

    /** Step to the next set covering the water in view, then to none. */
    fun cycleRaster() = onEngine { l -> l.rasterCycle(); pushRaster(l) }

    /** Draw set [i]. -1 turns off what is drawn over THIS view. */
    fun selectRasterSet(i: Int) = onEngine { l -> l.rasterSelect(i); pushRaster(l) }

    /** Hide the ENC wherever a raster chart covers, and show it again. */
    fun toggleChart() = onEngine { l -> l.toggleChart(); pushRaster(l) }

    /** Switch one chart off without removing it. */
    fun setRasterEnabled(path: String, on: Boolean) {
        rasterCharts.setEnabled(path, on)
        onEngine { l -> l.rasterSetEnabled(path, on); pushRaster(l) }
    }

    /** Switch a whole provider's charts together. */
    fun setRasterGroupEnabled(paths: List<String>, on: Boolean) {
        paths.forEach { rasterCharts.setEnabled(it, on) }
        onEngine { l ->
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
        rasterCharts.remove(path)
        onEngine { l -> l.rasterSetEnabled(path, false); pushRaster(l) }
    }

    // ---- mariner -----------------------------------------------------------

    /**
     * Push the edited settings to the engine and persist them. Debounced by the
     * caller (see ChartScreen) so dragging a slider doesn't thrash the engine
     * into a rebuild per frame. The values are snapshotted here so the render
     * thread never reads the form's array while the UI is editing it.
     */
    fun applyMariner() {
        val v = mariner.values.copyOf()
        val date = mariner.dateView
        onEngine { l ->
            l.setMariner(v, date)
            MarinerState.save(appContext, v, date)
        }
    }

    /**
     * Re-read the engine's mariner state into the UI. Needed after the
     * convenience toggles below, which change settings behind the form's back —
     * and they must persist too, or a scheme picked from the toolbar is lost on
     * relaunch while the same scheme picked in the sheet survives.
     */
    private fun syncMarinerFromEngine(l: Lookout) {
        val v = DoubleArray(Lookout.MARINER_LEN)
        l.getMariner(v)
        val date = l.getMarinerDate()
        MarinerState.save(appContext, v, date)
        main.post { mariner.loadFrom(v, date) }
    }

    // ---- actions -----------------------------------------------------------

    fun cycleScheme() = onEngine { l ->
        l.cycleScheme()
        syncMarinerFromEngine(l)
    }

    fun setScheme(s: Scheme) {
        mariner.scheme = s
        applyMariner()
    }

    /** Zoom about the view centre — what the +/- buttons do. */
    fun zoomBy(dz: Double, centreXPts: Float, centreYPts: Float) =
        onEngine { it.zoomAt(dz, centreXPts, centreYPts) }

    fun fitChart() = onEngine { it.fitChart() }

    /** Recentre on a coordinate, keeping the zoom and the rotation. */
    fun goTo(lat: Double, lon: Double) = onEngine { l ->
        val r = lastPushed
        l.setView(lon, lat, r?.zoom ?: 12.0, r?.rotationDeg ?: 0.0)
    }

    fun resetRotation() = onEngine { it.resetRotation() }

    fun memoryWarning() = onEngine { it.memoryWarning() }

    /**
     * Tap-to-identify at a point in logical points. A tap outside an open
     * report picks again, there. The report's own taps never arrive here,
     * because the card consumes them.
     */
    fun identifyAt(xPts: Float, yPts: Float) = onEngine { l ->
        val where = Offset(xPts, yPts)
        // An overlay symbol answers FIRST and takes the tap: a tap on a target
        // pins its bubble and does not also open the chart's pick report, or
        // the report would cover the target the mariner just asked about.
        // Tapping the target that is already pinned closes it — the touch
        // equivalent of the pointer platform's click-elsewhere, kept because a
        // finger is on the target and there may be nowhere clear to tap.
        val hit = l.overlayHit(xPts, yPts, pinLonLat)
        if (hit != null && hit.size >= 2) {
            val info = OverlayInfo.parse(hit[1])
            if (info != null) {
                val id = hit[0]
                val again = id == pinnedId
                val next = if (again) null else OverlayPin(id, info, pinLonLat[0], pinLonLat[1])
                val at = if (again) null else screenPointFor(l, pinLonLat[0], pinLonLat[1])
                pinnedId = if (again) null else id
                postedPin = next
                postedPoint = at
                main.post {
                    pinned = next
                    pinnedPoint = at
                    if (next != null) dismissIdentify()
                }
                return@onEngine
            }
        }
        // A tap on open water closes the bubble and picks the chart, as it did
        // before there were overlay objects to tap.
        pinnedId = null
        postedPin = null
        postedPoint = null
        l.screenToGeo(xPts, yPts, geoBuf)
        val flat = l.pick(geoBuf[0], geoBuf[1])
        val found = if (flat == null || flat.isEmpty()) {
            emptyList()
        } else {
            (flat.indices step 3).map { i ->
                PickFeature(
                    cls = flat[i],
                    s57 = flat.getOrElse(i + 1) { "" },
                    chart = flat.getOrElse(i + 2) { "" },
                )
            }
        }
        val pose = lastPushed
        main.post {
            pinned = null
            pinnedPoint = null
            identify = found
            identifyIndex = 0
            identifyPoint = if (found.isEmpty()) null else where
            pickPose = if (found.isEmpty()) null else pose
        }
    }

    /** Close the pinned bubble (its own close button, and the back gesture). */
    fun dismissPin() {
        pinnedId = null
        pinned = null
        pinnedPoint = null
        postedPin = null
        postedPoint = null
    }

    /**
     * Re-read the pinned object and re-project its anchor. Called every frame:
     * an AIS target moves under its own steam and the chart moves under the
     * mariner's, so a remembered screen point would drift off the symbol within
     * a second. A gone target (aged out, or its plugin stopped) closes the
     * bubble rather than leaving it pinned to water.
     */
    private fun followPin(l: Lookout) {
        val id = pinnedId ?: return
        val cur = l.overlayInfo(id, pinLonLat)
        if (cur == null || cur.size < 2) {
            pinnedId = null
            main.post { if (pinned?.id == id) dismissPin() }
            return
        }
        val info = OverlayInfo.parse(cur[1]) ?: return
        val next = OverlayPin(id, info, pinLonLat[0], pinLonLat[1])
        val at = screenPointFor(l, pinLonLat[0], pinLonLat[1])
        // Every frame, but posted only when something actually moved: the
        // anchor has to keep up with a pan (a 10 Hz bubble visibly lags the
        // symbol under it), while a target sitting still must not recompose
        // the bubble at display rate. The shadows are the render thread's own
        // copy of what Compose was last told, so the comparison never reads
        // Compose state off the main thread.
        if (next == postedPin && at == postedPoint) return
        postedPin = next
        postedPoint = at
        main.post {
            if (pinnedId != id) return@post          // retired while this hopped threads
            pinned = next
            pinnedPoint = at
        }
    }

    /** Where a geographic point lands on screen, in logical points. */
    private fun screenPointFor(l: Lookout, lon: Double, lat: Double): Offset {
        l.geoToScreen(lon, lat, screenBuf)
        return Offset(screenBuf[0], screenBuf[1])
    }

    fun dismissIdentify() {
        identify = emptyList()
        identifyIndex = 0
        identifyPoint = null
        pickPose = null
    }

    private companion object {
        const val TAG = "lookout"

        /** ~10 Hz: fast enough to feel live, slow enough not to drive layout. */
        const val PUSH_INTERVAL_NS = 100_000_000L

        /**
         * How often the settings screen re-reads the plugin status. The plugins
         * rebuild theirs every two seconds, so this is twice their cadence —
         * fast enough that a rate never looks stuck, and the republish is
         * skipped whenever nothing changed.
         */
        const val PLUGIN_POLL_MS = 1_000L

        /**
         * How often the frame loop crosses into the core for the alerts. See
         * the plugin alerts section for why this is a sample and not a wake.
         */
        const val ALERT_INTERVAL_NS = 1_000_000_000L

        /** No `seq` the core reports, so it can stand for "not answered yet". */
        const val ALERTS_UNREAD = -1L

        /**
         * The background visit's pace with a connection live. Matches the
         * frame loop's own alert sampling, and is a fifth of the alarm repeat,
         * so an alarm is heard well before it would have sounded twice.
         */
        const val BACKGROUND_LIVE_MS = 1_000L

        /**
         * The pace while a connection is only being dialled. Nothing can be
         * received until one answers, so this is watching for the answer and
         * nothing else.
         */
        const val BACKGROUND_TRYING_MS = 5_000L

        /** Cheap (an async prefs write), but there is no point doing it often. */
        const val SAVE_INTERVAL_NS = 3_000_000_000L
    }
}
