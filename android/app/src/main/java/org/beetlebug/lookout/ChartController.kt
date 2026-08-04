package org.beetlebug.lookout

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** One feature under the cursor: S-57 object class, its acronym, source cell. */
data class PickFeature(val cls: String, val s57: String, val chart: String)

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
 * The bridge between [LookoutView] (which owns the Surface and the engine
 * handle) and the Compose chrome. The Android analogue of ChartController.swift
 * plus AppModel.
 *
 * Threading: every public entry point is called on the main thread, but the
 * native calls are POSTED to the render thread ([engine]) — the api lock is held
 * for a whole frame, so calling in directly froze the UI for that long. Results
 * that drive Compose state hop back via [main]. LookoutView stops the render
 * thread before close(), so queued work always drains against a live handle.
 */
class ChartController(private val appContext: Context) {

    @Volatile private var lk: Lookout? = null

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

    /** Live HUD state. */
    var readouts by mutableStateOf(Readouts())
        private set

    /** Result of the last tap-to-identify; empty hides the report. */
    var identify by mutableStateOf<List<PickFeature>>(emptyList())

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
        restoreView(l)
        val loaded = date
        main.post { mariner.loadFrom(v, loaded) }
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
     * Drop [l]'s handle — but only if it is still the live one. Switching chart
     * library recreates the SurfaceView, and the outgoing view's
     * surfaceDestroyed can land AFTER the incoming view has already attached;
     * clearing unconditionally would leave the controller detached from a live
     * engine (a frozen HUD, dead settings) until the next surface change.
     */
    fun detach(l: Lookout?) {
        if (l != null && lk !== l) return
        saveView() // last known pose; the handle is about to close
        engine = null
        lk = null
        identify = emptyList()
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
        if (r == lastPushed) return
        lastPushed = r
        main.post { readouts = r }
        // Persist periodically as well: a swipe-away or a low-memory kill never
        // reaches detach().
        if (frameTimeNanos - lastSaveNs >= SAVE_INTERVAL_NS) {
            lastSaveNs = frameTimeNanos
            saveView()
        }
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
            identify = found
            identifyIndex = 0
            identifyPoint = if (found.isEmpty()) null else where
            pickPose = if (found.isEmpty()) null else pose
        }
    }

    fun dismissIdentify() {
        identify = emptyList()
        identifyIndex = 0
        identifyPoint = null
        pickPose = null
    }

    private companion object {
        /** ~10 Hz: fast enough to feel live, slow enough not to drive layout. */
        const val PUSH_INTERVAL_NS = 100_000_000L

        /** Cheap (an async prefs write), but there is no point doing it often. */
        const val SAVE_INTERVAL_NS = 3_000_000_000L
    }
}
