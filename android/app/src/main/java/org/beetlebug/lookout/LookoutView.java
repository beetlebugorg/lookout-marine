package org.beetlebug.lookout;

import android.content.Context;
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

    private final String chartPath;
    private final float density;
    private Lookout lk;
    private long lastFrameNs;
    private final GestureDetector gestures;
    private final ScaleGestureDetector scaler;

    public LookoutView(Context context, String chartPath) {
        super(context);
        this.chartPath = chartPath;
        float d = context.getResources().getDisplayMetrics().density;
        this.density = d > 0 ? d : 1f;
        getHolder().addCallback(this);

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

            @Override
            public void onLongPress(MotionEvent e) {
                if (lk != null) lk.cycleScheme();
            }

            @Override
            public boolean onDown(MotionEvent e) {
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

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        // Both detectors see every event: pinch zooms while its focal-point
        // drift still pans (the Google-Maps feel).
        scaler.onTouchEvent(e);
        gestures.onTouchEvent(e);
        return true;
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
            lk = Lookout.open(chartPath, holder.getSurface(), wPx, hPx, wPts, hPts, true);
            lastFrameNs = 0;
            Choreographer.getInstance().postFrameCallback(this);
        } else {
            lk.resize(wPts, hPts);
        }
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        Choreographer.getInstance().removeFrameCallback(this);
        if (lk != null) {
            lk.close();
            lk = null;
        }
    }

    // ---- frame loop ----------------------------------------------------------
    @Override
    public void doFrame(long frameTimeNanos) {
        if (lk == null) return;
        double dt = lastFrameNs == 0 ? 0.0 : (frameTimeNanos - lastFrameNs) / 1e9;
        lastFrameNs = frameTimeNanos;
        if (dt > 0.1) dt = 0.1; // resumed from pause: don't lurch the ease
        boolean animating = lk.animating();
        if (animating && dt > 0) lk.tickAnim(dt);
        if (animating || lk.needsRedraw()) lk.render();
        Choreographer.getInstance().postFrameCallback(this);
    }
}
