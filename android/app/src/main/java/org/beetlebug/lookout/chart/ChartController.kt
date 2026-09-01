package org.beetlebug.lookout.chart

import org.beetlebug.lookout.hud.LoadPhase
import org.beetlebug.lookout.hud.Readouts

import org.beetlebug.lookout.plugins.rowsJson

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.LookoutActivity
import org.beetlebug.lookout.charts.ChartLinkController
import org.beetlebug.lookout.charts.RasterController
import org.beetlebug.lookout.charts.RasterCharts
import org.beetlebug.lookout.charts.RasterSet
import org.beetlebug.lookout.charts.RasterState
import org.beetlebug.lookout.engine.ChartService
import org.beetlebug.lookout.engine.EngineAccess
import org.beetlebug.lookout.engine.LookoutView
import org.beetlebug.lookout.pick.AuxFile
import org.beetlebug.lookout.pick.OverlayInfo
import org.beetlebug.lookout.pick.OverlayPin
import org.beetlebug.lookout.pick.PickDecoded
import org.beetlebug.lookout.plugins.AlertController
import org.beetlebug.lookout.plugins.PluginSettingsController
import org.beetlebug.lookout.plugins.PluginAlert
import org.beetlebug.lookout.plugins.PluginAlertSet
import org.beetlebug.lookout.plugins.PluginField
import org.beetlebug.lookout.plugins.PluginListSchema
import org.beetlebug.lookout.plugins.PluginPrefs
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.plugins.PluginRow
import org.beetlebug.lookout.plugins.readTableRows
import org.beetlebug.lookout.plugins.TableBatch
import org.beetlebug.lookout.plugins.TableController
import org.beetlebug.lookout.plugins.TableSpec
import org.beetlebug.lookout.plugins.readTableSpecs
import org.beetlebug.lookout.plugins.trimmed
import org.beetlebug.lookout.settings.MarinerState
import org.beetlebug.lookout.settings.Scheme
import org.beetlebug.lookout.store.Store

