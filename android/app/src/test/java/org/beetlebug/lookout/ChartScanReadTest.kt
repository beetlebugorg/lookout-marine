package org.beetlebug.lookout

import org.beetlebug.lookout.charts.ChartScanRead

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a scan says, as the shell walks it.
 *
 * THE CORE DOES THE LOOKING. Which files are charts, what each one is and what
 * band it belongs to is decided in Zig and checked there. What this pins is the
 * walk: the summary, the two runs of files, and a read that came back short.
 */
class ChartScanReadTest {

    private fun file(
        path: String,
        name: String,
        kind: Int,
        band: Int = 0,
        bandName: String = "",
        bytes: Long = 0,
        scale: Double = 0.0,
        located: Boolean = false,
        west: Double = 0.0,
        south: Double = 0.0,
        east: Double = 0.0,
        north: Double = 0.0,
    ): List<String> = listOf(
        path, name, kind.toString(), band.toString(), bandName, bytes.toString(),
        scale.toString(), if (located) "1" else "0",
        west.toString(), south.toString(), east.toString(), north.toString(),
    )

    private fun read(
        cells: List<List<String>>,
        raster: List<List<String>> = emptyList(),
        updates: Int = 0,
        other: Int = 0,
        refused: Int = 0,
        sources: Int = 0,
        bytes: Long = 0,
        producer: String = "",
        root: String = "/charts",
    ): Array<String> = (
        listOf(
            root, updates.toString(), other.toString(), refused.toString(),
            sources.toString(), bytes.toString(), producer,
            cells.size.toString(), raster.size.toString(),
        ) + cells.flatMap { it } + raster.flatMap { it }
        ).toTypedArray()

    private val scan = ChartScanRead.decode(read(
        cells = listOf(
            file("/charts/US5MD1MC.000", "US5MD1MC", ChartScanRead.SOURCE,
                band = 5, bandName = "Harbor", bytes = 412_000, scale = 20_000.0,
                located = true, west = -76.6, south = 38.9, east = -76.4, north = 39.0),
            file("/charts/US3CU1EF.pmtiles", "US3CU1EF", ChartScanRead.BAKED, band = 3),
        ),
        raster = listOf(file("/charts/photo.mbtiles", "photo", ChartScanRead.RASTER)),
        updates = 2129, other = 7, refused = 1, sources = 12,
        bytes = 900_000, producer = "US",
    ))!!

    @Test fun theSummaryIsRead() {
        assertEquals("/charts", scan.root)
        assertEquals(2129, scan.updates)
        assertEquals(7, scan.other)
        assertEquals(1, scan.refused)
        assertEquals(12, scan.sources)
        assertEquals(900_000L, scan.bytes)
        assertEquals("US", scan.producer)
    }

    /** The cells come first and the pictures after, in one list: a picture
     *  belongs to the raster chart list and a cell to the chart. */
    @Test fun theCellsComeBeforeThePictures() {
        assertEquals(listOf("US5MD1MC", "US3CU1EF", "photo"), scan.files.map { it.name })
        assertEquals(ChartScanRead.RASTER, scan.files.last().kind)
    }

    @Test fun everyFieldOfAFileIsRead() {
        val cell = scan.files.first()
        assertEquals("/charts/US5MD1MC.000", cell.path)
        assertEquals(ChartScanRead.SOURCE, cell.kind)
        assertEquals(5, cell.band)
        assertEquals("Harbor", cell.bandName)
        assertEquals(412_000L, cell.bytes)
        assertEquals(20_000.0, cell.scale, 0.0)
        assertEquals(-76.6, cell.west!!, 1e-9)
        assertEquals(39.0, cell.north!!, 1e-9)
    }

    /** An archive that states no coverage has no edges, which is not four
     *  zeroes: a chart at 0°N 0°E is in the Gulf of Guinea. */
    @Test fun aFileStatingNoCoverageHasNoEdges() {
        val baked = scan.files[1]
        assertNull(baked.west)
        assertNull(baked.north)
    }

    @Test fun aPathThatCouldNotBeReadIsNull() {
        assertNull(ChartScanRead.decode(null))
        assertNull(ChartScanRead.decode(emptyArray()))
    }

    /** An empty folder is a read with no files, which is a real answer. */
    @Test fun anEmptyFolderIsAReadWithNoFiles() {
        val empty = ChartScanRead.decode(read(cells = emptyList()))!!
        assertTrue(empty.files.isEmpty())
        assertEquals("/charts", empty.root)
    }

    /** A file cut short is dropped rather than read with the wrong fields. */
    @Test fun aTruncatedFileIsDropped() {
        val flat = read(cells = listOf(file("/a", "A", ChartScanRead.BAKED)))
        assertTrue(ChartScanRead.decode(flat.copyOfRange(0, 15))!!.files.isEmpty())
    }
}
