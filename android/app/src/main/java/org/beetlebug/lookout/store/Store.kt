package org.beetlebug.lookout.store

import android.content.Context
import android.util.Log
import org.beetlebug.lookout.Lookout
import java.io.File

/**
 * The one place the shell reads and writes its settings.
 *
 * Everything kept across launches goes through here: the camera pose, the
 * mariner settings, the plugin values and rows, the chart links, the chart sets
 * and the raster charts. It is `lookout_store`, so all four shells keep the
 * same settings in the same file format under the same key names, and the core
 * can read what the shell wrote.
 *
 * A key lives in a GROUP. The group names are the core's, so a shell cannot
 * invent a name the others do not know.
 *
 * A store that will not open leaves every read on its fallback and every write
 * a no-op: a settings file that cannot be opened must not stop the chart coming
 * up.
 */
object Store {

    /** The core's group names. */
    object Group {
        const val VIEW = "view"
        const val RECENTS = "recents"
        const val RASTER = "raster"
        const val MARINER = "mariner.v1"
        const val PLUGINS = "plugins.v1"
        const val CHARTLINKS = "chartlinks"
        const val CHARTSETS = "chartsets"
    }

    /**
     * The core's store, for lookout_set_store. 0 until [open], and 0 again when
     * the core could not open one.
     */
    @Volatile var handle: Long = 0
        private set

    /**
     * Open the store under the app's own files directory. Idempotent: the
     * Activity may be made more than once over a process that kept running.
     */
    fun open(ctx: Context) {
        if (handle != 0L) return
        val dir = File(ctx.filesDir, "settings").absolutePath
        handle = Lookout.storeOpen(dir)
        if (handle == 0L) Log.w(TAG, "store: could not open $dir")
        else StoreImport.once(ctx)
    }

    /** Point the store somewhere else. For a test, which puts it back. */
    fun reopen(dir: String) {
        close()
        handle = Lookout.storeOpen(dir)
    }

    fun close() {
        Lookout.storeClose(handle)
        handle = 0
    }

    /** Write anything waiting now, whatever the coalesce window says. */
    fun flush() = Lookout.storeFlush(handle)

    // ---- reading ------------------------------------------------------------

    fun has(group: String, key: String): Boolean = Lookout.storeHas(handle, group, key)

    /** Null when the key is not set, which is not an empty value. */
    fun text(group: String, key: String): String? = Lookout.storeText(handle, group, key)

    fun number(group: String, key: String, fallback: Double = 0.0): Double =
        Lookout.storeNumber(handle, group, key, fallback)

    fun flag(group: String, key: String, fallback: Boolean = false): Boolean =
        Lookout.storeFlag(handle, group, key, fallback)

    fun list(group: String, key: String): List<String> =
        Lookout.storeList(handle, group, key).toList()

    /** The keys set under a group, in the order they were written. */
    fun keys(group: String): List<String> = Lookout.storeKeys(handle, group).toList()

    // ---- writing ------------------------------------------------------------

    fun setText(group: String, key: String, value: String) =
        Lookout.storeSetText(handle, group, key, value)

    fun setNumber(group: String, key: String, value: Double) =
        Lookout.storeSetNumber(handle, group, key, value)

    fun setFlag(group: String, key: String, value: Boolean) =
        Lookout.storeSetFlag(handle, group, key, value)

    /** An empty list clears the key. */
    fun setList(group: String, key: String, items: List<String>) =
        Lookout.storeSetList(handle, group, key, items.toTypedArray())

    fun remove(group: String, key: String) = Lookout.storeRemove(handle, group, key)

    private const val TAG = "lookout"
}
