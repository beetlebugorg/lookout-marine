package org.beetlebug.lookout

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
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
 * Charts come from a library chosen in the Charts tab, else anything pushed into
 * the app's external files dir, else the cell baked into the APK assets — see
 * [ChartsModel]. Chosen libraries are opened IN PLACE (by path, mmap'd), never
 * copied; the bundled asset is the one exception, since an APK asset has no path
 * of its own.
 */
class LookoutActivity : ComponentActivity() {
    private var chartView: LookoutView? = null
    private lateinit var controller: ChartController
    private lateinit var charts: ChartsModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Chart under the system bars; the Compose chrome insets itself.
        enableEdgeToEdge()

        // Before any open: without a root the engine re-bakes both atlases on
        // every launch (~1s), having no cache path in the environment.
        Lookout.setCacheDir(cacheDir.absolutePath)

        // The bundled cell is the last resort, extracted once; the model prefers
        // a chosen library, then anything pushed into our external files dir.
        charts = ChartsModel(applicationContext, extractAsset(CHART_ASSET, CHART_NAME))
        if (charts.chartPaths.isEmpty()) {
            Log.e(TAG, "no charts: none chosen, none pushed, asset extraction failed")
            finish()
            return
        }
        controller = ChartController(applicationContext)
        // The plugin set rides in the APK as assets, which have no filesystem
        // path — the host loads a DIRECTORY, so extract it to one first. Done
        // here rather than on the render thread: it is half a megabyte of wasm,
        // and the engine is opened the moment the surface arrives.
        controller.pluginDir = extractPlugins()
        // A dev affordance, not a mariner one: there is no plugin settings pane
        // on Android yet, so the NMEA source has no other way to be addressed.
        //   adb shell am start -n … -e nmea 127.0.0.1:10110
        controller.nmeaAddress = intent?.getStringExtra("nmea")

        setContent {
            // The chrome follows the CHART's scheme, not the system's: a white
            // settings sheet at night would undo the night palette's whole point.
            LookoutTheme(dark = controller.mariner.scheme != Scheme.DAY) {
                ChartScreen(
                    charts = charts,
                    onRequestFileAccess = ::requestFileAccess,
                    controller = controller,
                    onViewCreated = { chartView = it },
                )
            }
        }
    }

    /**
     * The permission has to be granted in system settings (there is no dialog
     * for MANAGE_EXTERNAL_STORAGE), so re-read it whenever we come back.
     */
    override fun onResume() {
        super.onResume()
        if (::charts.isInitialized) charts.refreshAccess()
    }

    /**
     * Ask for read access to the whole shared volume, because charts are opened
     * IN PLACE by path — see the manifest for why a SAF tree can't serve. API 30+
     * routes to the "All files access" settings screen; earlier releases still
     * have a runtime dialog for the legacy read permission.
     */
    private fun requestFileAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val uri = Uri.fromParts("package", packageName, null)
            // The app-specific screen can be missing on some builds; fall back to
            // the global list rather than throwing.
            val intents = listOf(
                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, uri),
                Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
            )
            for (i in intents) {
                if (i.resolveActivity(packageManager) != null) {
                    startActivity(i)
                    return
                }
            }
            Log.w(TAG, "no all-files-access settings screen on this build")
        } else {
            requestPermissions(arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE), REQ_READ)
        }
    }

    // No onRequestPermissionsResult: whichever route was taken — the settings
    // screen or the legacy dialog — the Activity resumes afterwards, and
    // onResume re-reads the permission. One path, not two.

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

    /**
     * Extract assets/plugins into filesDir/plugins and answer its path, or null
     * when the APK ships no plugin set (a build with the host switched off).
     *
     * Copied rather than read in place because the wasm host is handed a
     * DIRECTORY PATH: it lists the `<id>.manifest.json` + `<id>.wasm` pairs and
     * reads them with ordinary file calls, and an APK asset has neither a path
     * nor a listing an outside reader can walk. Length is the freshness test,
     * the same one the chart uses — an upgrade that changes a module changes its
     * size, and the whole set re-extracts in well under a second anyway.
     */
    private fun extractPlugins(): String? {
        val names = try {
            assets.list(PLUGIN_ASSET_DIR)?.takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            Log.e(TAG, "plugin assets: $e")
            null
        } ?: run {
            Log.w(TAG, "no plugin assets in this build")
            return null
        }
        val dir = File(filesDir, PLUGIN_DIR_NAME)
        if (!dir.isDirectory && !dir.mkdirs()) {
            Log.e(TAG, "cannot create $dir")
            return null
        }
        var wrote = 0
        for (n in names) {
            val out = File(dir, n)
            try {
                val len = assets.open("$PLUGIN_ASSET_DIR/$n").use { it.available().toLong() }
                if (out.length() == len && len > 0L) continue
                assets.open("$PLUGIN_ASSET_DIR/$n").use { input ->
                    FileOutputStream(out).use { output -> input.copyTo(output) }
                }
                wrote++
            } catch (e: Exception) {
                Log.e(TAG, "plugin extract $n: $e")
            }
        }
        val modules = names.count { it.endsWith(".wasm") }
        Log.i(TAG, "plugins: $modules module(s) in $dir ($wrote file(s) written this launch)")
        return dir.absolutePath
    }

    private companion object {
        const val TAG = "lookout"
        const val CHART_ASSET = "charts/US5MD1MC.pmtiles"
        const val CHART_NAME = "US5MD1MC.pmtiles"
        const val PLUGIN_ASSET_DIR = "plugins"
        const val PLUGIN_DIR_NAME = "plugins"
        const val REQ_READ = 1
    }
}
