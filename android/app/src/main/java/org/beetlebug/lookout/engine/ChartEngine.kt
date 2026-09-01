package org.beetlebug.lookout.engine

import org.beetlebug.lookout.hud.LoadPhase

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.chart.ChartController

import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import java.util.concurrent.CountDownLatch

/**
 * The chart engine and the thread it runs on, owned by the PROCESS.
 *
 * Android destroys a SurfaceView's surface whenever the app leaves the
 * foreground. While the engine belonged to the view it went with the surface,
 * so pressing HOME threw away the opened library, the atlas bake and the whole
 * plugin layer, and coming back re-ran an open that costs seconds on a real
 * chart library. It also silenced any alarm nobody had answered, which is the
 * part that matters at sea.
 *
 * So the surface is what comes and goes and the engine is not. A view hands one
 * over with [attach] and takes it back with [detach]; in between, the engine
 * stands with no view at all, holding its charts, its scene and its plugins,
 * while [backgroundTick] keeps sampling the alerts so an alarm raised with
 * nobody looking still reaches the mariner.
 *
 * The FIRST surface is what opens the library, because a Vulkan device built
 * with no presentation surface cannot grow one: the instance and device
 * extensions, the render pass and every pipeline are all chosen at open. Every
 * surface after that one is optional.
 *
 * Threading: [queue] is the render thread, and every native call belongs on it.
 * The lifecycle calls (open, close, attach, detach) are posted there too, which
 * is the external serialization the C ABI asks for, and the frame loop is
 * stopped around them.
 */
class ChartEngine private constructor() {

    /** What a view contributes to a frame before the engine draws it. */
    fun interface FrameHook {
        /** RENDER THREAD, once per frame, before anything reads the camera. */
        fun onFrame(l: Lookout, frameTimeNanos: Long)
    }

    /** The render thread's queue, or null before the first surface. */
    @Volatile
    var queue: Handler? = null
        private set

    /** The open handle, or null before the first surface. */
    @Volatile
    var lookout: Lookout? = null
        private set

    private var thread: HandlerThread? = null

    @Volatile private var controller: ChartController? = null
    @Volatile private var frameHook: FrameHook? = null

    /** The library this engine was opened on. RENDER THREAD. */
    private var paths: Array<String> = emptyArray()

    /** The background library add of a link-first startup, joined before any
     *  close: the add runs with the api lock dropped for its file opens, so
     *  the handle has to outlive it. */
    private var libraryAdd: Thread? = null
    private var ticking = false

    /**
     * Set the moment the platform takes the surface back, cleared when it
     * hands one over. Read by the open, which finishes long after `detach`
     * has returned and must not start drawing on a window that has gone.
     */
    @Volatile private var surfaceGone = false

