package org.beetlebug.lookout;

import android.view.Surface;

/**
 * Java binding to the lookout-core C ABI (liblookout_jni.so — the Zig core
 * with its JNI natives, rendered via Vulkan straight onto the Surface).
 *
 * Units: every geometry-taking method works in LOGICAL points (dp) — divide
 * pixels by DisplayMetrics.density before calling. The one exception is
 * open(), whose widthPx/heightPx describe the Surface itself.
 *
 * Threading: call every method on the main thread (the native side assumes
 * it; gestures and Choreographer callbacks both land there naturally).
 */
public final class Lookout implements AutoCloseable {
    static {
        System.loadLibrary("lookout_jni");
    }

    private long h;

    private Lookout(long h) {
        this.h = h;
    }

    /** Open a baked chart onto a Surface. Returns null on failure. */
    public static Lookout open(String chartPath, Surface surface,
                               int widthPx, int heightPx,
                               int widthPts, int heightPts, boolean msaa) {
        long h = nOpen(chartPath, surface, widthPx, heightPx, widthPts, heightPts, msaa);
        return h == 0 ? null : new Lookout(h);
    }

    @Override
    public void close() {
        if (h != 0) {
            nClose(h);
            h = 0;
        }
    }

    public boolean isOpen()                      { return h != 0; }
    /** Logical points (px / density). */
    public void resize(int wPts, int hPts)       { if (h != 0) nResize(h, wPts, hPts); }
    public void fitChart()                       { if (h != 0) nFitChart(h); }
    /** Drag the chart with the finger: positive = finger delta, logical pts. */
    public void pan(float dxPts, float dyPts)    { if (h != 0) nPan(h, dxPts, dyPts); }
    /** Zoom by dz levels about a point (logical pts); eases via tickAnim. */
    public void zoomAt(double dz, float xPts, float yPts) { if (h != 0) nZoomAt(h, dz, xPts, yPts); }
    /** Render one frame; true when the frame presented. */
    public boolean render()                      { return h != 0 && nRender(h); }
    /** True while the view needs another frame (state changed, building). */
    public boolean needsRedraw()                 { return h != 0 && nNeedsRedraw(h); }
    /** True while a zoom ease / fling is running (drive tickAnim). */
    public boolean animating()                   { return h != 0 && nAnimating(h); }
    public void tickAnim(double dtSeconds)       { if (h != 0) nTickAnim(h, dtSeconds); }
    /** Cycle the S-52 colour scheme: day -> dusk -> night. */
    public void cycleScheme()                    { if (h != 0) nCycleScheme(h); }

    private static native long nOpen(String chartPath, Surface surface,
                                     int widthPx, int heightPx,
                                     int widthPts, int heightPts, boolean msaa);
    private static native void nClose(long h);
    private static native void nResize(long h, int wPts, int hPts);
    private static native void nFitChart(long h);
    private static native void nPan(long h, float dxPts, float dyPts);
    private static native void nZoomAt(long h, double dz, float xPts, float yPts);
    private static native boolean nRender(long h);
    private static native boolean nNeedsRedraw(long h);
    private static native boolean nAnimating(long h);
    private static native void nTickAnim(long h, double dt);
    private static native void nCycleScheme(long h);
}
