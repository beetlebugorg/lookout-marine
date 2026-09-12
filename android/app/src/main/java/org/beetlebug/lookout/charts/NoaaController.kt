package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.engine.EngineAccess

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * NOAA's charts: the catalog, the regions and the download.
 *
 * THE CORE OWNS ALL OF THIS. It reads NOAA's product catalog, turns a pick
 * into the cells that cover that water, and fetches them through the shell's
 * own fetcher. This holds what the screen reads and asks for changes.
 *
 * Every call into the engine goes through the render thread, and a call that
 * wants an answer waits for the next [poll] rather than reaching across. That
 * is why picking a region does not price it here: it marks the price stale and
 * the next tick works it out with a live handle.
 */
class NoaaController(private val access: EngineAccess) {

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

    // What the next tick has to do with a live handle.
    @Volatile private var wantRefresh = false
    @Volatile private var wantCost = false
    @Volatile private var wantCoverage = false
    @Volatile private var wantHave: Array<String>? = null
    @Volatile private var order: Triple<String, String, Boolean>? = null
    @Volatile private var wantCancel = false

    private val pollBuf = LongArray(8)
    private val costBuf = LongArray(4)

    /** Read NOAA's catalog. The result arrives through [poll]. */
    fun refresh() {
        error = null
        wantRefresh = true
        access.wake()
    }

    fun toggle(id: String) {
        picked = if (picked.contains(id)) picked - id else picked + id
        wantCost = true
        access.wake()
    }

    /** The picked ids as the core reads them. */
    val pickedIds: String get() = regions.filter { picked.contains(it.id) }.joinToString(",") { it.id }

    /**
     * Name the cells this device already holds, so a pick prices what is
     * missing from the water rather than all of it.
     */
    fun noteInstalled(names: List<String>) {
        wantHave = names.toTypedArray()
        wantCost = true
        access.wake()
    }

    /**
     * Fetch the picked water into [destDir]. `again` fetches the cells already
     * held too, which is how a mariner repairs or refreshes a set.
     */
    fun download(destDir: String, again: Boolean) {
        val ids = pickedIds
        if (ids.isEmpty()) return
        error = null
        order = Triple(ids, destDir, again)
        access.wake()
    }

    /** Stop the download. What arrived stays. */
    fun cancel() {
        wantCancel = true
        access.wake()
    }

    /**
     * Take the core's state, and run whatever the screen asked for while no
     * handle was to hand. RENDER THREAD, off the readout tick.
     */
    fun poll(l: Lookout) {
        wantHave?.let { names ->
            wantHave = null
            l.noaaHave(names)
        }
        if (wantCancel) {
            wantCancel = false
            l.noaaCancel()
        }
        order?.let { (ids, dest, again) ->
            order = null
            l.noaaDownload(ids, dest, again)
        }
        if (wantRefresh) {
            wantRefresh = false
            l.noaaRefresh()
        }

        val have = l.noaaPoll(pollBuf)
        val gained = have && !haveCatalog
        if (gained) wantCoverage = true

        val nextPhase = when (pollBuf[0].toInt()) {
            1 -> Phase.READING_CATALOG
            2 -> Phase.READY
            3 -> Phase.DOWNLOADING
            else -> Phase.IDLE
        }
        val nextDate = if (have) l.noaaDate() else ""
        val nextError = l.noaaError().ifEmpty { null }
        val nCells = pollBuf[2].toInt()
        val nTotal = pollBuf[3].toInt()
        val nDone = pollBuf[4].toInt()
        val nFailed = pollBuf[5].toInt()
        val nBytesTotal = pollBuf[6]
        val nBytesDone = pollBuf[7]

        if (gained || wantCost) {
            wantCost = false
            readCost(l)
        }
        val boxes = if (wantCoverage && have) readCoverage(l) else null
        if (boxes != null) wantCoverage = false

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
            if (boxes != null) coverage = boxes
        }
    }

    /** RENDER THREAD. Publishes through [access]. */
    private fun readCost(l: Lookout) {
        val ids = pickedIds
        if (ids.isEmpty() || !l.noaaCost(ids, costBuf)) {
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
     * while the catalog is loaded, so this runs once. RENDER THREAD.
     */
    private fun readCoverage(l: Lookout): Map<String, List<Box>> {
        val out = HashMap<String, List<Box>>(regions.size)
        var buf = DoubleArray(256 * 4)
        for (r in regions) {
            var n = l.noaaRegionCoverage(r.id, buf)
            if (n * 4 > buf.size) {
                buf = DoubleArray(n * 4)
                n = l.noaaRegionCoverage(r.id, buf)
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