    /**
     * Give the engine a surface, opening the library on the first one and
     * starting the frame loop on every one. Returns at once; the work is the
     * render thread's.
     *
     * A different [chartPaths] is a different engine: the scene, the
     * composition and the plugin layer all belong to the library, so this
     * closes and opens again rather than pretending.
     */
    fun attach(
        surface: Surface,
        chartPaths: Array<String>,
        controller: ChartController,
        density: Float,
        wPx: Int,
        hPx: Int,
        wPts: Int,
        hPts: Int,
        hook: FrameHook,
    ) {
        if (thread == null) {
            // The open is tens of seconds on a real library (one chart open per
            // cell, 7000+, the atlas bake, Vulkan bring-up), so nothing below
            // may run on the UI thread.
            thread = HandlerThread("lookout-render").also { it.start() }
            queue = Handler(thread!!.looper)
        }
        val h = queue ?: return
        surfaceGone = false
        frameHook = hook
        // Before any path returns: every controller mutation must be able to
        // wake an idled frame loop, whichever branch below runs.
        controller.onMutated = ::kick
        h.post {
            var l = lookout
            if (l != null && !chartPaths.contentEquals(paths)) {
                closeOn(l)
                l = null
            }
            if (l != null && this.controller !== controller) {
                // The Activity was destroyed and built again over a process
                // that kept running. The engine is already set up; only this
                // new controller's own state is missing. Stop the replaced
                // controller's tile service first: two pollers would fight
                // over one ring, and the old controller's thread pool would
                // otherwise run for the rest of the process.
                this.controller?.onReplaced()
                this.controller = controller
                controller.rebind(l, h)
            }
            if (l != null && l.isAttached) {
                // A resize rebuilds the swapchain and the api lock it takes is
                // held for a whole frame, which is why this is not done on the
                // UI thread: there a rotation becomes an input-dispatch ANR.
                // The density rides along: a fold or an external display
                // recreates the Activity with a new one over the same engine,
                // and symbols sized for the old glass mis-draw AND mis-pick.
                l.setDensity(density)
                l.setDeviceScale(density)
                l.resize(wPts, hPts)
                return@post
            }
            if (l != null && !l.attachSurface(surface, wPts, hPts)) {
                // The new surface would not offer the format the pipelines were
                // built for. A slow chart beats no chart, so reopen.
                Log.w(TAG, "surface would not attach; reopening the library")
                closeOn(l)
                l = null
            }
            if (l == null) {
                this.controller = controller
                // The loader's honest phases: the one-time atlas bake shows
                // only when the cache is cold, and the first-scene step takes
                // over once the (synchronous) open returns.
                controller.noteOpenPhase(
                    if (Lookout.atlasCacheReady()) LoadPhase.MAPPING
                    else LoadPhase.SYMBOLS
                )
                // An active chart link needs no cell library to paint. Open
                // the engine EMPTY — about a second instead of the ten that
                // mapping thousands of cells costs — so the link takes the
                // screen first, and bring the library installed behind it (the
                // add drops the engine's locks for its file opens, so the
                // chart keeps drawing). Without a link the library IS the
                // first picture, and the loader stays honest about it.
                val linkFirst = controller.linkFirstHint && chartPaths.isNotEmpty()
                l = openOn(
                    surface,
                    if (linkFirst) emptyArray() else chartPaths,
                    controller, density, wPx, hPx, wPts, hPts, h,
                ) ?: return@post
                // The TARGET library, whatever was opened so far: a re-attach
                // must not close a still-loading engine over the difference.
                paths = chartPaths
                controller.noteOpenPhase(LoadPhase.TESSELLATING)
                if (linkFirst) {
                    val engine = l
                    libraryAdd = Thread({
                        val n = engine.chartsAdd(chartPaths)
                        Log.i(TAG, "library installed behind the chart link: $n cells")
                    }, "lookout-library-add").also { it.start() }
                }
            }
            // The surface went while this open was running. `detach` could
            // not barrier against it — the handle is published last, so it
            // had nothing to wait on and returned at once — and the window
            // the platform handed us has since been freed. Starting the frame
            // loop here would draw at display rate into a dead surface for
            // as long as the app lived: measured at 13% of a core, backgrounded,
            // indefinitely, and it never stopped when the app came back.
            if (surfaceGone) {
                Log.i(TAG, "surface went during the open; standing down instead of drawing")
                l.detachSurface()
                startBackgroundTick()
                return@post
            }
            stopBackgroundTick()
            waiting = false
            frameLoopLive = true
            Choreographer.getInstance().removeFrameCallback(frameCallback)
            Choreographer.getInstance().postFrameCallback(frameCallback)
        }
    }

