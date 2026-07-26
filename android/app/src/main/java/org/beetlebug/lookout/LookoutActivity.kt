package org.beetlebug.lookout

import android.os.Bundle
import android.util.Log
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import java.io.File
import java.io.FileOutputStream

/**
 * The app: a ComponentActivity hosting the chart plus its Compose chrome — the
 * Java/Kotlin shell owns the Activity, the Surface and all gestures, while the
 * Zig core renders the chart into that Surface via Vulkan. The exact Android
 * analogue of the iOS app's SwiftUI shell around the Metal core.
 *
 * The chart itself is deliberately NOT Compose: it stays a SurfaceView
 * ([LookoutView]) hosted in an AndroidView, so the render thread presents
 * straight to the Surface with no composition in the path. Compose draws only
 * the HUD, the controls and the settings sheet — the analogue of HUDOverlay
 * and SettingsView sitting over the Metal layer.
 *
 * Charts come from one of two places (see [resolveChart]): a chart pushed into
 * the app's external files dir, else the one baked into the APK assets, copied
 * to internal storage once (tile57 opens charts by path / mmap, which can't read
 * an APK asset directly).
 */
class LookoutActivity : ComponentActivity() {
    private var chartView: LookoutView? = null
    private lateinit var controller: ChartController

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Chart under the system bars; the Compose chrome insets itself.
        enableEdgeToEdge()

        val chart = resolveChart()
        if (chart == null) {
            Log.e(TAG, "no chart: nothing pushed, and asset extraction failed")
            finish()
            return
        }
        controller = ChartController(applicationContext)

        setContent {
            // The chrome follows the CHART's scheme, not the system's: a white
            // settings sheet at night would undo the night palette's whole point.
            LookoutTheme(dark = controller.mariner.scheme != Scheme.DAY) {
                ChartScreen(
                    chartPath = chart,
                    controller = controller,
                    onViewCreated = { chartView = it },
                )
            }
        }
    }

    /** Hand the engine's reclaimable caches back under memory pressure. */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // Every level, rather than a threshold: the call is advisory (the
        // engine trims at its next safe point), and the TRIM_MEMORY_* constants
        // are all deprecated as of API 35. Can also fire before onCreate
        // finishes, or after the early-out above.
        if (::controller.isInitialized) controller.memoryWarning()
    }

    /**
     * Scroll-wheel fallback: when the pointer isn't hover-focused on the
     * SurfaceView, ACTION_SCROLL lands here instead of the view.
     */
    override fun onGenericMotionEvent(e: MotionEvent): Boolean =
        chartView?.handleScroll(e) == true || super.onGenericMotionEvent(e)

    /**
     * The chart to open: a pushed one if there is one, else the baked-in demo
     * cell. Pushed charts win so a chart can be swapped without rebuilding the
     * APK — bake on the host, then, with no permissions and no root:
     *
     *     adb push tiles/ /sdcard/Android/data/org.beetlebug.lookout/files/charts/
     *
     * The engine opens ONE chart per handle, so of several pushed cells the
     * first by path wins; the Charts tab (not built yet) is where picking among
     * them belongs, and composing them needs a lookout_open_charts binding.
     */
    private fun resolveChart(): String? = pushedChart() ?: extractAsset(CHART_ASSET, CHART_NAME)

    /**
     * The first *.pmtiles under `<externalFilesDir>/charts`, or null. Searched
     * recursively: `tile57 bake_tree` mirrors the ENC tree (REGION/CELL.pmtiles),
     * so a pushed library is nested, not flat. The directory is created here so
     * that a first run leaves an obvious target to push into.
     */
    private fun pushedChart(): String? {
        val dir = File(getExternalFilesDir(null) ?: return null, CHART_DIR)
        if (!dir.isDirectory && !dir.mkdirs()) {
            Log.w(TAG, "could not create $dir")
            return null
        }
        val charts = dir.walkTopDown()
            .filter { it.isFile && it.extension == "pmtiles" }
            .sortedBy { it.path }
            .toList()
        if (charts.isEmpty()) {
            Log.i(TAG, "no pushed charts in $dir; using the bundled chart")
            return null
        }
        val chart = charts.first()
        Log.i(TAG, "pushed chart -> $chart (${chart.length()} bytes)" +
            if (charts.size > 1) ", ${charts.size - 1} other(s) ignored" else "")
        return chart.absolutePath
    }

    /** Copy an APK asset to internal storage (skipped when already current). */
    private fun extractAsset(asset: String, outName: String): String? {
        val out = File(filesDir, outName)
        return try {
            val assetLen = assets.open(asset).use { it.available().toLong() }
            if (out.length() != assetLen || assetLen == 0L) {
                assets.open(asset).use { input ->
                    FileOutputStream(out).use { output -> input.copyTo(output) }
                }
                Log.i(TAG, "chart extracted -> $out (${out.length()} bytes)")
            }
            out.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "asset extract: $e")
            null
        }
    }

    private companion object {
        const val TAG = "lookout"
        const val CHART_ASSET = "charts/US5MD1MC.pmtiles"
        const val CHART_NAME = "US5MD1MC.pmtiles"
        /** Push target, under the app's external files dir. */
        const val CHART_DIR = "charts"
    }
}
