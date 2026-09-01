package org.beetlebug.lookout.charts

import org.beetlebug.lookout.engine.LookoutView
import org.beetlebug.lookout.store.Store

import android.content.Context
import android.os.Build
import android.os.Environment
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * A chart library: a directory holding baked cells, opened in place.
 *
 * `cells` is every *.pmtiles under [dir], recursively — `bake_tree` mirrors the
 * ENC tree (REGION/CELL.pmtiles), so a library is nested, not flat. The whole
 * set goes to the engine at once, which composes it and picks the owner per tile
 * from its band/tier partition. Nothing here names `partition.tpart`: tile57
 * discovers the bake's sidecar by walking up from the archives, which is exactly
 * why charts are opened by path rather than copied in.
 */
data class Library(val dir: File, val cells: List<String>) {
    val name: String get() = dir.name
    val path: String get() = dir.absolutePath
}

/**
 * Which charts are open, and the picking of them — the Android answer to iOS's
 * document-picker import, minus the import: a 3 GB library is pointed at, never
 * copied.
 *
 * The list is the CORE's ([ChartSets]). A folder the mariner added is a SET,
 * and the chart is the union of the sets switched on, so two agencies' charts
 * draw as one. Only the paths and the switches are saved: a folder changes
 * underneath the app.
 *
 * [chartPaths] is what [LookoutView] opens, and it falls back — the union,
 * then anything pushed into the app's own external files dir (no permission
 * needed, see the adb recipe in [LookoutActivity]), then the cell bundled in
 * the APK — so the app always has something to draw.
 */
class ChartsModel(private val appContext: Context, private val bundled: String?) {

    /** The installed sets, in the order added. Re-read when the core's
     *  background scan lands. */
    var sets by mutableStateOf<List<ChartSets.Set>>(emptyList())
        private set

    /** Set while a directory scan is running (a big tree takes a moment). */
    var scanning by mutableStateOf(false)
        private set

    /** Last scan that found no cells, for the UI to explain itself. */
    var lastEmptyPick by mutableStateOf<String?>(null)

    /** Bumped on every selection change: what the chart view keys itself on. */
    var generation by mutableStateOf(0)
        private set

    /**
     * Whether the OS will let us read chart dirs outside our own sandbox.
     * State, not a query, so the UI recomposes when the user comes back from the
     * system settings screen ([refreshAccess] on resume).
     */
    var storageAccess by mutableStateOf(false)
        private set

    /** The import pipeline: scan, bake what is raw, open the result. */
    val importer = ChartImport(appContext)

    /** Volume roots a folder browser starts from (computed once). */
    val roots: List<File> by lazy { storageRoots(appContext) }

    init {
        refreshAccess()
        ChartBake.sweepTrash(appContext)
        ChartSets.open(ChartBake.chartsRoot(appContext).absolutePath)
        pullSets()
        seedFromTheChosenLibrary()
    }

    /**
     * The one library a mariner chose before there was a list becomes their
     * first set. Without it their charts are simply gone at the next launch,
     * with the folder still on disk and the app on the first-run page.
     *
     * Once, and only into an empty list: a mariner who then removed that set
     * must not have it back at the next launch.
     */
    private fun seedFromTheChosenLibrary() {
        val saved = Store.text(Store.Group.RECENTS, KEY_SELECTED) ?: return
        Store.remove(Store.Group.RECENTS, KEY_SELECTED)
        if (sets.isNotEmpty()) return
        // Not filtered: the core's scan decides what is a chart, so a folder
        // that was never one drops out on its own.
        ChartSets.add(saved)
        pullSets()
        Log.i(TAG, "the chosen library is now a set: $saved")
    }

