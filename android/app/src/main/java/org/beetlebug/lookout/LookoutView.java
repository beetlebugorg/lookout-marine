package org.beetlebug.lookout;

import android.content.Context;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Choreographer;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import java.util.concurrent.CountDownLatch;

/**
 * The chart view: a SurfaceView the Zig core renders into via Vulkan, with
 * platform gesture recognizers driving the camera — one finger pans, pinch
 * zooms about the focal point, double-tap zooms in a level, long-press cycles
 * day/dusk/night. A Choreographer frame callback renders only when the core
 * says something changed (needsRedraw/animating), so an idle chart costs no
 * GPU and no battery.
 *
 * All camera calls are in LOGICAL points: pixel coordinates divide by the
 * display density before crossing into the core (whose camera unit is dp).
 */
public final class LookoutView extends SurfaceView
        implements SurfaceHolder.Callback, Choreographer.FrameCallback {

    // Every cell to compose, not one chart: a pushed library is opened whole.
    private final String[] chartPaths;
    private final float density;
    private final ChartController controller;
    // Published by the open, on the render thread; cleared by the close in
    // onDetachedFromWindow, on the main thread once that thread has stopped.
    // The C ABI's api lock serializes the native calls themselves.
    private volatile Lookout lk;
    private long lastFrameNs;

    // ---- touch track (input resampling) -------------------------------------
    // Pan is NOT applied when the touch lands. MotionEvents are delivered on the
    // UI thread against ITS vsync while frames run on the render thread against
    // a different one, so handing the raw event delta straight to the camera made
    // the per-frame step wobble ±25% at a dead-steady drag (measured: 1.50 px one
    // frame, 1.87 the next). Presentation is a clean 60 Hz and every frame is
    // individually crisp, so that wobble is the whole artifact: the eye tracks the
    // chart smoothly and uneven steps smear into fuzz — worst at a slow pan, where
    // the step is a couple of pixels and the jitter is a large fraction of it.
    //
    // Instead the UI thread records a position-vs-time track and each frame samples
    // it at the FRAME's own timestamp, so a frame moves by exactly the distance the
    // finger covered over that frame. Same idea as the platform's own resampler,
    // aimed at the clock that actually matters here.
    private static final int TRACK_N = 16;
    // Sample slightly in the past so there is usually a real sample on both sides
    // to interpolate between, and predict only a little past the newest one — the
    // values the platform resampler uses.
    private static final long RESAMPLE_LAG_NS = 5_000_000L;
    private static final long MAX_PREDICT_NS = 8_000_000L;
    // Two samples further apart than this are not a velocity worth extrapolating.
    private static final long MAX_PREDICT_BASE_NS = 32_000_000L;

    private final Object trackLock = new Object();
    private final float[] trackX = new float[TRACK_N];
    private final float[] trackY = new float[TRACK_N];
    private final long[] trackT = new long[TRACK_N]; // event time, ns
    private int trackHead = -1, trackCount;
    // Bumped whenever the focus point jumps discontinuously (a finger joins or
    // leaves): the next frame re-bases on the new track instead of panning across
    // the jump.
    private int trackEpoch;
    private boolean dragging;
    private float downX, downY;
    private final int touchSlop;
    // Render-thread only: the last position this loop resampled to.
    private float lastFx, lastFy;
    private int lastEpoch = -1;
    private boolean haveLast;
    private final GestureDetector gestures;
    private final ScaleGestureDetector scaler;
    // Frames run on a dedicated render thread (the C ABI's intended shape:
    // gestures on main, lookout_render on a render thread). A rebuild after a
    // zoom re-tessellates for ~a second — on the main thread that froze the UI
    // ("Skipped N frames"); here it only occupies the render thread, and the
    // engine tessellation itself runs on a further worker inside the core.
    private HandlerThread renderThread;
    // Gestures post here instead of calling in directly: the C ABI's per-handle
    // lock is held for a whole frame, so a UI-thread call froze for that long.
    private volatile Handler engine;

    /** Run something on the render thread, or drop it if there is no engine. */
    private void onEngine(Runnable r) {
        Handler h = engine;
        if (h != null && lk != null) h.post(r);
    }

    public LookoutView(Context context, String[] chartPaths, ChartController controller) {
        super(context);
        this.chartPaths = chartPaths;
        this.controller = controller;
        float d = context.getResources().getDisplayMetrics().density;
        this.density = d > 0 ? d : 1f;
        this.touchSlop = android.view.ViewConfiguration.get(context).getScaledTouchSlop();
        getHolder().addCallback(this);
        // Scroll/rotary events need a focus target; without this they dispatch
        // to the Activity (handled there too, but keep the direct path alive).
        setFocusable(true);
        setFocusableInTouchMode(true);
        requestFocus();

        gestures = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            @Override
            public boolean onDoubleTap(MotionEvent e) {
                final float x = e.getX() / density, y = e.getY() / density;
                onEngine(() -> lk.zoomAt(1.0, x, y));
                return true;
            }

            /** Tap a feature to identify it (S-52 cursor pick). "Confirmed"
             *  waits out the double-tap window so a zoom doesn't also pick. */
            @Override
            public boolean onSingleTapConfirmed(MotionEvent e) {
                controller.identifyAt(e.getX() / density, e.getY() / density);
                return true;
            }

            /** Momentum pan. GestureDetector reports px/sec; the camera is
             *  logical-unit, so scale before crossing. */
            @Override
            public boolean onFling(MotionEvent e1, MotionEvent e2, float vx, float vy) {
                onEngine(() -> lk.flingStart(vx / density, vy / density));
                return true;
            }

            /** Through the controller, not the handle: a scheme change has to
             *  land in the settings state and be SAVED, or a scheme picked by
             *  long-press is lost on relaunch while the same scheme picked in
             *  the sheet survives. */
            @Override
            public void onLongPress(MotionEvent e) {
                controller.cycleScheme();
            }

            @Override
            public boolean onDown(MotionEvent e) {
                // A new grab stops any coast, so the chart doesn't slide out
                // from under the finger that just caught it.
                onEngine(() -> lk.flingStart(0, 0));
                return true; // claim the stream
            }
        });

        scaler = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override
            public boolean onScale(ScaleGestureDetector det) {
                float f = det.getScaleFactor();
                if (f > 0) {
                    final double dz = Math.log(f) / Math.log(2.0);
                    final float fx = det.getFocusX() / density, fy = det.getFocusY() / density;
                    onEngine(() -> lk.zoomAt(dz, fx, fy));
                }
                return true;
            }
        });
    }

    // Two-finger tap = zoom OUT one level (the double-tap mirror; Maps does
    // the same). GestureDetector has no such gesture, so track it here: two
    // pointers down and up again quickly without wandering.
    private long twoDownMs;
    private float twoMidX, twoMidY;
    private boolean twoTap;

    // Two-finger twist = course-up rotation. Tracked here because there is no
    // platform rotate detector. It runs alongside the pinch (both see every
    // event), but only ENGAGES past a threshold: almost no two-finger pinch is
    // perfectly twist-free, and rotating the chart a degree per zoom would make
    // north drift for no reason.
    private static final float ROTATE_ENGAGE_DEG = 18f;
    // atan2 of the vector BETWEEN the fingers is mostly noise when they are
    // close: a 2px tremor is 0.4 deg at 300px of separation but 2.3 deg at
    // 50px — and a pinch drives them together, so the twist gets loudest
    // exactly while zooming. Below this span it is not a signal.
    private static final float MIN_TWIST_SPAN_DP = 96f;
    // Engaged, a held-still pinch should not creep.
    private static final float TWIST_DEADBAND_DEG = 0.25f;
    private boolean rotating;
    private float twistPrevDeg, twistAccumDeg;

    /** Angle of the vector between the first two pointers, in degrees. */
    private static float twistAngle(MotionEvent e) {
        return (float) Math.toDegrees(Math.atan2(e.getY(1) - e.getY(0), e.getX(1) - e.getX(0)));
    }

    /** Mean of the active pointers — GestureDetector's own scroll focus, so a
     *  two-finger pinch still pans by its focal drift. `h` < 0 = the current
     *  sample, else the h'th batched historical one. */
    private static float focus(MotionEvent e, int h, boolean yAxis) {
        final int n = e.getPointerCount();
        float s = 0;
        for (int i = 0; i < n; i++) {
            if (yAxis) s += (h < 0) ? e.getY(i) : e.getHistoricalY(i, h);
            else s += (h < 0) ? e.getX(i) : e.getHistoricalX(i, h);
        }
        return s / n;
    }

    private void addSample(float x, float y, long tNs) {
        synchronized (trackLock) {
            // Batched samples can repeat a timestamp; a zero-length span would
            // divide by zero when interpolating, so overwrite rather than push.
            if (trackCount > 0 && tNs <= trackT[trackHead]) {
                trackX[trackHead] = x;
                trackY[trackHead] = y;
                return;
            }
            trackHead = (trackHead + 1) % TRACK_N;
            trackX[trackHead] = x;
            trackY[trackHead] = y;
            trackT[trackHead] = tNs;
            if (trackCount < TRACK_N) trackCount++;
        }
    }

    /** The focus jumped (a finger joined or left) or a new gesture began: drop the
     *  track so the next frame re-bases instead of panning across the jump. */
    private void breakTrack() {
        synchronized (trackLock) {
            trackCount = 0;
            trackHead = -1;
            trackEpoch++;
        }
    }

    /** Record this event's samples, batched history first (they carry their own
     *  timestamps and are the finer-grained motion the resampler wants). */
    private void recordTouch(MotionEvent e) {
        final int hn = e.getHistorySize();
        for (int h = 0; h < hn; h++) {
            addSample(focus(e, h, false), focus(e, h, true), e.getHistoricalEventTime(h) * 1_000_000L);
        }
        addSample(focus(e, -1, false), focus(e, -1, true), e.getEventTime() * 1_000_000L);
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                breakTrack();
                dragging = false;
                downX = e.getX();
                downY = e.getY();
                break;
            case MotionEvent.ACTION_POINTER_DOWN:
                if (e.getPointerCount() == 2) {
                    twoTap = true;
                    twoDownMs = e.getEventTime();
                    twoMidX = (e.getX(0) + e.getX(1)) * 0.5f;
                    twoMidY = (e.getY(0) + e.getY(1)) * 0.5f;
                    twistPrevDeg = twistAngle(e);
                    twistAccumDeg = 0;
                    rotating = false;
                } else {
                    twoTap = false; // third finger: not a two-finger tap
                }
                breakTrack(); // the focus moves to the mean of one more finger
                break;
            case MotionEvent.ACTION_MOVE:
                if (dragging) {
                    recordTouch(e);
                } else if (Math.hypot(e.getX() - downX, e.getY() - downY) > touchSlop) {
                    // Past the slop: start the track HERE, so the pan doesn't
                    // begin with a jump of the slop distance.
                    dragging = true;
                    recordTouch(e);
                }
                if (twoTap && e.getPointerCount() >= 2) {
                    float mx = (e.getX(0) + e.getX(1)) * 0.5f;
                    float my = (e.getY(0) + e.getY(1)) * 0.5f;
                    if (Math.hypot(mx - twoMidX, my - twoMidY) > 24f * density) twoTap = false;
                }
                if (e.getPointerCount() >= 2) trackTwist(e);
                break;
            case MotionEvent.ACTION_UP:
                if (twoTap && e.getEventTime() - twoDownMs < 300) {
                    final float mx = twoMidX / density, my = twoMidY / density;
                    onEngine(() -> lk.zoomAt(-1.0, mx, my));
                }
                twoTap = false;
                rotating = false;
                dragging = false; // the fling, if any, takes it from here
                break;
            case MotionEvent.ACTION_POINTER_UP:
                rotating = false; // down to one finger: the twist is over
                breakTrack(); // and the focus jumps back onto that finger
                break;
            case MotionEvent.ACTION_CANCEL:
                twoTap = false;
                rotating = false;
                dragging = false;
                break;
        }
        // Both detectors see every event: pinch zooms while its focal-point
        // drift still pans (the Google-Maps feel).
        scaler.onTouchEvent(e);
        gestures.onTouchEvent(e);
        return true;
    }

    /**
     * Feed the twist to the camera. lookout_rotate_drag_logical rotates about
     * the VIEW CENTRE by the angle swept from one point to another, so handing
     * it centre+previous-vector and centre+current-vector expresses exactly the
     * angle the two fingers turned through (the vector length is irrelevant).
     */
    private void trackTwist(MotionEvent e) {
        float now = twistAngle(e);
        float d = now - twistPrevDeg;
        while (d > 180f) d -= 360f;   // shortest way round the wrap
        while (d < -180f) d += 360f;
        twistPrevDeg = now; // always, so re-entering never replays a stale sweep

        final float span = (float) Math.hypot(e.getX(1) - e.getX(0), e.getY(1) - e.getY(0));
        if (span < MIN_TWIST_SPAN_DP * density) return;

        if (!rotating) {
            twistAccumDeg += d;
            if (Math.abs(twistAccumDeg) < ROTATE_ENGAGE_DEG) return;
            rotating = true; // engaged: from here the twist tracks 1:1
        }
        if (Math.abs(d) < TWIST_DEADBAND_DEG) return;
        final float cx = getWidth() * 0.5f / density, cy = getHeight() * 0.5f / density;
        final double r = Math.toRadians(d);
        // A unit vector before and after the sweep, offset from the centre.
        onEngine(() -> lk.rotateDrag(cx + 100f, cy,
                cx + 100f * (float) Math.cos(r), cy + 100f * (float) Math.sin(r)));
    }

    /** Mouse / trackpad: the scroll wheel zooms about the cursor (the natural
     *  zoom on the emulator, where pinch needs a modifier key). Also called by
     *  the Activity's onGenericMotionEvent fallback — scroll events arrive
     *  there instead when the pointer isn't hover-focused on this view. */
    public boolean handleScroll(MotionEvent e) {
        if (e.getActionMasked() != MotionEvent.ACTION_SCROLL || lk == null) return false;
        float v = e.getAxisValue(MotionEvent.AXIS_VSCROLL);
        if (v == 0) v = e.getAxisValue(MotionEvent.AXIS_SCROLL); // rotary encoders
        android.util.Log.i("lookout", "scroll: src=0x" + Integer.toHexString(e.getSource())
                + " v=" + v + " at (" + e.getX() + "," + e.getY() + ")");
        if (v == 0) return false;
        float x = e.getX(), y = e.getY();
        if (x <= 0 && y <= 0) { // no cursor position (rotary): zoom about center
            x = getWidth() * 0.5f;
            y = getHeight() * 0.5f;
        }
        final double dz = v * 0.5;
        final float zx = x / density, zy = y / density;
        onEngine(() -> lk.zoomAt(dz, zx, zy));
        return true;
    }

    @Override
    public boolean onGenericMotionEvent(MotionEvent e) {
        return handleScroll(e) || super.onGenericMotionEvent(e);
    }

    // ---- surface lifecycle --------------------------------------------------
    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        // dimensions arrive in surfaceChanged
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int wPx, int hPx) {
        final int wPts = Math.round(wPx / density), hPts = Math.round(hPx / density);
        final Surface surface = holder.getSurface();
        if (renderThread == null) {
            // The open is tens of seconds on a real library (one
            // tile57_chart_open per cell, 7000+, the atlas bake, Vulkan
            // bring-up) and it scales with the library, so on the UI thread it
            // is an ANR on every launch. Everything below runs off this thread.
            renderThread = new HandlerThread("lookout-render");
            renderThread.start();
            engine = new Handler(renderThread.getLooper());
        }
        final Handler h = engine;
        h.post(() -> {
            Lookout l = lk;
            if (l != null && l.isAttached()) {
                // A resize rebuilds the swapchain and the api lock it takes is
                // held for a whole frame, which is why this is not done on the
                // UI thread: there a rotation becomes an input-dispatch ANR.
                l.resize(wPts, hPts);
                return;
            }
            if (l != null && !l.attachSurface(surface, wPts, hPts)) {
                // The new surface would not offer the format the pipelines were
                // built for. A slow chart beats no chart, so reopen.
                android.util.Log.w("lookout", "surface would not attach; reopening the library");
                controller.detach(l);
                l.close();
                lk = null;
                l = null;
            }
            if (l == null) {
                l = Lookout.openCharts(chartPaths, surface, wPx, hPx, wPts, hPts, true);
                if (l == null) return;
                // The surface's own extent lags a rotation, so the engine is
                // TOLD the scale rather than left to infer it, before the first
                // build.
                l.setDensity(density);
                // The symbols and the text are sized for 1x until the engine is
                // told the display's scale. Without this they draw too small
                // and their pick geometry with them.
                l.setDeviceScale(density);
                // Also before the first build: the mariner's saved settings and
                // the saved view, or the chart tessellates once at defaults and
                // again immediately. Safe inline, no frame runs until lk is
                // published.
                controller.attach(l, h);
                lk = l; // published LAST: onEngine and doFrame both gate on it
            }
            lastFrameNs = 0; // a new surface is not a continuation of the old
            // Choreographer is per-thread; this already IS the render thread.
            Choreographer.getInstance().postFrameCallback(this);
        });
    }

    /**
     * The surface is going, but the engine is not. Android destroys a
     * SurfaceView's surface every time the app backgrounds, and reopening the
     * library on the way back costs seconds; only the Vulkan surface and its
     * swapchain have to go, so the plugins keep running and an alarm nobody has
     * answered goes on sounding.
     *
     * Blocks until the render thread has stopped drawing and let the surface
     * go, because the platform frees it the moment this returns. Both the frame
     * callback and the detach run on that one thread, so a single barrier
     * covers both, and the wait is far shorter than the close this replaced.
     */
    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        final Handler h = engine;
        final Lookout l = lk;
        if (h == null || l == null) return;
        final CountDownLatch done = new CountDownLatch(1);
        h.post(() -> {
            Choreographer.getInstance().removeFrameCallback(this);
            l.detachSurface();
            done.countDown();
        });
        try {
            done.await();
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }

    /**
     * The view itself is going: switching chart library replaces it, and so
     * does the Activity being destroyed. The engine still belongs to this view,
     * so it closes with it. Externally serialized the way the C ABI asks, by
     * stopping the render thread first.
     */
    @Override
    protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        if (renderThread != null) {
            renderThread.quitSafely();
            try {
                renderThread.join();
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            renderThread = null;
            engine = null;
        }
        // Nothing is in flight now; drop the controller's reference before the
        // handle dies, passing OUR handle so a later teardown cannot detach the
        // controller from a newer view's engine.
        controller.detach(lk);
        if (lk != null) {
            lk.close();
            lk = null;
        }
    }

    // ---- frame loop (render thread) -----------------------------------------
    /**
     * Pan by however far the touch focus travelled between the last frame and
     * this one, read off the track at each frame's own timestamp. Interpolates
     * between the two samples bracketing that instant; past the newest sample it
     * extrapolates the last leg's velocity a little, which is what keeps a steady
     * drag stepping evenly when a touch report happens to land just after a frame.
     * A held-still finger extrapolates a zero velocity, so nothing creeps.
     */
    private void applyPan(Lookout l, long frameTimeNanos) {
        final long t = frameTimeNanos - RESAMPLE_LAG_NS;
        float x, y;
        final int epoch;
        synchronized (trackLock) {
            if (trackCount == 0) return;
            epoch = trackEpoch;
            final int head = trackHead;
            if (t >= trackT[head]) {
                x = trackX[head];
                y = trackY[head];
                if (trackCount >= 2) {
                    final int prev = (head - 1 + TRACK_N) % TRACK_N;
                    final long span = trackT[head] - trackT[prev];
                    if (span > 0 && span <= MAX_PREDICT_BASE_NS) {
                        final float f = Math.min(t - trackT[head], MAX_PREDICT_NS) / (float) span;
                        x += (trackX[head] - trackX[prev]) * f;
                        y += (trackY[head] - trackY[prev]) * f;
                    }
                }
            } else {
                // Walk back to the newest sample at or before t; anything older
                // than the whole track clamps to its oldest sample.
                int hi = head, n = 1;
                while (n < trackCount && trackT[hi] > t) {
                    hi = (hi - 1 + TRACK_N) % TRACK_N;
                    n++;
                }
                final int lo = hi;
                final int up = (hi + 1) % TRACK_N;
                if (trackT[lo] >= t || n >= trackCount) {
                    x = trackX[lo];
                    y = trackY[lo];
                } else {
                    final long span = trackT[up] - trackT[lo];
                    final float f = span > 0 ? (t - trackT[lo]) / (float) span : 0f;
                    x = trackX[lo] + (trackX[up] - trackX[lo]) * f;
                    y = trackY[lo] + (trackY[up] - trackY[lo]) * f;
                }
            }
        }
        if (haveLast && epoch == lastEpoch) {
            final float dx = x - lastFx, dy = y - lastFy;
            // The chart drags WITH the finger, so the camera pans by the focus delta.
            if (dx != 0f || dy != 0f) l.pan(dx / density, dy / density);
        }
        lastFx = x;
        lastFy = y;
        lastEpoch = epoch;
        haveLast = true;
    }

    @Override
    public void doFrame(long frameTimeNanos) {
        Lookout l = lk;
        // No handle, or a handle with no surface to present on: either way stop
        // rescheduling. surfaceChanged starts the loop again when one arrives.
        if (l == null || !l.isAttached()) return;
        double dt = lastFrameNs == 0 ? 0.0 : (frameTimeNanos - lastFrameNs) / 1e9;
        lastFrameNs = frameTimeNanos;
        if (dt > 0.1) dt = 0.1; // resumed from pause: don't lurch the ease
        // Before anything reads the camera: this frame's share of the drag.
        applyPan(l, frameTimeNanos);
        boolean animating = l.animating();
        if (animating && dt > 0) l.tickAnim(dt);
        if (animating || l.needsRedraw()) l.render();
        // Sample the HUD here rather than on a timer: the readouts describe the
        // frame that was just presented. The controller throttles the push.
        controller.onFrameRendered(frameTimeNanos);
        Choreographer.getInstance().postFrameCallback(this); // this thread's Choreographer
    }
}
