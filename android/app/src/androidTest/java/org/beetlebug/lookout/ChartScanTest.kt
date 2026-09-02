package org.beetlebug.lookout

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.beetlebug.lookout.charts.ChartScanRead
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * The scan and the bake plan, against the real engine.
 *
 * The walk itself is checked on the JVM from a built array. This is the half a
 * built array cannot check: that the natives hand the engine what it expects
 * and hand back what it said.
 */
@RunWith(AndroidJUnit4::class)
class ChartScanTest {

    private val dir: File by lazy {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        File(ctx.cacheDir, "scan-test").apply { deleteRecursively(); mkdirs() }
    }

    /**
     * A path that is not a directory is taken as one file, because the open
     * panel takes one archive as readily as a folder of them. A path that is
     * not there is then one file that is not a chart.
     */
    @Test fun aPathThatIsNotThereReadsAsOneFileThatIsNotAChart() {
        val scan = ChartScanRead.read("/no/such/folder", zip = false)!!
        assertTrue(scan.files.isEmpty())
        assertEquals(1, scan.other)
    }

    /** An empty folder is a read with no files, and the root it was given. */
    @Test fun anEmptyFolderReadsAsAScanWithNoCharts() {
        val scan = ChartScanRead.read(dir.absolutePath, zip = false)
        assertTrue("the folder did not read", scan != null)
        assertTrue(scan!!.files.isEmpty())
    }

    /** A file that is not a chart is counted and never listed as one. */
    @Test fun aFileThatIsNotAChartIsCountedAsOther() {
        File(dir, "readme.txt").writeText("not a chart")
        val scan = ChartScanRead.read(dir.absolutePath, zip = false)!!
        assertTrue("a text file was listed as a chart", scan.files.none { it.name == "readme" })
        assertTrue("it was not counted", scan.other >= 1)
    }

    // ---- the order --------------------------------------------------------

    /**
     * Coarse band first, sheets after the survey, a lift last. A mariner who
     * cancels half way then has charts covering the whole passage at a usable
     * scale.
     */
    @Test fun theOrderIsCoarseBandFirstThenSheetsThenLifts() {
        val names = arrayOf("US5MD1MC", "US3CU1EF", "photo", "already", "US4TE3W0")
        val bands = intArrayOf(5, 3, 0, 0, 4)
        val works = intArrayOf(CELL, CELL, SHEET, LIFT, CELL)
        val order = Lookout.bakeOrder(names, bands, works)
        assertEquals(
            listOf("US3CU1EF", "US4TE3W0", "US5MD1MC", "photo", "already"),
            order.map { names[it] },
        )
    }

    @Test fun orderingNothingIsNothing() {
        assertEquals(0, Lookout.bakeOrder(emptyArray(), IntArray(0), IntArray(0)).size)
    }

    // ---- where a prepared chart lands -------------------------------------

    /**
     * Every prepared chart goes in a directory of its own name. The raster
     * layer reads a provider from the directory ABOVE, so a folder of 900
     * sheets written flat becomes 900 switches.
     */
    @Test fun aPreparedCellGoesInADirectoryOfItsOwnName() {
        val out = Lookout.bakeOutputPath(
            "/out", "/src", "/src/US5MD1MC.000", "US5MD1MC.000", 5, CELL,
        )
        assertEquals("/out/US5MD1MC/US5MD1MC.pmtiles", out)
    }

    /** A lift keeps the name the file already has: an .mbtiles is a chart. */
    @Test fun aLiftKeepsItsOwnName() {
        val out = Lookout.bakeOutputPath(
            "/out", "/src", "/src/photo.mbtiles", "photo.mbtiles", 0, LIFT,
        )
        assertTrue("a lift was renamed: $out", out.endsWith("photo.mbtiles"))
    }

    private companion object {
        // lookout_prepare
        const val CELL = 0
        const val SHEET = 1
        const val LIFT = 2
    }
}