    /** Re-read the storage permission (call from the Activity's onResume). */
    fun refreshAccess() {
        storageAccess = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            appContext.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    /**
     * The cells to open, in fallback order. Never empty unless the APK asset
     * failed to extract too, which [LookoutActivity] treats as fatal.
     */
    val chartPaths: Array<String>
        get() {
            val want = composed.takeIf { it.isNotEmpty() }
                ?: pushed
                ?: return bundled?.let { arrayOf(it) } ?: emptyArray()
            // Held, not rebuilt. This is read from composition, and a real
            // library is seven thousand cells: returning a fresh Array on
            // every read copied all of them each time the loader recomposed.
            pathsCache?.let { if (it.first === want) return it.second }
            val array = want.toTypedArray()
            pathsCache = want to array
            return array
        }

    private fun cells(n: Int) = if (n == 1) "1 cell" else "$n cells"

    /** The union of the switched-on sets, held between changes for the same
     *  reason [chartPaths] is. */
    private var composed: List<String> = emptyList()

    private var pathsCache: Pair<List<String>, Array<String>>? = null

    /** A label for the HUD/settings: what's actually open right now. */
    val activeLabel: String
        get() {
            val on = sets.filter { it.on }
            if (composed.isNotEmpty()) {
                val cells = cells(composed.size)
                return if (on.size == 1) "${on[0].title} ($cells)" else "${on.size} sets ($cells)"
            }
            pushed?.let { return "pushed (${cells(it.size)})" }
            return "bundled demo cell"
        }

    /**
     * Put [dir] on the list. Rejects a folder the core found no charts in
     * (surfaced via [lastEmptyPick]) rather than listing a set that opens
     * nothing, since the usual mistake is picking the ENC source tree.
     */
    suspend fun add(dir: File): Boolean {
        scanning = true
        try {
            // Off the main thread: a full ENC library is thousands of files.
            val found = withContext(Dispatchers.IO) {
                ChartScanRead.read(dir.absolutePath, zip = isArchive(dir))
            }
            val charts = found?.files.orEmpty().count { it.kind != ChartScanRead.OTHER }
            if (charts == 0) {
                lastEmptyPick = dir.absolutePath
                Log.w(TAG, "no charts under $dir")
                return false
            }
            ChartSets.add(dir.absolutePath)
            lastEmptyPick = null
            pullSets()
            Log.i(TAG, "set added: ${dir.absolutePath} ($charts charts)")
            return true
        } finally {
            scanning = false
        }
    }

    /** The switch. A set switched off stays installed and leaves the chart. */
    fun setOn(path: String, on: Boolean) {
        if (ChartSets.setOn(path, on)) pullSets()
    }

    /**
     * Take a set off the list, and delete what this app prepared from it. The
     * mariner's own files are never touched: ChartBake refuses any path it did
     * not make.
     */
    fun remove(path: String) {
        if (!ChartSets.remove(path)) return
        ChartBake.deletePrepared(appContext, File(path))
        pullSets()
    }

    /**
     * Re-read the list and the union. Called after every change the shell made,
     * and from the frame loop when the core's background scan lands.
     */
    fun pullSets() {
        sets = ChartSets.all()
        composed = ChartSets.compose()
        generation++
    }

    /** True when the core's background scan has landed since the last look. */
    fun scanLanded(): Boolean = ChartSets.changed()

    /** One .zip is a set, as a chart agency publishes them. */
    private fun isArchive(dir: File): Boolean =
        dir.isFile && dir.name.endsWith(".zip", ignoreCase = true)

    /**
     * Charts pushed into the app's own external files dir, or null if none.
     * Walked ONCE and remembered: [chartPaths] and [activeLabel] are read from
     * composition, and a tree walk per recomposition would be a main-thread
     * filesystem hit on every frame the settings sheet animates.
     */
    private val pushed: List<String>? by lazy {
        val dir = File(appContext.getExternalFilesDir(null) ?: return@lazy null, PUSH_DIR)
        if (!dir.isDirectory && !dir.mkdirs()) return@lazy null
        cellsUnder(dir).ifEmpty { null }
    }

    private companion object {
        const val TAG = "lookout"
        const val KEY_SELECTED = "library"
        /** Push target under the app's external files dir. */
        const val PUSH_DIR = "charts"
    }
}

/**
 * Every baked cell under [dir], sorted. Unreadable subtrees are logged and
 * skipped rather than aborting the walk — a shared volume always has a few
 * directories we can't enter. Symlinks ARE followed (walkTopDown offers no
 * choice), so a looping tree would spin; no chart bake produces one.
 */
fun cellsUnder(dir: File): List<String> =
    dir.walkTopDown()
        .onFail { f, e -> Log.w("lookout", "skip $f: $e") }
        .filter { it.isFile && it.extension == "pmtiles" }
        .map { it.absolutePath }
        .sorted()
        .toList()

/** Where a folder browser starts: the shared volume, not our sandbox. */
fun storageRoots(ctx: Context): List<File> {
    val roots = mutableListOf<File>()
    @Suppress("DEPRECATION")
    Environment.getExternalStorageDirectory()?.let { if (it.isDirectory) roots.add(it) }
    // Removable volumes: the app-scoped dirs are the only ones handed to us by
    // path, so walk up to the volume root, which all-files access can read.
    ctx.getExternalFilesDirs(null).filterNotNull().forEach { d ->
        var p: File? = d
        repeat(4) { p = p?.parentFile } // <vol>/Android/data/<pkg>/files -> <vol>
        p?.let { if (it.isDirectory && roots.none { r -> r.path == it.path }) roots.add(it) }
    }
    return roots
}