    /**
     * Take the surface back, and BLOCK until the render thread has stopped
     * drawing and given it up: the platform frees the surface the moment
     * surfaceDestroyed returns.
     *
     * The frame loop and the detach both run on that one thread, so a single
     * barrier covers both. The wait is far shorter than the close this replaced,
     * which shut down every plugin and closed every cell on the same thread.
     */
    fun detach() {
        val h = queue ?: return
        // Before the early return below: an open that is still running has to
        // learn the surface is gone, because it is what starts the frame loop
        // when it finishes.
        surfaceGone = true
        // Nothing to barrier against yet. `openOn` publishes the handle LAST,
        // so a null one means the open has not finished, and the frame loop
        // has not started either — there is no drawing in flight to wait for.
        val l = lookout ?: return
        val done = CountDownLatch(1)
        h.post {
            Choreographer.getInstance().removeFrameCallback(frameCallback)
            queue?.removeCallbacks(waitTick)
            waiting = false
            frameHook = null
            controller?.onSurfaceDetached()
            l.detachSurface()
            startBackgroundTick()
            done.countDown()
        }
        // NOT interruptible: the platform frees the surface the moment
        // surfaceDestroyed returns, so returning early hands the render
        // thread a freed surface — a native use-after-free. Remember the
        // interrupt, finish the wait, re-assert it on the way out.
        var interrupted = false
        while (true) {
            try {
                done.await()
                break
            } catch (e: InterruptedException) {
                interrupted = true
            }
        }
        if (interrupted) Thread.currentThread().interrupt()
    }

    /** Hand the engine's reclaimable caches back. Safe on any thread. */
    fun memoryWarning() {
        val h = queue ?: return
        h.post { lookout?.memoryWarning() }
    }

    // ---- the frame loop (render thread) -------------------------------------

    private val frameCallback = Choreographer.FrameCallback { t -> doFrame(t) }

    /** True while a WAIT verdict's delay is posted rather than a frame. */
    private var waiting = false

    /** True while the frame callback is posted. A kick on a LIVE loop only
     *  resets the idle counter: re-posting the callback per gesture event
     *  churned the choreographer and zeroed the frame clock mid-drag. */
    private var frameLoopLive = false

