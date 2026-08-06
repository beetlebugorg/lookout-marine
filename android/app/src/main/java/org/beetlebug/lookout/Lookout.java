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

    /**
     * Point the engine's atlas cache at a writable directory, before any open.
     * Android has no cache path in the environment, so without this the symbol
     * and glyph atlases are re-rasterized on every launch.
     */
    public static void setCacheDir(String path) {
        nSetCacheDir(path);
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
    /** DisplayMetrics.density; set before the first build. */
    public void setDensity(float d)              { if (h != 0) nSetDensity(h, d); }

    /**
     * The display's device pixels per reference pixel. It sizes symbols, text
     * and every label's collision box, and the engine sizes for 1x until it is
     * told otherwise. It describes the DISPLAY, so the settings form does not
     * carry it and setMariner preserves it.
     */
    public void setDeviceScale(float scale)      { if (h != 0) nSetDeviceScale(h, scale); }
    public void fitChart()                       { if (h != 0) nFitChart(h); }
    /** The opening view when nothing was saved: library framed, overview zoom. */
    public void defaultView()                    { if (h != 0) nDefaultView(h); }
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
    private static native void nSetCacheDir(String path);
    private static native void nClose(long h);
    private static native void nResize(long h, int wPts, int hPts);
    private static native void nSetDensity(long h, float d);
    private static native void nSetDeviceScale(long h, float scale);
    private static native void nFitChart(long h);
    private static native void nDefaultView(long h);
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

    // ---- raster charts ---------------------------------------------------
    //
    // A raster chart is a chart made of pictures the mariner supplies: MBTiles
    // of satellite imagery, or another vendor's chart rendered to tiles. They
    // draw BELOW the ENC, which then drops its opaque depth and land fills
    // wherever a picture covers, so the mariner keeps the contours, buoys,
    // lights and soundings and sees the water as well.
    //
    // Charts group into SETS by provider. Sets covering different water draw at
    // the same time; only sets covering the same water are a choice.

    /** Open a raster chart and add it to its set. False when it will not open. */
    public boolean rasterAdd(String path)        { return h != 0 && nRasterAdd(h, path); }

    /** Step to the next set covering the water in view, then to none. */
    public void rasterCycle()                    { if (h != 0) nRasterCycle(h); }

    /** The set drawn over this view, or "" when this water has no picture. */
    public String rasterActiveName()             { return h == 0 ? "" : nRasterActiveName(h); }

    /**
     * A set whose charts are in view, DRAWN OR NOT. This is what lets the pill
     * say "there is a picture here" while it is switched off — without it a
     * mariner sailing into coverage never learns the chart is under them.
     */
    public String rasterAvailableName()          { return h == 0 ? "" : nRasterAvailableName(h); }

    /**
     * True while the ENC is drawing WITHOUT its opaque fills, because a picture
     * is beneath THIS view. Not the same as "a set is selected": the mode
     * engages only where a chart actually covers.
     */
    public boolean rasterOverChart()             { return h != 0 && nRasterOverChart(h); }

    public int rasterSetCount()                  { return h == 0 ? 0 : nRasterSetCount(h); }
    public String rasterSetName(int i)           { return h == 0 ? "" : nRasterSetName(h, i); }
    public boolean rasterSetInView(int i)        { return h != 0 && nRasterSetInView(h, i); }

    /** Which set is drawn over this view, or -1. */
    public int rasterActiveIndex()               { return h == 0 ? -1 : nRasterActiveIndex(h); }

    /** Draw set i. -1 turns off what is drawn over THIS view, not every set. */
    public void rasterSelect(int i)              { if (h != 0) nRasterSelect(h, i); }

    /** Switch one chart off without removing it. These are big downloads. */
    public boolean rasterSetEnabled(String path, boolean on) {
        return h != 0 && nRasterSetEnabled(h, path, on);
    }
    public boolean rasterEnabled(String path)    { return h != 0 && nRasterEnabled(h, path); }

    /** Hide the ENC wherever a raster chart covers, and show it again. */
    public void toggleChart()                    { if (h != 0) nToggleChart(h); }
    public boolean chartHidden()                 { return h != 0 && nChartHidden(h); }

    private static native boolean nRasterAdd(long h, String path);
    private static native void nRasterCycle(long h);
    private static native String nRasterActiveName(long h);
    private static native String nRasterAvailableName(long h);
    private static native boolean nRasterOverChart(long h);
    private static native int nRasterSetCount(long h);
    private static native String nRasterSetName(long h, int i);
    private static native boolean nRasterSetInView(long h, int i);
    private static native int nRasterActiveIndex(long h);
    private static native void nRasterSelect(long h, int i);
    private static native boolean nRasterSetEnabled(long h, String path, boolean on);
    private static native boolean nRasterEnabled(long h, String path);
    private static native void nToggleChart(long h);
    private static native boolean nChartHidden(long h);
}
