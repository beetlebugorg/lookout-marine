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
 * Threading: the native side holds an api lock per call, so gestures (main
 * thread) and the frame loop (LookoutView's render thread) may call
 * concurrently. close() is the exception — stop the render thread first
 * (LookoutView.surfaceDestroyed does).
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

    /**
     * Open a chart LIBRARY: many baked cells composed into one seamless view,
     * the engine choosing the owner per tile from its band/tier partition.
     * Returns null on failure. One path behaves exactly like open().
     */
    public static Lookout openCharts(String[] chartPaths, Surface surface,
                                     int widthPx, int heightPx,
                                     int widthPts, int heightPts, boolean msaa) {
        long h = nOpenCharts(chartPaths, surface, widthPx, heightPx, widthPts, heightPts, msaa);
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

    // ---- HUD readouts ------------------------------------------------------

    /** Length of the {@link #readouts} array. */
    public static final int READOUTS_LEN = 7;
    public static final int R_LON = 0, R_LAT = 1, R_ZOOM = 2, R_ROTATION_DEG = 3,
                            R_OVERSCALE = 4, R_SCALE_DENOM = 5, R_BUILDING = 6;

    /**
     * Fill {@code out} (length >= {@link #READOUTS_LEN}) with everything the
     * HUD shows, in one crossing. Pass a reusable array: this runs off the
     * frame loop, so it must not allocate.
     */
    public void readouts(double[] out)           { if (h != 0) nReadouts(h, out); }

    public void setView(double lon, double lat, double zoom, double rotationDeg) {
        if (h != 0) nSetView(h, lon, lat, zoom, rotationDeg);
    }

    /** Logical points -> geographic. Fills {@code out} as {lon, lat}. */
    public void screenToGeo(float xPts, float yPts, double[] out) {
        if (h != 0) nScreenToGeo(h, xPts, yPts, out);
    }

    /** Snap the view back to north-up. */
    public void resetRotation()                  { if (h != 0) nResetRotation(h); }

    /** Two-finger twist: rotate about the centre by the swept angle (pts). */
    public void rotateDrag(float x0, float y0, float x1, float y1) {
        if (h != 0) nRotateDrag(h, x0, y0, x1, y1);
    }

    /** Momentum pan, logical points/second. (0,0) stops a coast. */
    public void flingStart(double vx, double vy)  { if (h != 0) nFlingStart(h, vx, vy); }

    /** onTrimMemory: drop reclaimable engine caches. */
    public void memoryWarning()                   { if (h != 0) nMemoryWarning(h); }

    // ---- mariner (all S-52 display settings) -------------------------------

    /**
     * Number of mariner fields that cross as a flat double[]. The index
     * meanings live in {@link MarinerState} (Kotlin) and mirror the MI block in
     * src/jni_android.zig — the two must be edited together.
     */
    public static final int MARINER_LEN = 27;

    /** Fill {@code out} (length >= {@link #MARINER_LEN}) from the engine. */
    public void getMariner(double[] out)          { if (h != 0) nGetMariner(h, out); }

    /** The mariner's "YYYYMMDD" view date, or "" for today. */
    public String getMarinerDate()                { return h == 0 ? "" : nGetMarinerDate(h); }

    /**
     * Apply the surfaced fields. Fields the UI doesn't surface (device_scale,
     * viewing groups, …) are preserved: the native side overlays these onto the
     * engine's current struct rather than replacing it.
     */
    public void setMariner(double[] vals, String dateView) {
        if (h != 0) nSetMariner(h, vals, dateView);
    }

    // ---- pick --------------------------------------------------------------

    /**
     * S-52 cursor pick at a geographic point. Returns flat (class, s57, chart)
     * triples — one per feature under the point — or null on failure.
     */
    public String[] pick(double lon, double lat) { return h == 0 ? null : nPick(h, lon, lat); }

    private static native long nOpen(String chartPath, Surface surface,
                                     int widthPx, int heightPx,
                                     int widthPts, int heightPts, boolean msaa);
    private static native long nOpenCharts(String[] chartPaths, Surface surface,
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
    private static native void nReadouts(long h, double[] out);
    private static native void nSetView(long h, double lon, double lat, double zoom, double rotationDeg);
    private static native void nScreenToGeo(long h, float xPts, float yPts, double[] out);
    private static native void nResetRotation(long h);
    private static native void nRotateDrag(long h, float x0, float y0, float x1, float y1);
    private static native void nFlingStart(long h, double vx, double vy);
    private static native void nMemoryWarning(long h);
    private static native void nGetMariner(long h, double[] out);
    private static native String nGetMarinerDate(long h);
    private static native void nSetMariner(long h, double[] vals, String dateView);
    private static native String[] nPick(long h, double lon, double lat);
}