    private fun doFrame(frameTimeNanos: Long) {
        val l = lookout ?: run {
            frameLoopLive = false
            return
        }
        // No surface to present on: stop rescheduling. attach starts it again.
        if (!l.isAttached) {
            frameLoopLive = false
            return
        }
        // Before anything reads the camera: the view's share of this frame.
        frameHook?.onFrame(l, frameTimeNanos)

        // THE CORE DECIDES. It measures the gap and caps it, advances the
        // fling and the queued chart-link answers, writes the pose down as the
        // mariner moves, and says whether there is a frame to draw. Four
        // shells had four copies of that.
        l.frameNext(frame)
        val verdict = frame[0]
        if (verdict == Lookout.FRAME_RENDER) l.render()
        // Sample the HUD here rather than on a timer: the readouts describe the
        // frame that was just presented. The controller throttles the push.
        controller?.onFrameRendered(frameTimeNanos)

        // A gesture holds the loop open whatever the core says: the pan stream
        // is consumed BY the frame loop, and the loop standing down mid-drag
        // landed the whole drag at the lift.
        if (verdict == Lookout.FRAME_IDLE && !gestureActive) {
            frameLoopLive = false
            return
        }
        val waitMs = if (gestureActive) 0 else frame[1]
        if (waitMs > 0) {
            // Plugin traffic has no gesture behind it, so the core asks for a
            // slow poll rather than a display tick.
            waiting = true
            queue?.postDelayed(waitTick, waitMs.toLong())
            return
        }
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    private val waitTick = Runnable {
        waiting = false
        if (frameLoopLive) Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    /** {verdict, waitMs, building}. Render thread only. */
    private val frame = IntArray(3)

    /** True while a pointer is on the glass. The pan stream is consumed BY
     *  the frame loop (the view's resampler hook), so the loop must not
     *  stand down mid-gesture — it did, during the touch slop's quiet
     *  frames, and the whole drag then landed at the lift. */
    @Volatile private var gestureActive = false

    /** UI thread, from the view's touch handler. Safe from any thread. */
    fun setGestureActive(on: Boolean) {
        gestureActive = on
        if (on) kick()
    }

    /** Wake the frame loop: a mutation happened. Safe from any thread. */
    fun kick() {
        val h = queue ?: return
        h.post {
            lookout?.frameKick()
            resumeFrames()
        }
    }

    /** Render thread. A live loop only has its idle counter reset; the
     *  choreographer is touched solely on a true resume from stand-down. */
    private fun resumeFrames() {
        val l = lookout ?: return
        if (!l.isAttached) return
        if (frameLoopLive) {
            // A wait is already posted; letting it fire keeps one callback in
            // flight rather than two.
            return
        }
        frameLoopLive = true
        if (!waiting) Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    // ---- the background visit (render thread, no surface) -------------------
    //
    // A source plugin keeps receiving while the app is away, and can raise a
    // collision alarm at any moment from its own thread. With no frame loop
    // nothing would ever look, so the alarm would arrive silently and wait for
    // the mariner to come back on their own. This is the one thing that still
    // wakes with no view, and it does the least it can: sample the alerts.
    //
    // The controller sets the pace and ends it. The visit stops the moment no
    // connection is held or being chased, so a backgrounded plotter with
    // nothing plugged in wakes for nothing at all.

    private val backgroundTick = object : Runnable {
        override fun run() {
            if (!ticking) return
            val l = lookout ?: return
            if (l.isAttached) { // the frame loop has it back
                ticking = false
                return
            }
            val next = controller?.onBackgroundTick(l) ?: 0L
            if (next <= 0L) {
                ticking = false
                return
            }
            queue?.postDelayed(this, next)
        }
    }

    private fun startBackgroundTick() {
        if (ticking) return
        ticking = true
        queue?.post(backgroundTick)
    }

    private fun stopBackgroundTick() {
        ticking = false
        queue?.removeCallbacks(backgroundTick)
    }

    // ---- open and close (render thread) -------------------------------------

    private fun openOn(
        surface: Surface,
        chartPaths: Array<String>,
        controller: ChartController,
        density: Float,
        wPx: Int,
        hPx: Int,
        wPts: Int,
        hPts: Int,
        h: Handler,
    ): Lookout? {
        val l = Lookout.openCharts(chartPaths, surface, wPx, hPx, wPts, hPts, true) ?: return null
        // The surface's own extent lags a rotation, so the engine is TOLD the
        // scale rather than left to infer it, before the first build.
        l.setDensity(density)
        // The symbols and the text are sized for 1x until the engine is told
        // the display's scale. Without this they draw too small and their pick
        // geometry with them.
        l.setDeviceScale(density)
        // Also before the first build: the mariner's saved settings and the
        // saved view, or the chart tessellates once at defaults and again
        // immediately. Safe inline, no frame runs until lookout is published.
        controller.attach(l, h)
        paths = chartPaths
        lookout = l // published LAST: the frame loop gates on it
        return l
    }

    private fun closeOn(l: Lookout) {
        stopBackgroundTick()
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        // The library add drops the engine's api lock for its file opens, so
        // the handle must outlive the add: join it before closing.
        libraryAdd?.let { t ->
            while (true) {
                try { t.join(); break } catch (_: InterruptedException) {}
            }
        }
        libraryAdd = null
        controller?.detach(l)
        l.close()
        lookout = null
        paths = emptyArray()
    }

    companion object {
        private const val TAG = "lookout"
        /* The idle watch for plugin-driven redraws: the AIS store coalesces
         * at 2 Hz, so 4 Hz sees every change with one frame of slack. */

        /**
         * One engine for the process. Not tied to the Activity: the point of
         * all this is that it outlives one, and an alarm sounding from a
         * plugin has to outlive one too.
         */
        private val instance = ChartEngine()

        @JvmStatic
        fun get(): ChartEngine = instance
    }
}