import android.content.Context
import android.os.Handler
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File

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

    /**
     * The handle, the render thread and the way back to the main thread, in
     * one object. Held rather than reimplemented here so the parts this class
     * is being broken into can each take it and keep the same threading rule.
     */
    val access = EngineAccess()

    /** Set by the engine: wakes its idled frame loop after a mutation lands. */
    var onMutated: (() -> Unit)?
        get() = access.onMutated
        set(v) { access.onMutated = v }

    private fun onEngine(block: (Lookout) -> Unit) = access.onEngine(block)
    private val readoutBuf = DoubleArray(Lookout.READOUTS_LEN)
    private val geoBuf = DoubleArray(2)
    private val shipBuf = DoubleArray(2)

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

    /** Which step the startup loader is showing. */
    var loadPhase by mutableStateOf(LoadPhase.MAPPING)
        private set

    /** Called around the open on the render thread; the loader recomposes. */
    fun noteOpenPhase(p: LoadPhase) {
        access.onMain { loadPhase = p }
    }

    /** Result of the last tap-to-identify; empty hides the report. */
    var identify by mutableStateOf<List<PickDecoded>>(emptyList())
        private set

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

    /**
     * The pinned object's payload as the core last stated it, and what it
     * parsed to. RENDER THREAD, and only ever read against the id it belongs
     * to: both are cleared when the pin changes or goes.
     */
    private var pinnedPayload: String? = null
    private var pinnedInfo: OverlayInfo? = null

    /** What the render thread last told Compose, so it can skip saying it again. */
    private var postedPin: OverlayPin? = null
    private var postedPoint: Offset? = null

    /** What the plugins are alarming about, and the siren. */
    val alertsController = AlertController(appContext, access)

    /** Every alert the plugins have raised, most urgent first. */
    val alerts: List<PluginAlert> get() = alertsController.alerts

    /** Which object of the pick the report shows. */
    var identifyIndex by mutableStateOf(0)
        private set

    /** The report's object list, choosing which object is on show. */
    fun selectIdentify(index: Int) {
        identifyIndex = index
    }

    /** Where the pick happened, in logical points, or null when none is open. */
    var identifyPoint by mutableStateOf<Offset?>(null)
        private set

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

    /** The mariner's picture charts, and the HUD pill over them. */
    val rasterController = RasterController(access, RasterCharts(appContext))

    /** Charts by link: an online map AS the chart. */
    val chartLinkController = ChartLinkController(appContext, access)

    val rasterCharts get() = rasterController.charts

    /** Whether a chart link was the drawn chart last time. */
    val linkFirstHint: Boolean get() = chartLinkController.linkFirstHint

    val isOpen: Boolean get() = access.isOpen

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
        access.bind(l, queue)
        // The shell's settings file. The engine restores the pose and the
        // mariner's settings out of it, writes the pose down as the mariner
        // moves, and writes both at close and at detach.
        l.setStore(Store.handle)
        val v = DoubleArray(Lookout.MARINER_LEN)
        l.getMariner(v)
        val date = l.getMarinerDate()
        lastPushed = null
        alertsController.reset()
        lastWatchNs = 0L
        restoreView(l)
        rasterController.installAll(l)
        plugins.loadPlugins(l)
        // The core reads its chart-link list at open and resolves the selected
        // one as soon as this installs the fetcher, so nothing is replayed
        // here — only the mariner's old SharedPreferences list, once.
        chartLinkController.start(l)
        val loaded = date
        access.onMain {
            mariner.loadFrom(v, loaded)
            plugins.drainOpenFiles()
        }
    }

    /**
     * The opening view when there is no saved pose. The pose itself is the
     * ENGINE's: it restores one out of the store at setStore. With nothing
     * saved the opening view is the engine's own, the same policy every host
     * gets from lookout_default_view.
     */
    private fun restoreView(l: Lookout) {
        if (!Store.has(Store.Group.VIEW, "lon")) l.defaultView()
    }

    /**
     * Bind a controller to an engine that is ALREADY open, after the Activity
     * was destroyed and built again over a process that kept running. Every
     * effect [attach] has on the engine is already in place, so this only
     * reads: what is missing is this object's own state and the Compose state
     * behind it.
     *
     * MAIN THREAD; the value is posted to [queue].
     */
    fun rebind(l: Lookout, queue: Handler) {
        access.bind(l, queue)
        queue.post {
            plugins.forgetLastRegistry()
            alertsController.reset()
            lastWatchNs = 0L
            lastPushed = null
            rasterController.reset()
            val v = DoubleArray(Lookout.MARINER_LEN)
            l.getMariner(v)
            val date = l.getMarinerDate()
            plugins.republish(l)
            alertsController.publish(l)
            rasterController.pushRaster(l)
            // This controller's own fetcher, and its own snapshot poll: the
            // old controller's was stopped in onReplaced, and the credit the
            // recreation dropped comes back with the next snapshot.
            chartLinkController.start(l)
            access.onMain { mariner.loadFrom(v, date) }
        }
    }

    /**
     * Another controller is taking over the engine because the Activity was
     * rebuilt over a running process. Only the tile service needs stopping;
     * everything else here is released when this object is dropped.
     *
     * RENDER THREAD.
     */
    fun onReplaced() {
        chartLinkController.stop()
    }

    /**
     * The surface is going but the engine is not. The engine writes the pose
     * at detach; this puts it on disk, because the periodic flush runs off the
     * frame loop and there are about to be no frames.
     *
     * RENDER THREAD, inside the detach barrier.
     */
    fun onSurfaceDetached() {
        Store.flush()
    }

    /**
     * Drop [l]'s handle — but only if it is still the live one. Switching chart
     * library closes the engine and opens another; the outgoing close can land
     * AFTER the incoming open has already attached, and clearing unconditionally
     * would leave the controller detached from a live engine (a frozen HUD,
     * dead settings) until the next surface change.
     */
    fun detach(l: Lookout?) {
        if (!access.isLive(l)) return
        Store.flush() // the engine wrote the pose; put it on disk
        // Before the handle closes: a fetch landing later must find the
        // provider gone, not a dying engine.
        chartLinkController.stop()
        access.unbind()
        // Everything below is the MAIN thread's: Compose state, the siren
        // (whose strike runnable lives on the main handler and whose flag is
        // not volatile), and the service. Called here from the render thread
        // inside closeOn, so it hops — the race let one more strike sound
        // after the engine and its alarm were gone.
        access.onMain {
            rendering = false
            identify = emptyList()
            alertsController.clear()
            // The plugins' declared tables went with them.
            tables.clear()
            // And nothing left to hold the process up for.
            stopService()
        }
    }

    // ---- readouts (render thread) ------------------------------------------

    @Volatile private var lastPushed: Readouts? = null
    private var lastPushNs = 0L

    /**
     * Sample the engine for the HUD. Throttled and change-gated: the frame loop
     * runs at display rate, and pushing a new Readouts every frame would
     * recompose the HUD 120 times a second to redraw identical text.
     */
    fun onFrameRendered(frameTimeNanos: Long) {
        val l = access.live ?: return
        // Before the HUD throttle: the bubble follows its target at frame rate,
        // the readouts at 10 Hz.
        followPin(l)
        watchPlugins(l, frameTimeNanos)
        if (lastPushNs != 0L && frameTimeNanos - lastPushNs < PUSH_INTERVAL_NS) return
        lastPushNs = frameTimeNanos
        l.readouts(readoutBuf)
        val fix = l.ownShip(shipBuf)
        val r = Readouts(
            lon = readoutBuf[Lookout.R_LON],
            lat = readoutBuf[Lookout.R_LAT],
            zoom = readoutBuf[Lookout.R_ZOOM],
            rotationDeg = readoutBuf[Lookout.R_ROTATION_DEG],
            overscale = readoutBuf[Lookout.R_OVERSCALE],
            scaleDenominator = readoutBuf[Lookout.R_SCALE_DENOM],
            building = readoutBuf[Lookout.R_BUILDING] != 0.0,
            followState = l.followActive(),
            courseUp = l.courseUpActive(),
            fixState = fix,
            // Published only when live — the readout never falls back to the
            // map centre or a dead-reckoned number.
            shipLon = if (fix == Lookout.FIX_LIVE) shipBuf[0] else 0.0,
            shipLat = if (fix == Lookout.FIX_LIVE) shipBuf[1] else 0.0,
        )
        // The chart moved under an open report, so retire the report. This
        // covers every move, including the pan and the fling, which run on
        // this thread and never call into this class.
        pickPose?.let { pose ->
            if (r.lon != pose.lon || r.lat != pose.lat ||
                r.zoom != pose.zoom || r.rotationDeg != pose.rotationDeg
            ) {
                pickPose = null
                access.onMain {
                    dismissIdentify()
                    // A camera move retires the chart menu with the report:
                    // both describe a point the chart has slid out from under.
                    chartMenu = null
                }
            }
        }
        // The pill appears and goes as the mariner sails in and out of the
        // coverage, so this is read on the frame, not only when something is
        // pressed. Cheap: a handful of calls over a handful of sets.
        rasterController.pushRaster(l)
        // The chart-link list, the credit and the error, from the core. A
        // landing answer raises needs-redraw, so a resolve keeps this ticking
        // until it is done.
        chartLinkController.poll(l)
        if (r == lastPushed) return
        lastPushed = r
        access.onMain {
            readouts = r
            rendering = true
        }
    }

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
        alertsController.publish(l)
        val c = plugins.connections(l)
        updateService(c)
        return when {
            c.live -> BACKGROUND_LIVE_MS
            c.trying -> BACKGROUND_TRYING_MS
            else -> 0L
        }
    }

    // ---- the foreground service --------------------------------------------

    /** Whether the process is currently being held up. RENDER THREAD. */
    private var serviceOn = false
    private var lastLiveMs = 0L
    /** When a refused foreground start may be tried again. The platform
     *  refuses from the background (API 31+); one attempt per backoff keeps
     *  the log quiet, and a foreground return heals it on the next tick. */
    private var serviceRetryAtMs = 0L

    /**
     * Start or stop the service from what the connections say. Live means the
     * app is holding a session to the gateway, which is the case that has to
     * survive the mariner looking at something else.
     *
     * A drop does not stop it at once. A gateway blinks, a boat's Wi-Fi hands
     * over, and stopping on the first missed second would drop the notification,
     * lose the process's protection, and then need a foreground start to get it
     * back, which the platform will not allow from the background. So it
     * lingers, and only a connection that stays down ends it.
     *
     * RENDER THREAD.
     */
    private fun updateService(c: PluginSettingsController.Connections) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (c.live) lastLiveMs = now
        val want = c.live || (serviceOn && now - lastLiveMs < SERVICE_LINGER_MS)
        if (want == serviceOn) return
        if (want) {
            if (now < serviceRetryAtMs) return
            // Only believe the service is up when the platform took the start;
            // a refused start is retried, not recorded as running.
            serviceOn = ChartService.start(appContext)
            if (!serviceOn) serviceRetryAtMs = now + SERVICE_RETRY_MS
        } else {
            serviceOn = false
            ChartService.stop(appContext)
        }
    }

    /** The engine is going, so nothing is left to hold the process up for. */
    private fun stopService() {
        if (!serviceOn) return
        serviceOn = false
        ChartService.stop(appContext)
    }

    /**
     * The once-a-second look at what the plugins are doing: what they are
     * alarming about, and whether anything is still connected. Both come off
     * the frame loop rather than a clock of their own, so an idle chart gains
     * no wakeup it did not already have; this only decides how often that
     * existing visit crosses into the core. The same pair is what
     * [onBackgroundTick] does when there are no frames to ride on.
     *
     * RENDER THREAD.
     */
    private fun watchPlugins(l: Lookout, frameTimeNanos: Long) {
        if (lastWatchNs != 0L && frameTimeNanos - lastWatchNs < WATCH_INTERVAL_NS) return
        lastWatchNs = frameTimeNanos
        alertsController.publish(l)
        updateService(plugins.connections(l))
    }

    private var lastWatchNs = 0L

    /** Silence one alert and take it off the chart. */
    fun acknowledgeAlert(alert: PluginAlert) = alertsController.acknowledge(alert)

    // ---- plugin tables ------------------------------------------------------

    /**
     * The plugins: what is loaded, what each declares, and the mariner's
     * writes to any of it. The declared tables ride its registry refresh.
     */
    val plugins = PluginSettingsController(appContext, access) { specs -> tables.adopt(specs) }

    /** Set by the Activity before the first surface. */
    var pluginDir: String?
        get() = plugins.pluginDir
        set(v) { plugins.pluginDir = v }

    /** Developer only, from the launch intent. See PluginSettingsController. */
    var nmeaAddress: String?
        get() = plugins.nmeaAddress
        set(v) { plugins.nmeaAddress = v }

    val pluginRegistry: PluginRegistry get() = plugins.pluginRegistry
    val pluginConsent: PluginSettingsController.PluginPackage? get() = plugins.pluginConsent
    val installError: String? get() = plugins.installError

    fun refreshPlugins() = plugins.refreshPlugins()
    fun startPluginPolling() = plugins.startPluginPolling()
    fun stopPluginPolling() = plugins.stopPluginPolling()
    fun setPluginScalar(id: String, field: PluginField, v: Double) = plugins.setPluginScalar(id, field, v)
    fun setPluginList(list: PluginListSchema, rows: List<PluginRow>) = plugins.setPluginList(list, rows)
    fun setPluginGrant(id: String, cap: String, on: Boolean) = plugins.setPluginGrant(id, cap, on)
    fun uninstallPlugin(id: String) = plugins.uninstallPlugin(id)
    fun beginPluginInstall(path: String) = plugins.beginPluginInstall(path)
    fun confirmPluginInstall() = plugins.confirmPluginInstall()
    fun cancelPluginInstall() = plugins.cancelPluginInstall()
    fun dismissInstallError() = plugins.dismissInstallError()

    /**
     * A file another app opened into us, routed by NAME: a .lkplug goes to the
     * consent sheet, anything else is offered to the plugins.
     */
    fun openFile(path: String) = plugins.openFile(path)

    /** The tables the plugins declare, and the one on screen. */
    val tables = TableController(access) { lon, lat -> centreOn(lon, lat) }

    val tableSpecs: List<TableSpec> get() = tables.tableSpecs
    val openTable: TableSpec? get() = tables.openTable
    val tableBatch: TableBatch? get() = tables.tableBatch
    val tableSortKey: String get() = tables.tableSortKey
    val tableSortAscending: Boolean get() = tables.tableSortAscending

    fun showTable(spec: TableSpec) = tables.showTable(spec)
    fun dismissTable() = tables.dismissTable()
    fun setTableSort(key: String) = tables.setTableSort(key)
    fun pollTable() = tables.pollTable()
    fun revealOnChart(lon: Double, lat: Double) = tables.revealOnChart(lon, lat)

    /**
     * Put the chart on a point, keeping the zoom and the rotation. Follow is
     * switched off first: a chart that slides back to own ship a moment later
     * has not shown the mariner the target they asked for.
     */
    private fun centreOn(lon: Double, lat: Double) = onEngine { l ->
        if (l.followActive() != 0) l.followSet(false)
        val r = lastPushed
        l.setView(lon, lat, r?.zoom ?: 12.0, r?.rotationDeg ?: 0.0)
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
        onEngine { l -> l.setMariner(v, date) }
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
        access.onMain { mariner.loadFrom(v, date) }
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

    // ---- the chart menu and markers -----------------------------------------

    /** The long-press chart menu: what stands where it was raised. */
    data class ChartMenu(
        val at: Offset,
        val lon: Double,
        val lat: Double,
        /** 0 over open water; else the mark under the finger. */
        val markerId: Long = 0,
        val markerName: String = "",
    )

    var chartMenu by mutableStateOf<ChartMenu?>(null)
        private set

    /** The mark being renamed, holding the menu's place data. */
    var renamingMarker by mutableStateOf<ChartMenu?>(null)
        private set

    /**
     * Raise the chart menu. Over a mark it renames and removes; over water it
     * drops. The mark is core-owned and chart-independent — the shell stores
     * nothing and draws nothing.
     */
    fun showChartMenu(xPts: Float, yPts: Float) = onEngine { l ->
        l.screenToGeo(xPts, yPts, geoBuf)
        val id = l.markerAt(xPts, yPts)
        val name = if (id != 0L) l.markerName(id).orEmpty() else ""
        val menu = ChartMenu(Offset(xPts, yPts), geoBuf[0], geoBuf[1], id, name)
        access.onMain { chartMenu = menu }
    }

    fun dismissChartMenu() {
        chartMenu = null
    }

    var auxFile by mutableStateOf<AuxFile?>(null)
        private set

    fun openAuxFile(cell: String, name: String) = onEngine { l ->
        val mime = arrayOfNulls<String>(1)
        val bytes = l.auxFile(cell, name, mime)
        if (bytes == null) {
            Log.w(TAG, "aux file not carried: $cell/$name")
            return@onEngine
        }
        val out = AuxFile(name, bytes, mime[0] ?: "")
        access.onMain { auxFile = out }
    }

    fun dismissAuxFile() {
        auxFile = null
    }

    fun menuPick() {
        val m = chartMenu ?: return
        chartMenu = null
        identifyAt(m.at.x, m.at.y)
    }

    /** THE DROP NEVER WAITS FOR TYPING: the core places and names the mark. */
    fun dropMarker() {
        val m = chartMenu ?: return
        chartMenu = null
        onEngine { l ->
            if (l.markerAdd(m.lon, m.lat) == 0L) Log.w(TAG, "marker refused")
        }
    }

    fun removeMarker() {
        val m = chartMenu ?: return
        chartMenu = null
        onEngine { l -> l.markerRemove(m.markerId) }
    }

    fun beginRenameMarker() {
        renamingMarker = chartMenu
        chartMenu = null
    }

    /** Empty keeps the old name — the core decides, so shells agree. */
    fun commitRenameMarker(name: String) {
        val m = renamingMarker ?: return
        renamingMarker = null
        onEngine { l -> l.markerRename(m.markerId, name) }
    }

    fun cancelRenameMarker() {
        renamingMarker = null
    }

    /**
     * The compass tap walks the orientation ladder, exactly the reference's
     * `cycleOrientation`: off → follow; following north-up → course-up; else
     * back to north-up, still locked. The STATE is never remembered here — the
     * engine drops follow on a pan, and the readouts poll it back.
     */
    fun cycleOrientation() = onEngine { l ->
        when {
            l.followActive() == 0 -> l.followSet(true)
            !l.courseUpActive() -> l.courseUpSet(true)
            else -> l.resetRotation()
        }
    }

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
                pinnedPayload = null
                pinnedInfo = null
                postedPin = next
                postedPoint = at
                access.onMain {
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
        pinnedPayload = null
        pinnedInfo = null
        postedPin = null
        postedPoint = null
        l.screenToGeo(xPts, yPts, geoBuf)
        val found = PickDecoded.read(l, geoBuf[0], geoBuf[1])
        val pose = lastPushed
        access.onMain {
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
        pinnedPayload = null
        pinnedInfo = null
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
            pinnedPayload = null
            pinnedInfo = null
            access.onMain { if (pinned?.id == id) dismissPin() }
            return
        }
        // The payload is JSON the plugin wrote, and it is the same JSON on
        // almost every frame: a target's name and MMSI never change, and its
        // speed and closest approach change at the store's own 2 Hz. Parsing
        // it per frame built a JSONObject, a JSONArray and a list of pairs at
        // display rate to produce an object equal to the last one. The
        // re-projection below is what must run every frame; this need not.
        val info = if (cur[1] == pinnedPayload) {
            pinnedInfo
        } else {
            OverlayInfo.parse(cur[1])?.also {
                pinnedPayload = cur[1]
                pinnedInfo = it
            }
        } ?: return
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
        access.onMain {
            if (pinnedId != id) return@onMain          // retired while this hopped threads
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

        /** See linkFirstHint. */
        const val LINK_ACTIVE_HINT = "active_hint"

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
         * How often the frame loop crosses into the core for what the plugins
         * are doing: the alerts, and whether anything is still connected. Both
         * ride the existing frame visit rather than a clock of their own, so an
         * idle chart gains no wakeup it did not already have.
         */
        const val WATCH_INTERVAL_NS = 1_000_000_000L

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

        /**
         * How long a dropped connection keeps the service. Long enough to
         * cover a gateway rebooting or a boat's Wi-Fi handing over, short
         * enough that a mariner who unplugs at the dock sees the notification
         * go within the minute.
         */
        const val SERVICE_LINGER_MS = 45_000L
        /** Backoff after the platform refuses a foreground start. */
        const val SERVICE_RETRY_MS = 30_000L

        /** Cheap (an async prefs write), but there is no point doing it often. */
    }
}
