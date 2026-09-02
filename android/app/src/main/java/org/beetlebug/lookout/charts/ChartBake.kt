package org.beetlebug.lookout.charts

import android.content.Context
import android.util.Log
import org.beetlebug.lookout.Lookout
import java.io.File
import java.util.UUID

/**
 * Where this app puts what it prepared, and how it takes it away again.
 *
 * THE PATHS ARE THE CORE'S (lookout_bake_prepared_name and
 * lookout_bake_is_derived). Four shells had four copies of them, and the layout
 * has teeth in it: the raster layer reads a provider from the directory above a
 * sheet, so a folder of 900 sheets written flat becomes 900 switches.
 */
object ChartBake {

    /** Under the app's own external files dir, so a mariner can reach it with
     *  adb and it goes with the app when the app goes. */
    fun chartsRoot(ctx: Context): File =
        File(ctx.getExternalFilesDir(null) ?: ctx.filesDir, "Charts")

    fun rasterRoot(ctx: Context): File =
        File(ctx.getExternalFilesDir(null) ?: ctx.filesDir, "Rasters")

    /**
     * Where charts prepared from [source] live, whether or not any have been.
     * One directory per source folder, named after it. The source folder is
     * never written to: it may be a read-only card or a drive that goes away.
     */
    fun preparedDirectory(ctx: Context, source: File, raster: Boolean = false): File {
        val name = Lookout.bakePreparedName(source.absolutePath)
            .ifEmpty { source.nameWithoutExtension.ifEmpty { source.name } }
        return File(if (raster) rasterRoot(ctx) else chartsRoot(ctx), name)
    }

    /** True when this app prepared the charts at [path]. */
    fun isDerived(ctx: Context, path: String): Boolean =
        Lookout.bakeIsDerived(chartsRoot(ctx).absolutePath, path) ||
            Lookout.bakeIsDerived(rasterRoot(ctx).absolutePath, path)

    /**
     * Delete charts this app prepared from [source]. Refuses any path it did
     * not make, so a mariner's own folder is never deleted by removing a set.
     *
     * Rename first, delete behind. A 7,224-chart library is 36,000 files, and
     * removing a set runs on the main thread; the rename is one step, so the
     * charts are gone from where anything looks for them before this returns,
     * and a set added straight back writes into a fresh directory rather than
     * racing the delete.
     */
    fun deletePrepared(ctx: Context, source: File) {
        for (raster in listOf(false, true)) {
            val dir = preparedDirectory(ctx, source, raster)
            if (!dir.exists() || !isDerived(ctx, dir.absolutePath)) continue
            val root = if (raster) rasterRoot(ctx) else chartsRoot(ctx)
            val trash = File(root, Lookout.bakeTrashPrefix() + UUID.randomUUID())
            if (dir.renameTo(trash)) {
                Thread { trash.deleteRecursively() }.start()
            } else {
                Thread { dir.deleteRecursively() }.start()
            }
            Log.i(TAG, "removed what was prepared from ${source.name}")
        }
    }

    /**
     * Finish a removal the process died in the middle of. One pass at launch:
     * a rename that landed leaves a directory nothing will ever look at again.
     */
    fun sweepTrash(ctx: Context) {
        for (root in listOf(chartsRoot(ctx), rasterRoot(ctx))) {
            val left = root.listFiles()?.filter { Lookout.bakeIsTrash(it.name) } ?: continue
            if (left.isEmpty()) continue
            Thread { left.forEach { it.deleteRecursively() } }.start()
        }
    }

    private const val TAG = "lookout"
}
