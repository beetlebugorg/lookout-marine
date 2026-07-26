package org.beetlebug.lookout;

import android.content.Context;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Choreographer;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

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
    // Written on the main thread (surfaceChanged/surfaceDestroyed), read on the
    // render thread — the C ABI's api lock serializes the actual native calls.
    private volatile Lookout lk;
    private long lastFrameNs;
    private final GestureDetector gestures;
    private final ScaleGestureDetector scaler;
    // Frames run on a dedicated render thread (the C ABI's intended shape:
    // gestures on main, lookout_render on a render thread). A rebuild after a
    // zoom re-tessellates for ~a second — on the main thread that froze the UI
    // ("Skipped N frames"); here it only occupies the render thread, and the
    // engine tessellation itself runs on a further worker inside the core.
    private HandlerThread renderThread;

    public LookoutView(Context context, String[] chartPaths, ChartController controller) {
        super(context);
        this.chartPaths = chartPaths;
        this.controller = controller;
        float d = context.getResources().getDisplayMetrics().density;
        this.density = d > 0 ? d : 1f;
        getHolder().addCallback(this);
        // Scroll/rotary events need a focus target; without this they dispatch
        // to the Activity (handled there too, but keep the direct path alive).
        setFocusable(true);
        setFocusableInTouchMode(true);
        requestFocus();

        gestures = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            @Override
            public boolean onScroll(MotionEvent e1, MotionEvent e2, float dx, float dy) {
                // distance is previous-minus-current; the chart drags WITH the finger
                if (lk != null) lk.pan(-dx / density, -dy / density);
                return true;
            }

            @Override
            public boolean onDoubleTap(MotionEvent e) {
                if (lk != null) lk.zoomAt(1.0, e.getX() / density, e.getY() / density);
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
                if (lk != null) lk.flingStart(vx / density, vy / density);
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
                if (lk != null) lk.flingStart(0, 0);
                return true; // claim the stream
            }
        });

        scaler = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override
            public boolean onScale(ScaleGestureDetector det) {
                float f = det.getScaleFactor();
                if (lk != null && f > 0) {
                    lk.zoomAt(Math.log(f) / Math.log(2.0),
                              det.getFocusX() / density, det.getFocusY() / density);
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
    private static final float ROTATE_ENGAGE_DEG = 10f;
    private boolean rotating;
    private float twistPrevDeg, twistAccumDeg;

    /** Angle of the vector between the first two pointers, in degrees. */
    private static float twistAngle(MotionEvent e) {
        return (float) Math.toDegrees(Math.atan2(e.getY(1) - e.getY(0), e.getX(1) - e.getX(0)));
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        switch (e.getActionMasked()) {
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
                break;
            case MotionEvent.ACTION_MOVE:
                if (twoTap && e.getPointerCount() >= 2) {
                    float mx = (e.getX(0) + e.getX(1)) * 0.5f;
                    float my = (e.getY(0) + e.getY(1)) * 0.5f;
                    if (Math.hypot(mx - twoMidX, my - twoMidY) > 24f * density) twoTap = false;
                }
                if (e.getPointerCount() >= 2) trackTwist(e);
                break;
            case MotionEvent.ACTION_UP:
                if (twoTap && lk != null && e.getEventTime() - twoDownMs < 300) {
                    lk.zoomAt(-1.0, twoMidX / density, twoMidY / density);
                }
                twoTap = false;
                rotating = false;
                break;
            case MotionEvent.ACTION_POINTER_UP:
                rotating = false; // down to one finger: the twist is over
                break;
            case MotionEvent.ACTION_CANCEL:
                twoTap = false;
                rotating = false;
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
        twistPrevDeg = now;

        if (!rotating) {
            twistAccumDeg += d;
            if (Math.abs(twistAccumDeg) < ROTATE_ENGAGE_DEG) return;
            rotating = true; // engaged: from here the twist tracks 1:1
        }
        if (lk == null) return;
        float cx = getWidth() * 0.5f / density, cy = getHeight() * 0.5f / density;
        double r = Math.toRadians(d);
        // A unit vector before and after the sweep, offset from the centre.
        lk.rotateDrag(cx + 100f, cy,
                      cx + 100f * (float) Math.cos(r), cy + 100f * (float) Math.sin(r));
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
        lk.zoomAt(v * 0.5, x / density, y / density);
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
        int wPts = Math.round(wPx / density), hPts = Math.round(hPx / density);
        if (lk == null) {
            lk = Lookout.openCharts(chartPaths, holder.getSurface(), wPx, hPx, wPts, hPts, true);
            if (lk == null) return;
            lastFrameNs = 0;
            // Before the render thread starts: attach restores the mariner's
            // saved settings, and they must be in place for the FIRST build or
            // the chart tessellates once at defaults and immediately again.
            controller.attach(lk);
            renderThread = new HandlerThread("lookout-render");
            renderThread.start();
            // Choreographer is per-thread: fetch it ON the render thread so the
            // vsync callbacks (and every render) land there.
            new Handler(renderThread.getLooper()).post(
                    () -> Choreographer.getInstance().postFrameCallback(this));
        } else {
            lk.resize(wPts, hPts);
        }
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        // close() must be externally serialized against every other call (the
        // C ABI contract): stop the render thread first, then close.
        if (renderThread != null) {
            renderThread.quitSafely();
            try {
                renderThread.join();
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            renderThread = null;
        }
        // The render thread is stopped, so no more native calls are in flight;
        // drop the controller's reference before the handle dies — passing OUR
        // handle so a later teardown can't detach the controller from a newer
        // view's engine (switching library recreates this view).
        controller.detach(lk);
        if (lk != null) {
            lk.close();
            lk = null;
        }
    }

    // ---- frame loop (render thread) -----------------------------------------
    @Override
    public void doFrame(long frameTimeNanos) {
        Lookout l = lk;
        if (l == null) return; // surface tearing down: stop rescheduling
        double dt = lastFrameNs == 0 ? 0.0 : (frameTimeNanos - lastFrameNs) / 1e9;
        lastFrameNs = frameTimeNanos;
        if (dt > 0.1) dt = 0.1; // resumed from pause: don't lurch the ease
        boolean animating = l.animating();
        if (animating && dt > 0) l.tickAnim(dt);
        if (animating || l.needsRedraw()) l.render();
        // Sample the HUD here rather than on a timer: the readouts describe the
        // frame that was just presented. The controller throttles the push.
        controller.onFrameRendered(frameTimeNanos);
        Choreographer.getInstance().postFrameCallback(this); // this thread's Choreographer
    }
}
