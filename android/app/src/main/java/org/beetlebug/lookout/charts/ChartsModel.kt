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
 * Selection is a plain absolute path in prefs, so it survives a relaunch and
 * needs no permission of its own to remember (reading it back does; see
 * [storageAccess]). [chartPaths] is what [LookoutView] opens, and it falls
 * back — chosen library, then anything pushed into the app's own external files
 * dir (no permission needed, see the adb recipe in [LookoutActivity]), then the
 * cell bundled in the APK — so the app always has something to draw.
 */
class ChartsModel(private val appContext: Context, private val bundled: String?) {

    /** The chosen library, or null when falling back. */
    var selected by mutableStateOf<Library?>(null)
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
        val saved = Store.text(Store.Group.RECENTS, KEY_SELECTED)
        if (saved != null) {
            // Synchronous, on the main thread, before the first frame: the first
            // open needs its paths immediately (surfaceChanged follows onCreate),
            // and restoring the library is the whole point of having saved it.
            // Walking a 7k-cell tree costs a few hundred ms of launch, once.
            val dir = File(saved)
            val t = System.currentTimeMillis()
            if (dir.isDirectory) selected = scan(dir)
            if (selected == null) {
                Log.w(TAG, "saved library gone or unreadable: $saved")
            } else {
                Log.i(TAG, "library $saved: ${selected?.cells?.size} cells in ${System.currentTimeMillis() - t} ms")
            }
        }
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
            val want = selected?.cells?.takeIf { it.isNotEmpty() }
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

    private var pathsCache: Pair<List<String>, Array<String>>? = null

    /** A label for the HUD/settings: what's actually open right now. */
    val activeLabel: String
        get() {
            selected?.let { if (it.cells.isNotEmpty()) return "${it.name} (${it.cells.size} cells)" }
            pushed?.let { return "pushed (${it.size} cells)" }
            return "bundled demo cell"
        }

    /**
     * Adopt [dir] as the library. Rejects a directory with no cells under it
     * (surfaced via [lastEmptyPick]) rather than blanking the chart, since the
     * usual mistake is picking the ENC source tree — *.000 files, not a bake.
     */
    suspend fun select(dir: File): Boolean {
        scanning = true
        try {
            // Off the main thread: a full ENC library is thousands of files.
            val lib = withContext(Dispatchers.IO) { scan(dir) }
            if (lib == null || lib.cells.isEmpty()) {
                lastEmptyPick = dir.absolutePath
                Log.w(TAG, "no *.pmtiles under $dir — not a baked library?")
                return false
            }
            selected = lib
            lastEmptyPick = null
            Store.setText(Store.Group.RECENTS, KEY_SELECTED, lib.path)
            generation++
            Log.i(TAG, "library -> ${lib.path} (${lib.cells.size} cells)")
            return true
        } finally {
            scanning = false
        }
    }

    /** Back to the fallback chain (pushed charts, else the bundled cell). */
    fun clearSelection() {
        selected = null
        lastEmptyPick = null
        Store.remove(Store.Group.RECENTS, KEY_SELECTED)
        generation++
    }

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

    private fun scan(dir: File): Library? {
        if (!dir.isDirectory || !dir.canRead()) return null
        return Library(dir, cellsUnder(dir))
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
