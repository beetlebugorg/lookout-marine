package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.store.Store

/**
 * The installed charts, and which of them are drawn.
 *
 * A SET is a folder the mariner added, or one .zip, which is how a chart agency
 * publishes them. Either way it carries every chart inside, however deep: a
 * bake mirrors the exchange set's tree, so a library is nested rather than
 * flat.
 *
 * The list answers two questions a file picker cannot. What is installed, and
 * what am I sailing on right now. Switching a set off keeps it installed and
 * takes it out of the chart; the chart is the UNION of the sets switched on.
 *
 * The CORE does the looking and holds the list (lookout_chart_sets). It walks
 * each folder on a background worker, one at a time, names every file and asks
 * tile57 what each archive holds. Only the paths and the switches are saved:
 * a folder changes underneath the app, so the cells are found again at launch.
 */
object ChartSets {

    /** One row of the list. */
    data class Set(
        /** The folder or archive. Also the identity. */
        val path: String,
        /** The agency when the charts agree on one, else the folder name. */
        val title: String,
        /** The two-letter producer code, empty when the charts disagree. */
        val producer: String,
        val on: Boolean,
        /** True once the background scan has read this folder. Every count
         *  below is 0 until then. */
        val scanned: Boolean,
        val charts: Int,
        val pictures: Int,
        /** Files that bake before they draw. */
        val unprepared: Int,
        val bytes: Long,
        /** The coarsest and finest usage bands present, 1 to 6. 0 when the set
         *  holds no cell with a band in its name. */
        val bandLo: Int,
        val bandHi: Int,
    ) {
        val name: String get() = path.substringAfterLast('/').ifEmpty { path }
    }

    @Volatile private var handle: Long = 0

    /**
     * Open the list off the shell's store and start the background scans.
     * [preparedRoot] is where a bake writes: each set is scanned there as well
     * as at its own path, and a prepared chart WINS over the file it was made
     * from, so a folder scanned after an import does not ask to be imported
     * again.
     */
    fun open(preparedRoot: String) {
        if (handle != 0L) return
        handle = Lookout.chartSetsOpen(Store.handle, preparedRoot)
    }

    /** Point the list at a fresh store. For a test, which closes it after. */
    fun reopen(preparedRoot: String) {
        close()
        handle = Lookout.chartSetsOpen(Store.handle, preparedRoot)
    }

    fun close() {
        Lookout.chartSetsClose(handle)
        handle = 0
    }

    /** True since the last poll, then clears. A background scan landing raises
     *  it, and that is the only change the sets announce on their own. */
    fun changed(): Boolean = Lookout.chartSetsChanged(handle)

    /** The list, in the order added. */
    fun all(): List<Set> = decode(Lookout.chartSetsAll(handle))

    /** Every file one set holds, as the background scan found it. A bake reads
     *  this rather than walking the folder again. */
    fun files(path: String): List<ChartScanRead.ChartFile> =
        ChartScanRead.decodeFiles(Lookout.chartSetFiles(handle, path))

    /** 1 when it joined, 0 when it was already on the list. */
    fun add(path: String): Boolean = Lookout.chartSetsAdd(handle, path)

    /** Take a folder off the list. This deletes nothing: what a bake produced
     *  is the shell's to remove. */
    fun remove(path: String): Boolean = Lookout.chartSetsRemove(handle, path)

    fun setOn(path: String, on: Boolean): Boolean = Lookout.chartSetsSetOn(handle, path, on)

    fun isOn(path: String): Boolean = Lookout.chartSetsIsOn(handle, path)

    /** Every chart the switched-on sets hold, sorted and deduplicated: the
     *  union, the list the engine opens. */
    fun compose(): List<String> = Lookout.chartSetsCompose(handle).toList()

    /**
     * The flat read: eleven strings per set. `internal` so the suite drives the
     * same walk with no core.
     */
    internal fun decode(flat: Array<String>?): List<Set> {
        if (flat == null) return emptyList()
        val out = ArrayList<Set>(flat.size / FIELDS)
        var k = 0
        while (k + FIELDS <= flat.size) {
            out.add(
                Set(
                    path = flat[k],
                    title = flat[k + 1],
                    producer = flat[k + 2],
                    on = flat[k + 3] != "0",
                    scanned = flat[k + 4] != "0",
                    charts = flat[k + 5].toIntOrNull() ?: 0,
                    pictures = flat[k + 6].toIntOrNull() ?: 0,
                    unprepared = flat[k + 7].toIntOrNull() ?: 0,
                    bytes = flat[k + 8].toLongOrNull() ?: 0L,
                    bandLo = flat[k + 9].toIntOrNull() ?: 0,
                    bandHi = flat[k + 10].toIntOrNull() ?: 0,
                ),
            )
            k += FIELDS
        }
        return out
    }

    private const val FIELDS = 11
}
