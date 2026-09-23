package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.engine.EngineAccess

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.concurrent.Executors

/**
 * NOAA's charts: the catalog, the regions and the download.
 *
 * THE CORE OWNS ALL OF THIS. It reads NOAA's product catalog, turns a pick
 * into the cells that cover that water, and fetches them through
 * [NoaaFetch]. This holds what the screen reads and passes on what the
 * mariner does.
 *
 * The service has a handle of its own, [NoaaService], so no call here waits
 * for a chart handle. Every call runs on one worker thread, because adopting
 * a catalog parses a few megabytes of XML. After each call, and on each wake
 * from the fetcher, the worker reads the state only when the core reports it
 * changed.
 */
class NoaaController(
    private val access: EngineAccess,
    private val noaa: Long = NoaaService.handle,
) {

    /** One region a mariner picks from: a Coast Guard district. */
    data class Region(
        val id: String,
        val name: String,
        val blurb: String,
        val west: Double,
        val south: Double,
        val east: Double,
        val north: Double,
    )

    /** One box of a region's coverage, in degrees. */
    data class Box(val west: Double, val south: Double, val east: Double, val north: Double)

    enum class Phase { IDLE, READING_CATALOG, READY, DOWNLOADING }

    /** The region table. Static for the life of the process. */
    val regions: List<Region> = readRegions()

    var phase by mutableStateOf(Phase.IDLE)
        private set
    var haveCatalog by mutableStateOf(false)
        private set
    /** NOAA's validity date for the loaded catalog, "20250903". */
    var date by mutableStateOf("")
        private set
    var catalogCells by mutableStateOf(0)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    /** The download. */
    var total by mutableStateOf(0)
        private set
    var done by mutableStateOf(0)
        private set
    var failed by mutableStateOf(0)
        private set
    var bytesTotal by mutableStateOf(0L)
        private set
    var bytesDone by mutableStateOf(0L)
        private set
    /** One of the OUTCOME_ values, for the download numbered [run]. */
    var outcome by mutableStateOf(OUTCOME_NONE)
        private set
    /** Counts the downloads ordered, from 1. 0 before the first. */
    var run by mutableStateOf(0L)
        private set

    /** The core's prepare of what a download fetched. The counts by band are
     *  band 1 first. */
    var preparing by mutableStateOf(false)
        private set
    var prepared by mutableStateOf(0)
        private set
    var toPrepare by mutableStateOf(0)
        private set
    var bandTotal by mutableStateOf(List(6) { 0 })
        private set

    /** What the pick costs. */
    var cells by mutableStateOf(0)
        private set
    var bytes by mutableStateOf(0L)
        private set
    /** Cells of the picked water already on this device. */
    var held by mutableStateOf(0)
        private set
    var heldBytes by mutableStateOf(0L)
        private set

    /** The regions the mariner has picked. */
    var picked by mutableStateOf<Set<String>>(emptySet())
        private set

    /** Each region's real coverage, read once the catalog is in. */
    var coverage by mutableStateOf<Map<String, List<Box>>>(emptyMap())
        private set

    /** True while every picked cell is already installed. Downloading then
     *  fetches them again, which is how a mariner repairs a set. */
    val allInstalled: Boolean get() = held > 0 && cells == 0

    private val worker = Executors.newSingleThreadExecutor { Thread(it, "lookout-noaa") }
    private val pollBuf = LongArray(25)
    private val costBuf = LongArray(4)
    /** Whether the last state read had a catalog. Worker only. */
    private var hadCatalog = false

    init {
        if (noaa != 0L) {
            NoaaService.onWake = { worker.execute { pull() } }
            worker.execute { pull(force = true) }
        }
    }

    /** Run [block] on the worker, then read what changed. */
    private fun call(block: () -> Unit) {
        if (noaa == 0L) return
        worker.execute {
            block()
            pull()
        }
    }

    /** Read NOAA's catalog. The result arrives through the next change. */
    fun refresh() {
        error = null
        call { Lookout.noaaRefresh(noaa) }
    }

    fun toggle(id: String) {
        picked = if (picked.contains(id)) picked - id else picked + id
        call { readCost() }
    }

    /** The picked ids as the core reads them. */
    val pickedIds: String get() = regions.filter { picked.contains(it.id) }.joinToString(",") { it.id }

    /**
     * Price the pick again. The core reads the cells this device holds off
     * the chart sets, so a pick prices what is missing from the water.
     */
    fun reprice() {
        call { readCost() }
    }

    /**
     * Fetch the picked water into [destDir]. `again` fetches the cells already
     * held too, which is how a mariner repairs or refreshes a set.
     */
    fun download(destDir: String, again: Boolean) {
        val ids = pickedIds
        if (ids.isEmpty()) return
        error = null
        call { Lookout.noaaDownload(noaa, ids, destDir, again) }
    }

    /**
     * Tick the regions the core records as downloaded, and pass them to
     * [onDone] on the main thread. The picker opens with these, so unticking
     * one reads as giving it back.
     */
    fun pickRecorded(onDone: (Set<String>) -> Unit) {
        call {
            val buf = LongArray(6)
            val rec = regions.filter { Lookout.noaaRegionState(noaa, it.id, buf) && buf[5] != 0L }
            val ids = rec.map { it.id }.toSet()
            readCost(rec.joinToString(",") { it.id })
            access.onMain {
                picked = ids
                onDone(ids)
            }
        }
    }

    /**
     * Make the download at [destDir] hold the picked water: the core deletes
     * the water given back and fetches what is missing. [onDone] gets how
     * many directories left the library, on the main thread.
     */
    fun apply(destDir: String, onDone: (Int) -> Unit) {
        val ids = pickedIds
        error = null
        call {
            val moved = Lookout.noaaApply(noaa, ids, destDir, false)
            access.onMain { onDone(moved) }
        }
    }

    /** Stop the download and the core's prepare. What arrived stays. */
    fun cancel() {
        call { Lookout.noaaCancel(noaa) }
    }

    /**
     * Take the core's state when it changed, and publish it. WORKER THREAD.
     * [force] reads it regardless, for the first read.
     */
    private fun pull(force: Boolean = false) {
        if (!Lookout.noaaChanged(noaa) && !force) return
        val have = Lookout.noaaPoll(noaa, pollBuf)
        val gained = have && !hadCatalog
        hadCatalog = have

        val nextPhase = when (pollBuf[0].toInt()) {
            1 -> Phase.READING_CATALOG
            2 -> Phase.READY
            3 -> Phase.DOWNLOADING
            else -> Phase.IDLE
        }
        val text = Lookout.noaaText(noaa)
        val nextDate = if (have) text.getOrNull(0) ?: "" else ""
        val nextError = text.getOrNull(1)?.ifEmpty { null }
        val nCells = pollBuf[2].toInt()
        val nTotal = pollBuf[3].toInt()
        val nDone = pollBuf[4].toInt()
        val nFailed = pollBuf[5].toInt()
        val nBytesTotal = pollBuf[6]
        val nBytesDone = pollBuf[7]
        val nOutcome = pollBuf[8].toInt()
        val nRun = pollBuf[9]
        val nPreparing = pollBuf[10] != 0L
        val nPrepared = pollBuf[11].toInt()
        val nToPrepare = pollBuf[12].toInt()
        val nBandTotal = List(6) { pollBuf[19 + it].toInt() }

        if (gained) readCost()
        val boxes = if (gained) readCoverage() else null

        access.onMain {
            phase = nextPhase
            haveCatalog = have
            date = nextDate
            error = nextError
            catalogCells = nCells
            total = nTotal
            done = nDone
            failed = nFailed
            bytesTotal = nBytesTotal
            bytesDone = nBytesDone
            outcome = nOutcome
            run = nRun
            preparing = nPreparing
            prepared = nPrepared
            toPrepare = nToPrepare
            bandTotal = nBandTotal
            if (boxes != null) coverage = boxes
        }
    }

    /** WORKER THREAD. Publishes through [access]. */
    private fun readCost(ids: String = pickedIds) {
        if (ids.isEmpty() || !Lookout.noaaCost(noaa, ids, costBuf)) {
            access.onMain {
                cells = 0; bytes = 0; held = 0; heldBytes = 0
            }
            return
        }
        val c = costBuf[0].toInt()
        val b = costBuf[1]
        val hc = costBuf[2].toInt()
        val hb = costBuf[3]
        access.onMain {
            cells = c; bytes = b; held = hc; heldBytes = hb
        }
    }

    /**
     * Every region's coverage. The catalog holds it and it does not change
     * while the catalog is loaded, so this runs once. WORKER THREAD.
     */
    private fun readCoverage(): Map<String, List<Box>> {
        val out = HashMap<String, List<Box>>(regions.size)
        var buf = DoubleArray(256 * 4)
        for (r in regions) {
            var n = Lookout.noaaRegionCoverage(noaa, r.id, buf)
            if (n * 4 > buf.size) {
                buf = DoubleArray(n * 4)
                n = Lookout.noaaRegionCoverage(noaa, r.id, buf)
            }
            val boxes = ArrayList<Box>(n)
            for (i in 0 until minOf(n, buf.size / 4)) {
                boxes.add(Box(buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2], buf[i * 4 + 3]))
            }
            out[r.id] = boxes
        }
        return out
    }

    private fun readRegions(): List<Region> {
        val flat = try {
            Lookout.noaaRegions()
        } catch (e: UnsatisfiedLinkError) {
            return emptyList()
        }
        val out = ArrayList<Region>(flat.size / 4)
        var i = 0
        while (i + 3 < flat.size) {
            val extent = flat[i + 3].split(",").mapNotNull { it.toDoubleOrNull() }
            if (extent.size == 4) {
                out.add(Region(flat[i], flat[i + 1], flat[i + 2],
                               extent[0], extent[1], extent[2], extent[3]))
            }
            i += 4
        }
        return out
    }

    companion object {
        /** [outcome]: how the download numbered [run] ended. */
        const val OUTCOME_NONE = 0
        const val OUTCOME_RUNNING = 1
        const val OUTCOME_FINISHED = 2
        const val OUTCOME_EMPTY = 3
        const val OUTCOME_CANCELLED = 4
        const val OUTCOME_FAILED = 5

        /**
         * A size a mariner reads before agreeing to download it.
         *
         * A thousand to the megabyte, not 1024. It is what the Apple shells
         * print for the same download, and naming one region two sizes on two
         * devices reads as two different downloads.
         */
        fun sizeText(bytes: Long): String {
            val mb = bytes.toDouble() / 1_000_000.0
            return if (mb >= 1000) String.format("%.1f GB", mb / 1000.0)
                   else String.format("%.1f MB", mb)
        }
    }
}
