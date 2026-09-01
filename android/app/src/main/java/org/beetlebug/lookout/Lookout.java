package org.beetlebug.lookout;

import org.beetlebug.lookout.settings.MI;
import org.beetlebug.lookout.settings.MarinerState;

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
 * thread) and the frame loop (the render thread) may call concurrently.
 * close(), attachSurface() and detachSurface() are the exceptions: run them on
 * the render thread with the frame loop stopped.
 *
 * COMPLETENESS IS DELIBERATE. This class mirrors include/lookout.h whole, and
 * some of what it binds no Kotlin here calls: altStyleActive, pluginConfigGet,
 * rasterEnabled, rasterOverChart, isOpen, and the three portrayal quick
 * toggles, which the Mac reaches from its menu bar and this shell has no route
 * to. Those are gaps in the SHELL, not in the binding, so they stay bound. A
 * method removed here would have to be found again by reading the header.
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

    /**
     * Add baked charts to the open library; answers how many opened. The
     * heavy per-cell opens run off the engine lock, so a background thread
     * may call this while the chart draws — how the link-first startup
     * brings the library installed behind an already-drawing chart link.
     */
    public int chartsAdd(String[] paths) { return h == 0 ? 0 : nChartsAdd(h, paths); }

    @Override
    public void close() {
        if (h != 0) {
            nClose(h);
            h = 0;
        }
    }

    /**
     * Give up the Surface without closing the chart. Android destroys a
     * SurfaceView's surface every time the app backgrounds, and the library
     * behind it takes seconds to reopen; only the Vulkan surface and swapchain
     * have to go. Also hands the engine's reclaimable caches back, since no
     * frame will run to do it.
     *
     * Externally serialized like {@link #close}: no other call in flight, and
     * no rendering until {@link #attachSurface} has answered true.
     */
    public void detachSurface() {
        if (h == 0) return;
        nDetachSurface(h);
        attached = false;
    }

    /**
     * Present on a new Surface. False when it cannot be adopted, which leaves
     * the engine detached for the caller to reopen.
     */
    public boolean attachSurface(Surface surface, int wPts, int hPts) {
        if (h == 0) return false;
        attached = nAttachSurface(h, surface, wPts, hPts);
        return attached;
    }

    /** True while a Surface is attached and frames can run. */
    public boolean isAttached()                  { return attached; }

    /** Written on the render thread beside the calls above, read anywhere. */
    private volatile boolean attached = true;

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

    // ---- the frame loop ----

    /** Nothing to advance and something to draw. */
    public static final int FRAME_RENDER = 0;
    /** Nothing to draw yet, and something is coming: ask again in waitMs. */
    public static final int FRAME_WAIT = 1;
    /** Nothing is moving. Stop the loop; frameKick starts it again. */
    public static final int FRAME_IDLE = 2;

    /**
     * One tick, into {verdict, waitMs, building}. The gap since the last tick
     * is measured in the core and capped there, and the fling and the queued
     * chart-link answers are advanced with it.
     */
    public void frameNext(int[] out)             { if (h != 0) nFrameNext(h, out); }

    /** Start the loop again after a change the shell made itself: a gesture,
     *  an opened chart, a setting. */
    public void frameKick()                      { if (h != 0) nFrameKick(h); }
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
    /** Whether the next open skips the one-time symbol rasterize. */
    public static boolean atlasCacheReady()       { return nAtlasCacheReady(); }
    /** Offer an opened file to the plugins: 1 claimed, 0 none, -1 failed. */
    public int openFile(String path)              { return h == 0 ? 0 : nOpenFile(h, path); }
    /** This app's terms and every component it ships, as JSON. Baked into the
     *  binary, so it needs no chart open. */
    /**
     * This app's terms, then every component this shell ships with: fourteen
     * strings each, the app's entry first. The core filters by shell, so this
     * is this build's list and no other's. Needs no chart open.
     */
    public static String[] licenses()             { return nLicenses(); }

    // ---- the settings store ----
    //
    // One ini file under the app's own directory, replacing four
    // SharedPreferences files. See Store.kt.

    public static long storeOpen(String dir)      { return nStoreOpen(dir); }
    public static void storeClose(long s)         { if (s != 0) nStoreClose(s); }
    public static void storeFlush(long s)         { if (s != 0) nStoreFlush(s); }

    public static boolean storeHas(long s, String group, String key) {
        return s != 0 && nStoreHas(s, group, key);
    }
    /** Null when the key is not set, which is not an empty value. */
    public static String storeText(long s, String group, String key) {
        return s == 0 ? null : nStoreText(s, group, key);
    }
    public static double storeNumber(long s, String group, String key, double fallback) {
        return s == 0 ? fallback : nStoreNumber(s, group, key, fallback);
    }
    public static boolean storeFlag(long s, String group, String key, boolean fallback) {
        return s == 0 ? fallback : nStoreFlag(s, group, key, fallback);
    }
    public static String[] storeList(long s, String group, String key) {
        return s == 0 ? new String[0] : nStoreList(s, group, key);
    }
    /** The keys set under a group, in the order they were written. */
    public static String[] storeKeys(long s, String group) {
        return s == 0 ? new String[0] : nStoreKeys(s, group);
    }

    public static void storeSetText(long s, String group, String key, String value) {
        if (s != 0) nStoreSetText(s, group, key, value);
    }
    public static void storeSetNumber(long s, String group, String key, double value) {
        if (s != 0) nStoreSetNumber(s, group, key, value);
    }
    public static void storeSetFlag(long s, String group, String key, boolean value) {
        if (s != 0) nStoreSetFlag(s, group, key, value);
    }
    /** An empty list clears the key. */
    public static void storeSetList(long s, String group, String key, String[] items) {
        if (s != 0) nStoreSetList(s, group, key, items);
    }
    public static void storeRemove(long s, String group, String key) {
        if (s != 0) nStoreRemove(s, group, key);
    }

    // ---- the installed sets ----
    //
    // The folders of charts the mariner added, which of them are drawn, and
    // what each holds. The chart is the UNION of the sets switched on. No chart
    // handle: the sets exist before anything is open. See ChartSets.kt.

    public static long chartSetsOpen(long store, String preparedRoot) {
        return nChartSetsOpen(store, preparedRoot);
    }
    public static void chartSetsClose(long s)     { if (s != 0) nChartSetsClose(s); }
    /** True since the last poll, then clears. A background scan landing raises
     *  it, and that is the only change the sets announce on their own. */
    public static boolean chartSetsChanged(long s) {
        return s != 0 && nChartSetsChanged(s);
    }
    /** The list, in the order added: eleven strings per set. */
    public static String[] chartSetsAll(long s)   {
        return s == 0 ? new String[0] : nChartSetsAll(s);
    }
    /** Every file one set holds, in the scan read's own row shape. */
    public static String[] chartSetFiles(long s, String path) {
        return s == 0 ? new String[0] : nChartSetFiles(s, path);
    }
    public static boolean chartSetsAdd(long s, String path) {
        return s != 0 && nChartSetsAdd(s, path);
    }
    public static boolean chartSetsRemove(long s, String path) {
        return s != 0 && nChartSetsRemove(s, path);
    }
    public static boolean chartSetsSetOn(long s, String path, boolean on) {
        return s != 0 && nChartSetsSetOn(s, path, on);
    }
    public static boolean chartSetsIsOn(long s, String path) {
        return s != 0 && nChartSetsIsOn(s, path);
    }
    /** Every chart the switched-on sets hold, sorted and deduplicated. */
    public static String[] chartSetsCompose(long s) {
        return s == 0 ? new String[0] : nChartSetsCompose(s);
    }

    /**
     * Hand the store to this chart handle. The engine then restores the camera
     * pose and the mariner's display settings out of it, writes the pose down
     * as the mariner moves, and writes both at close and at detach.
     */
    public void setStore(long store)              { if (h != 0) nSetStore(h, store); }

    // ---- the format kit ----
    //
    // The strings a mariner reads and the text a mariner types, from the
    // engine, so every shell prints and accepts the same thing. None of it
    // needs a chart open.

    /** A full position, latitude first: "38\u00B058.578'N 076\u00B028.920'W". */
    public static String fmtPosition(double lat, double lon) { return nFmtPosition(lat, lon); }

    /** One half of a position, in degrees and decimal minutes. */
    public static String fmtCoordDm(double value, boolean isLat) { return nFmtCoordDm(value, isLat); }

    /** The 1:N display scale with group separators: "1:13,267". */
    public static String fmtScale(double denominator)  { return nFmtScale(denominator); }

    /** The S-52 navigational purpose band for a display scale. */
    public static String bandName(double denominator)  { return nBandName(denominator); }

    /** {lat, lon} for a position the mariner typed, or null. */
    public static double[] parsePosition(String text)  { return nParsePosition(text); }

    /** The denominator for a scale the mariner typed, or 0. */
    public static double parseScale(String text)       { return nParseScale(text); }

    /** A wanted display scale as a zoom delta, to hand to zoomAt. */
    public static double zoomDeltaForScale(double current, double wanted) {
        return nZoomDeltaForScale(current, wanted);
    }

    /** What to call the set a raster file belongs to. The engine's own rule,
     *  the one it names the sets it draws by, so grouping by anything else
     *  disagrees with what the pill then shows. Needs no chart open. */
    public static String rasterSetNameFor(String path) { return nRasterSetNameFor(path); }

    // ---- mariner (all S-52 display settings) -------------------------------

    /**
     * Number of mariner fields that cross as a flat double[]. The index
     * meanings live in {@link MarinerState} (Kotlin) and mirror the MI block in
     * src/jni_android.zig — the two must be edited together.
     */
    public static final int MARINER_LEN = 27;

    /**
     * The mariner field names, in index order, as the engine declares them.
     *
     * The crossing is a flat double[] with no names in it, so {@link MarinerState}
     * and the MI block in src/jni_android.zig have to agree field for field.
     * MARINER_LEN checks the length; this checks the order.
     */
    public static String[] marinerKeys()          { return nMarinerKeys(); }

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
     * S-52 cursor pick at a geographic point: the features under it, best
     * first, each as the page the engine composed. Eleven strings per feature,
     * then its notes, its report rows and its source rows. Null on failure.
     */
    public String[] pickRead(double lon, double lat) {
        return h == 0 ? null : nPickRead(h, lon, lat);
    }

    private static native long nOpen(String chartPath, Surface surface,
                                     int widthPx, int heightPx,
                                     int widthPts, int heightPts, boolean msaa);
    private static native int nChartsAdd(long h, String[] paths);
    private static native long nOpenCharts(String[] chartPaths, Surface surface,
                                           int widthPx, int heightPx,
                                           int widthPts, int heightPts, boolean msaa);
    private static native void nSetCacheDir(String path);
    private static native void nClose(long h);
    private static native void nDetachSurface(long h);
    private static native boolean nAttachSurface(long h, Surface surface, int wPts, int hPts);
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
    private static native void nFrameNext(long h, int[] out);
    private static native void nFrameKick(long h);
    private static native void nCycleScheme(long h);
    private static native void nReadouts(long h, double[] out);
    private static native void nSetView(long h, double lon, double lat, double zoom, double rotationDeg);
    private static native void nScreenToGeo(long h, float xPts, float yPts, double[] out);
    private static native void nResetRotation(long h);
    private static native void nRotateDrag(long h, float x0, float y0, float x1, float y1);
    private static native void nFlingStart(long h, double vx, double vy);
    private static native void nMemoryWarning(long h);
    private static native boolean nAtlasCacheReady();
    private static native int nOpenFile(long h, String path);
    private static native String[] nLicenses();
    private static native long nStoreOpen(String dir);
    private static native void nStoreClose(long s);
    private static native void nStoreFlush(long s);
    private static native boolean nStoreHas(long s, String group, String key);
    private static native String nStoreText(long s, String group, String key);
    private static native double nStoreNumber(long s, String group, String key, double fallback);
    private static native boolean nStoreFlag(long s, String group, String key, boolean fallback);
    private static native String[] nStoreList(long s, String group, String key);
    private static native String[] nStoreKeys(long s, String group);
    private static native void nStoreSetText(long s, String group, String key, String value);
    private static native void nStoreSetNumber(long s, String group, String key, double value);
    private static native void nStoreSetFlag(long s, String group, String key, boolean value);
    private static native void nStoreSetList(long s, String group, String key, String[] items);
    private static native void nStoreRemove(long s, String group, String key);
    private static native void nSetStore(long h, long store);
    private static native long nChartSetsOpen(long store, String preparedRoot);
    private static native void nChartSetsClose(long s);
    private static native boolean nChartSetsChanged(long s);
    private static native String[] nChartSetsAll(long s);
    private static native String[] nChartSetFiles(long s, String path);
    private static native boolean nChartSetsAdd(long s, String path);
    private static native boolean nChartSetsRemove(long s, String path);
    private static native boolean nChartSetsSetOn(long s, String path, boolean on);
    private static native boolean nChartSetsIsOn(long s, String path);
    private static native String[] nChartSetsCompose(long s);
    private static native String nFmtPosition(double lat, double lon);
    private static native String nFmtCoordDm(double value, boolean isLat);
    private static native String nFmtScale(double denominator);
    private static native String nBandName(double denominator);
    private static native double[] nParsePosition(String text);
    private static native double nParseScale(String text);
    private static native double nZoomDeltaForScale(double current, double wanted);
    private static native String nRasterSetNameFor(String path);
    private static native String[] nMarinerKeys();
    private static native void nGetMariner(long h, double[] out);
    private static native String nGetMarinerDate(long h);
    private static native void nSetMariner(long h, double[] vals, String dateView);
    private static native String[] nPickRead(long h, double lon, double lat);

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

    // ---- wasm plugins ------------------------------------------------------
    //
    // Own ship, AIS targets and laylines are wasm modules, not core code: they
    // read the vessel data a source plugin publishes and post overlay geometry
    // the engine draws with the chart. Android has no bundle Resources dir, so
    // the shell extracts the set out of the APK assets and names that directory
    // — see LookoutActivity.extractPlugins.
    //
    // A core built without the plugin host answers false/null to all of these
    // rather than failing to link.

    /** Load and start every plugin in {@code dir}. False when none could. */
    public boolean pluginsLoad(String dir)       { return h != 0 && nPluginsLoad(h, dir); }

    /**
     * True while a plugin layer is running. A plugin posts geometry from its
     * own thread with no gesture behind it, so a render-on-demand loop must
     * keep polling {@link #needsRedraw} while this holds.
     */
    public boolean pluginsActive()               { return h != 0 && nPluginsActive(h); }

    /**
     * What the source plugins' connection rows say between them, as two bits:
     * 1 a session is open to a gateway, 2 one is open or being dialled.
     *
     * Answered by walking the registry natively. The shell asks once a second,
     * and building the whole registry here to read a handful of strings was the
     * only work a backgrounded plotter did.
     */
    public int pluginsConnectionState()          { return h == 0 ? 0 : nPluginsConnectionState(h); }

    /** Every loaded plugin with its settings schema, as JSON. Null when none. */

    // ---- the plugin registry, read typed ----
    //
    // A read is a snapshot: one arena, every string borrowed from it, alive
    // until pluginsFree. Read it on one thread, decode it, free it.
    //
    // A READ OF 0 IS NOT AN EMPTY REGISTRY. pluginsRead returns 0 with no chart
    // open and in a build with the plugin layer compiled out; a core holding no
    // plugins returns a snapshot with no rows.

    public long pluginsRead()                    { return h == 0 ? 0 : nPluginsRead(h); }
    public static void pluginsFree(long p)       { if (p != 0) nPluginsFree(p); }

    public static int pluginCount(long p)        { return nPluginCount(p); }

    /** field: 0 id, 1 name, 2 version, 3 status. */
    public static String pluginText(long p, int i, int field) { return nPluginText(p, i, field); }
    /** field: 0 origin, 1 live. */
    public static int pluginInt(long p, int i, int field)     { return nPluginInt(p, i, field); }

    public static int capCount(long p, int i)    { return nCapCount(p, i); }
    /** field: 0 name, 1 sentence. */
    public static String capText(long p, int i, int c, int field) { return nCapText(p, i, c, field); }
    public static boolean capGranted(long p, int i, int c) { return nCapGranted(p, i, c) != 0; }
    public static String[] capAllows(long p, int i, int c) { return nCapAllows(p, i, c); }

    public static int settingCount(long p, int i)             { return nSettingCount(p, i); }
    /** How many fields one item of a list setting has. */
    public static int settingFieldCount(long p, int i, int s) { return nSettingFieldCount(p, i, s); }

    // A setting is addressed by (plugin, setting, fi). fi of -1 is the setting
    // itself; 0 or more is that setting's fi'th list field.

    /** field: 0 key, 1 label, 2 desc, 3 group, 4 unit, 5 defaultText,
     *  6 placeholder, 7 footer, 8 empty, 9 addLabel, 10 switchKey. */
    public static String settingText(long p, int i, int s, int fi, int field) {
        return nSettingText(p, i, s, fi, field);
    }
    /** field: 0 min, 1 max, 2 defaultNumber, 3 value. */
    public static double settingNumber(long p, int i, int s, int fi, int field) {
        return nSettingNumber(p, i, s, fi, field);
    }
    /** field: 0 kind, 1 section, 2 optional, 3 maxText, 4 maxItems. */
    public static int settingInt(long p, int i, int s, int fi, int field) {
        return nSettingInt(p, i, s, fi, field);
    }

    public static int itemCount(long p, int i, int s)            { return nItemCount(p, i, s); }
    public static String itemId(long p, int i, int s, int it)     { return nItemId(p, i, s, it); }
    /** One item's cells as {key, text, key, text, ...}. */
    public static String[] itemValues(long p, int i, int s, int it) { return nItemValues(p, i, s, it); }

    /** The DNS-SD service types a list setting declares. */
    public static String[] services(long p, int i, int s)         { return nServices(p, i, s); }
    /** What a row added from a find sets, as {key, text, ...}. */
    public static String[] serviceSet(long p, int i, int s, int sv) { return nServiceSet(p, i, s, sv); }

    /** One plugin's settings as a JSON object, or null for an unknown id. */
    public String pluginConfigGet(String id)     { return h == 0 ? null : nPluginConfigGet(h, id); }

    /** Apply settings to one plugin at once. {@code json} is a JSON object. */
    public boolean pluginConfigSet(String id, String json) {
        return h != 0 && nPluginConfigSet(h, id, json);
    }

    // ---- plugin alerts -----------------------------------------------------
    //
    // A plugin raises an alert with a severity, a title and a body; the core
    // orders the set and hands it over here. An alarm is audible and repeats
    // until it is acknowledged, a warning and a notice are visible only. See
    // PluginAlerts.kt.

    /**
     * Every live alert as {@code {"seq":N,"alerts":[…]}}, already ordered: what
     * nobody has answered first, then the loudest, then the oldest. {@code seq}
     * moves whenever the set changes, so a caller can leave the list alone
     * while it has not. Null when no plugin layer is up.
     */

    /**
     * Every alert raised and not yet seen off: the seq, then seven strings per
     * alert (id, plugin, severity, title, body, raised, acknowledged).
     *
     * Null is "the core said nothing", which is not "there are no alerts".
     */
    public String[] alerts()                     { return h == 0 ? null : nAlerts(h); }

    /**
     * Silence ONE alert: it stops sounding and stays listed as acknowledged
     * until the condition clears. False when no alert holds {@code id}.
     */
    public boolean pluginAlertAck(long id)       { return h != 0 && nPluginAlertAck(h, id); }

    // ---- overlay pick (tap an AIS target) ----------------------------------
    //
    // A plugin's symbol can carry a pick payload. A tap on one pins a bubble to
    // it; the bubble re-reads the object every frame so it follows the target
    // and closes itself when the target ages out.

    /**
     * The overlay object nearest a point (logical pts), as {id, infoJson}, or
     * null when no symbol carrying a payload is within about 14 pt. Fills
     * {@code outLonLat} (length >= 2) with where the object draws now.
     */
    public String[] overlayHit(float xPts, float yPts, double[] outLonLat) {
        return h == 0 ? null : nOverlayHit(h, xPts, yPts, outLonLat);
    }

    /**
     * What a pinned object says NOW, as {id, infoJson}, or null once it is gone
     * — which is how a pinned bubble learns to close itself.
     */
    public String[] overlayInfo(String id, double[] outLonLat) {
        return h == 0 ? null : nOverlayInfo(h, id, outLonLat);
    }

    /** Geographic -> logical points. Fills {@code out} (length >= 2) as {x, y}. */
    public void geoToScreen(double lon, double lat, float[] out) {
        if (h != 0) nGeoToScreen(h, lon, lat, out);
    }

    private static native String[] nOverlayHit(long h, float xPts, float yPts, double[] outLonLat);
    private static native String[] nOverlayInfo(long h, String id, double[] outLonLat);
    private static native void nGeoToScreen(long h, double lon, double lat, float[] out);

    private static native boolean nPluginsLoad(long h, String dir);
    private static native boolean nPluginsActive(long h);
    private static native int nPluginsConnectionState(long h);
    private static native long nPluginsRead(long h);
    private static native void nPluginsFree(long p);
    private static native int nPluginCount(long p);
    private static native String nPluginText(long p, int i, int field);
    private static native int nPluginInt(long p, int i, int field);
    private static native int nCapCount(long p, int i);
    private static native String nCapText(long p, int i, int c, int field);
    private static native int nCapGranted(long p, int i, int c);
    private static native String[] nCapAllows(long p, int i, int c);
    private static native int nSettingCount(long p, int i);
    private static native int nSettingFieldCount(long p, int i, int s);
    private static native String nSettingText(long p, int i, int s, int fi, int field);
    private static native double nSettingNumber(long p, int i, int s, int fi, int field);
    private static native int nSettingInt(long p, int i, int s, int fi, int field);
    private static native int nItemCount(long p, int i, int s);
    private static native String nItemId(long p, int i, int s, int it);
    private static native String[] nItemValues(long p, int i, int s, int it);
    private static native String[] nServices(long p, int i, int s);
    private static native String[] nServiceSet(long p, int i, int s, int sv);
    private static native String nPluginConfigGet(long h, String id);
    private static native boolean nPluginConfigSet(long h, String id, String json);
    private static native String[] nAlerts(long h);
    private static native boolean nPluginAlertAck(long h, long id);
    // ---- follow mode and own ship ------------------------------------------

    /** Fix states {@link #ownShip} answers. */
    public static final int FIX_NONE = 0;
    public static final int FIX_LOST = 1;
    public static final int FIX_LIVE = 2;

    /** Centre the chart on own ship and keep it there. The engine drops
     *  follow on a pan, so poll {@link #followActive}, never remember a tap. */
    public void followSet(boolean on)            { if (h != 0) nFollowSet(h, on); }
    /** 0 off, 1 following, 2 armed and waiting for a fix. */
    public int followActive()                    { return h == 0 ? 0 : nFollowActive(h); }
    public void courseUpSet(boolean on)          { if (h != 0) nCourseUpSet(h, on); }
    public boolean courseUpActive()              { return h != 0 && nCourseUpActive(h) != 0; }

    /** The reported fix into {@code out} (length >= 2: lon, lat); answers a
     *  FIX_* state. The numbers mean nothing unless it answers FIX_LIVE. */
    public int ownShip(double[] out)             { return h == 0 ? FIX_NONE : nOwnShip(h, out); }

    // ---- raster shown state and the ENC switch -----------------------------

    /** Whether set {@code i} is drawn where it covers. The engine owns the
     *  election; this is read back to SAVE the mariner's choice by set. */
    public boolean rasterShown(int i)            { return h != 0 && nRasterShown(h, i); }
    public void rasterSetShown(int i, boolean on){ if (h != 0) nRasterSetShown(h, i, on); }
    public void setChartHidden(boolean hidden)   { if (h != 0) nSetChartHidden(h, hidden); }
    /** How many survey cells are installed. 0 means no ENC: a raster set saved
     *  hidden must draw anyway, or the sea is blank. */
    public int chartsCount()                     { return h == 0 ? 0 : nChartsCount(h); }

    // ---- markers -----------------------------------------------------------

    /** Drop a mark; the CORE names it ("Mark 1"), so the drop never waits for
     *  typing. Answers the id, 0 refused. */
    public long markerAdd(double lon, double lat){ return h == 0 ? 0 : nMarkerAdd(h, lon, lat); }
    /** The marker's name, or null once it is gone. */
    public String markerName(long id)            { return h == 0 ? null : nMarkerName(h, id); }
    /** The marker within about 14 pt of a LOGICAL point, or 0. Decides the
     *  chart menu's items: over a mark it renames and removes. */
    public long markerAt(float xPts, float yPts) { return h == 0 ? 0 : nMarkerAt(h, xPts, yPts); }
    /** Empty keeps the old name; the core clips at 32 characters. */
    public boolean markerRename(long id, String name) { return h != 0 && nMarkerRename(h, id, name); }
    public boolean markerRemove(long id)         { return h != 0 && nMarkerRemove(h, id); }

    // ---- the chart's own files and the library -----------------------------

    /** A file the chart carries (TXTDSC text, PICREP picture), or null.
     *  {@code mimeOut} (length >= 1, may be null) receives the mime type. */
    public byte[] auxFile(String cell, String name, String[] mimeOut) {
        return h == 0 ? null : nAuxFile(h, cell, name, mimeOut);
    }

    /** Look through a folder or archive for charts; the engine's scan JSON,
     *  or null. NOT REENTRANT — serialize callers — and handle-less: the
     *  scan reads the filesystem, not the open chart. */
    /**
     * What a folder or one .zip holds: the summary, the counts, then twelve
     * strings per file. Null when the path cannot be read. Needs no chart open.
     */
    public static String[] scanRead(String path, boolean zip) { return nScanRead(path, zip); }

    /**
     * The order a bake runs the items in, as indices into what was passed.
     * Coarse band first, sheets after the survey, a lift last.
     */
    public static int[] bakeOrder(String[] names, int[] bands, int[] works) {
        return nBakeOrder(names, bands, works);
    }

    /** Where one prepared chart is written under outDir. Empty when it does
     *  not fit. */
    public static String bakeOutputPath(String outDir, String source, String path,
                                        String name, int band, int work) {
        return nBakeOutputPath(outDir, source, path, name, band, work);
    }

    /** The directory name a source is prepared into, under the charts root.
     *  An archive names it without the .zip. */
    public static String bakePreparedName(String source) { return nBakePreparedName(source); }

    /** True when path is under the directory this app prepares into. What is
     *  outside is the mariner's own and is never touched. */
    public static boolean bakeIsDerived(String root, String path) {
        return nBakeIsDerived(root, path);
    }

    /** What a removal renames to before deleting behind itself. */
    public static String bakeTrashPrefix()        { return nBakeTrashPrefix(); }
    /** The test a launch sweep uses. */
    public static boolean bakeIsTrash(String name) { return nBakeIsTrash(name); }

    // ---- portrayal quick toggles -------------------------------------------

    public void toggleText()                     { if (h != 0) nToggleText(h); }
    public void toggleSoundings()                { if (h != 0) nToggleSoundings(h); }
    public void toggleOtherCategory()            { if (h != 0) nToggleOtherCategory(h); }

    private static native void nFollowSet(long h, boolean on);
    private static native int nFollowActive(long h);
    private static native void nCourseUpSet(long h, boolean on);
    private static native int nCourseUpActive(long h);
    private static native int nOwnShip(long h, double[] out);
    private static native boolean nRasterShown(long h, int i);
    private static native void nRasterSetShown(long h, int i, boolean shown);
    private static native void nSetChartHidden(long h, boolean hidden);
    private static native int nChartsCount(long h);
    private static native long nMarkerAdd(long h, double lon, double lat);
    private static native String nMarkerName(long h, long id);
    private static native long nMarkerAt(long h, float xPts, float yPts);
    private static native boolean nMarkerRename(long h, long id, String name);
    private static native boolean nMarkerRemove(long h, long id);
    private static native byte[] nAuxFile(long h, String cell, String name, String[] mimeOut);
    private static native String[] nScanRead(String path, boolean zip);
    private static native int[] nBakeOrder(String[] names, int[] bands, int[] works);
    private static native String nBakeOutputPath(String outDir, String source, String path,
                                                 String name, int band, int work);
    private static native String nBakePreparedName(String source);
    private static native boolean nBakeIsDerived(String root, String path);
    private static native String nBakeTrashPrefix();
    private static native boolean nBakeIsTrash(String name);
    private static native void nToggleText(long h);
    private static native void nToggleSoundings(long h);
    private static native void nToggleOtherCategory(long h);
    // ---- the bake ----------------------------------------------------------

    /** Start the phased bake (cells, sheets, lift; kind-contiguous lists).
     *  0 when nothing starts. Poll with {@link #bakePoll}; free when done. */
    public static long bakeStart(String source, String[] ins, String[] outs,
                                 int cells, int sheets, int lifts, boolean zip) {
        return nBakeStart(source, ins, outs, cells, sheets, lifts, zip);
    }
    /** True while running; out (length >= 4) gets done, total, baked, ok. */
    public static boolean bakePoll(long job, int[] out) { return nBakePoll(job, out); }
    /** tile57 stops at the next chart boundary, not instantly. */
    public static void bakeCancel(long job) { nBakeCancel(job); }
    /** Joins the worker: cancel a running bake first. */
    public static void bakeFree(long job) { nBakeFree(job); }

    private static native long nBakeStart(String source, String[] ins, String[] outs, int cells, int sheets, int lifts, boolean zip);
    private static native boolean nBakePoll(long job, int[] out);
    private static native void nBakeCancel(long job);
    private static native void nBakeFree(long job);
    // ---- plugin install and consent ----------------------------------------

    /** Name the install root (the app's files dir): before any plugin call. */
    public boolean pluginsInstallRoot(String path) { return h != 0 && nPluginsInstallRoot(h, path); }
    /** Load the set the mariner installed. Call after the bundled load. */
    public boolean pluginsLoadInstalled()        { return h != 0 && nPluginsLoadInstalled(h); }
    /** The consent JSON for a .lkplug, or null when no layer can come up. */
    public String pluginInspect(String path)     { return h == 0 ? null : nPluginInspect(h, path); }
    /** Install a consented .lkplug: null on success, else one sentence why. */
    public String pluginInstall(String path) {
        return h == 0 ? "The plugin layer could not start." : nPluginInstall(h, path);
    }
    public boolean pluginUninstall(String id)    { return h != 0 && nPluginUninstall(h, id); }
    /**
     * Every table the loaded plugins declare: eight strings per table, then
     * three per column. Null when no plugin layer is up.
     */
    public String[] tables()                     { return h == 0 ? null : nTables(h); }

    /**
     * One table's rows, already in order: the seq, then six strings per row and
     * two per cell. Null for an unknown plugin or table.
     */
    public String[] tableRows(String id, String key, String sortKey, boolean ascending) {
        return h == 0 ? null : nTableRows(h, id, key, sortKey, ascending);
    }
    /** Tell the plugin its table is on screen: it builds no rows until then. */
    public boolean pluginTableOpen(String id, String key, boolean open) {
        return h != 0 && nPluginTableOpen(h, id, key, open);
    }

    // ---- charts by link -----------------------------------------------------

    /** Install or remove this shell's url fetcher. lookout drives it for the
     *  style, TileJSON, sprite packs and every tile; see lookout.h. */
    public void httpProvider(boolean on)         { if (h != 0) nHttpProvider(h, on); }
    /** Drain up to ids.length parked asks. allow[i] is 1 when the url may be
     *  read off local disk, 0 when it must not be. */
    public int httpPoll(long[] ids, int[] allow, String[] urls) {
        return h == 0 ? 0 : nHttpPoll(h, ids, allow, urls);
    }
    /** Drain the ids lookout has given up on. Advisory. */
    public int httpCancelPoll(long[] ids)        { return h == 0 ? 0 : nHttpCancelPoll(h, ids); }
    /** Answer one ask, from any thread. status is the final HTTP status, or 0
     *  for a transport failure; only 2xx carries a body. */
    public void httpRespond(long id, byte[] bytes, int status) {
        if (h != 0) nHttpRespond(h, id, bytes, status);
    }
    public void chartLinkAdd(String link)        { if (h != 0) nChartLinkAdd(h, link); }
    /** null draws lookout's own chart. */
    public void chartLinkSelect(String url)      { if (h != 0) nChartLinkSelect(h, url); }
    public void chartLinkRemove(String url)      { if (h != 0) nChartLinkRemove(h, url); }
    public void chartLinkRefresh(String url)     { if (h != 0) nChartLinkRefresh(h, url); }
    /** Everything the chart list shows, as one document. */
    public String chartLinksJson()               { return h == 0 ? null : nChartLinksJson(h); }
    /** 1 since the last poll, then clears. ONE consumer. */
    public boolean chartLinksChanged()           { return h != 0 && nChartLinksChanged(h); }
    /** One-time migration from the shell's old store. */
    public void chartLinksImport(String json)    { if (h != 0) nChartLinksImport(h, json); }
    /** Is a chart link the one being drawn? */
    public boolean altStyleActive()              { return h != 0 && nAltStyleActive(h); }
    /** A live grant flip; a revoked call answers -1 to the running plugin. */
    public boolean pluginGrantSet(String id, String cap, boolean on) {
        return h != 0 && nPluginGrantSet(h, id, cap, on);
    }

    private static native boolean nPluginsInstallRoot(long h, String path);
    private static native boolean nPluginsLoadInstalled(long h);
    private static native String nPluginInspect(long h, String path);
    private static native String nPluginInstall(long h, String path);
    private static native boolean nPluginUninstall(long h, String id);
    private static native boolean nAltStyleActive(long h);
    private static native void nHttpProvider(long h, boolean on);
    private static native int nHttpPoll(long h, long[] ids, int[] allow, String[] urls);
    private static native int nHttpCancelPoll(long h, long[] ids);
    private static native void nHttpRespond(long h, long id, byte[] bytes, int status);
    private static native void nChartLinkAdd(long h, String link);
    private static native void nChartLinkSelect(long h, String url);
    private static native void nChartLinkRemove(long h, String url);
    private static native void nChartLinkRefresh(long h, String url);
    private static native String nChartLinksJson(long h);
    private static native boolean nChartLinksChanged(long h);
    private static native void nChartLinksImport(long h, String json);
    private static native String[] nTables(long h);
    private static native String[] nTableRows(long h, String id, String key, String sortKey, boolean ascending);
    private static native boolean nPluginTableOpen(long h, String id, String key, boolean open);
    private static native boolean nPluginGrantSet(long h, String id, String cap, boolean on);
}
