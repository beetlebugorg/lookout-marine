package org.beetlebug.lookout;

import android.content.Context;
import android.os.Handler;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

/**
 * The chart view: a SurfaceView the Zig core renders into via Vulkan, with
 * platform gesture recognizers driving the camera — one finger pans, pinch
 * zooms about the focal point, double-tap zooms in a level, long-press cycles
 * day/dusk/night.
 *
 * It does NOT own the engine. {@link ChartEngine} does, for the whole process,
 * and this hands it a surface while there is one to hand over: Android destroys
 * a SurfaceView's surface every time the app backgrounds, and the engine has to
 * outlive that. What belongs here is the surface, the gestures and the touch
 * track, and one frame hook that turns that track into the pan the engine
 * applies before it draws.
 *
 * All camera calls are in LOGICAL points: pixel coordinates divide by the
 * display density before crossing into the core (whose camera unit is dp).
 */
public final class LookoutView extends SurfaceView implements SurfaceHolder.Callback {

    // Every cell to compose, not one chart: a pushed library is opened whole.
    private final String[] chartPaths;
    private final float density;
    private final ChartController controller;
    private final ChartEngine engine = ChartEngine.get();

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

    /** Something to do to the engine, on the engine's own thread. */
    private interface EngineTask {
        void run(Lookout l);
    }

    /**
     * Run something on the render thread, or drop it if there is no engine yet.
     * Gestures post instead of calling in directly: the C ABI's per-handle lock
     * is held for a whole frame, so a UI-thread call froze for that long.
     */
    private void onEngine(EngineTask t) {
        Handler h = engine.getQueue();
        if (h == null) return;
        h.post(() -> {
            Lookout l = engine.getLookout();
            if (l != null) t.run(l);
            // The frame loop may have stood down; a gesture is a frame.
            engine.kick();
        });
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
                onEngine(l -> l.zoomAt(1.0, x, y));
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
                onEngine(l -> l.flingStart(vx / density, vy / density));
                return true;
            }

            /** The chart menu, as the reference's right-click raises it: the
             *  place's coordinates, the pick, and the marker verbs. The scheme
             *  cycle this gesture used to spend itself on lives in Settings ›
             *  Display, where the pick persists either way. */
            @Override
            public void onLongPress(MotionEvent e) {
                controller.showChartMenu(e.getX() / density, e.getY() / density);
            }

            @Override
            public boolean onDown(MotionEvent e) {
                // A new grab stops any coast, so the chart doesn't slide out
                // from under the finger that just caught it.
                onEngine(l -> l.flingStart(0, 0));
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
                    onEngine(l -> l.zoomAt(dz, fx, fy));
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
    // Once the gesture is clearly a ZOOM — the finger span has changed by
    // this ratio either way — rotation stays out for the rest of it. A long
    // pinch drifts a degree here and a degree there, and the accumulated
    // drift used to cross the engage angle mid-zoom: the chart turned when
    // nobody asked. A deliberate twist reaches the engage angle long before
    // its span changes this much.
    private static final float TWIST_ZOOM_LOCKOUT_RATIO = 1.25f;
    private boolean rotating;
    private boolean twistLocked;
    private float twistPrevDeg, twistAccumDeg, twistDownSpan;

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
                // The pan stream is consumed BY the frame loop (the resampler
                // hook), so the loop must run for the whole touch. Without
                // this it stood down during the slop's quiet frames and the
                // entire drag applied at the lift.
                engine.setGestureActive(true);
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
                    twistDownSpan = (float) Math.hypot(e.getX(1) - e.getX(0), e.getY(1) - e.getY(0));
                    twistLocked = false;
                    rotating = false;
                } else {
                    twoTap = false; // third finger: not a two-finger tap
                }
                breakTrack(); // the focus moves to the mean of one more finger
                break;
            case MotionEvent.ACTION_MOVE:
                // With TWO fingers down the pan stands aside, as the
                // reference shell's pinch cancels its pan: the zoom's own
                // anchor keeps the chart under the fingers, and feeding the
                // focus drift to the pan AS WELL fights that correction
                // frame by frame — the chart visibly shakes while zooming.
                if (e.getPointerCount() >= 2) {
                    // nothing recorded: applyPan sees no track and sits out
                } else if (dragging) {
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
                engine.setGestureActive(false);
                if (twoTap && e.getEventTime() - twoDownMs < 300) {
                    final float mx = twoMidX / density, my = twoMidY / density;
                    onEngine(l -> l.zoomAt(-1.0, mx, my));
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
                engine.setGestureActive(false);
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
            if (twistLocked) return;
            // The zoom lockout: the span moving is the pinch announcing
            // itself, and from then on this gesture does not rotate.
            if (twistDownSpan > 0) {
                float ratio = span / twistDownSpan;
                if (ratio > TWIST_ZOOM_LOCKOUT_RATIO || ratio < 1f / TWIST_ZOOM_LOCKOUT_RATIO) {
                    twistLocked = true;
                    return;
                }
            }
            twistAccumDeg += d;
            if (Math.abs(twistAccumDeg) < ROTATE_ENGAGE_DEG) return;
            rotating = true; // engaged: from here the twist tracks 1:1
        }
        if (Math.abs(d) < TWIST_DEADBAND_DEG) return;
        final float cx = getWidth() * 0.5f / density, cy = getHeight() * 0.5f / density;
        final double r = Math.toRadians(d);
        // A unit vector before and after the sweep, offset from the centre.
        onEngine(l -> l.rotateDrag(cx + 100f, cy,
                cx + 100f * (float) Math.cos(r), cy + 100f * (float) Math.sin(r)));
    }

    /** Mouse / trackpad: the scroll wheel zooms about the cursor (the natural
     *  zoom on the emulator, where pinch needs a modifier key). Also called by
     *  the Activity's onGenericMotionEvent fallback — scroll events arrive
     *  there instead when the pointer isn't hover-focused on this view. */
    public boolean handleScroll(MotionEvent e) {
        if (e.getActionMasked() != MotionEvent.ACTION_SCROLL || engine.getLookout() == null) return false;
        float v = e.getAxisValue(MotionEvent.AXIS_VSCROLL);
        if (v == 0) v = e.getAxisValue(MotionEvent.AXIS_SCROLL); // rotary encoders
        if (v == 0) return false;
        float x = e.getX(), y = e.getY();
        if (x <= 0 && y <= 0) { // no cursor position (rotary): zoom about center
            x = getWidth() * 0.5f;
            y = getHeight() * 0.5f;
        }
        final double dz = v * 0.5;
        final float zx = x / density, zy = y / density;
        onEngine(l -> l.zoomAt(dz, zx, zy));
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

    /**
     * Hand the surface to the engine. It opens the library on the first one and
     * starts its frame loop on every one; a size change on a surface it already
     * holds is a resize.
     */
    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int wPx, int hPx) {
        final int wPts = Math.round(wPx / density), hPts = Math.round(hPx / density);
        engine.attach(holder.getSurface(), chartPaths, controller, density,
                wPx, hPx, wPts, hPts, this::applyPan);
    }

    /**
     * Take the surface back. The engine keeps everything else, so returning
     * from the background costs a swapchain instead of an open of the whole
     * library, and the plugins go on running with their alerts intact.
     *
     * The engine blocks until its render thread has let the surface go, which
     * this call must do: the platform frees it the moment this returns.
     */
    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        engine.detach();
    }

    // ---- the frame hook (render thread) -------------------------------------
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
}
