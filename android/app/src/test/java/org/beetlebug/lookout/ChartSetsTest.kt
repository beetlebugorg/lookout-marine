package org.beetlebug.lookout

import org.beetlebug.lookout.charts.ChartSets

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The installed sets, as the shell walks them.
 *
 * THE CORE HOLDS THE LIST. Which folders are on it, what each holds and what
 * the union is are decided in Zig and checked there. What this pins is the
 * walk: a set with its counts, a set the scan has not reached yet, and a read
 * that came back short.
 */
class ChartSetsTest {

    private fun set(
        path: String,
        title: String,
        producer: String = "",
        on: Boolean = true,
        scanned: Boolean = true,
        charts: Int = 0,
        pictures: Int = 0,
        unprepared: Int = 0,
        bytes: Long = 0,
        bandLo: Int = 0,
        bandHi: Int = 0,
        managed: Boolean = false,
        heldBack: Int = 0,
        toPrepare: Int = 0,
        refused: Int = 0,
        bandCount: List<Int> = List(6) { 0 },
    ): List<String> = listOf(
        path, title, producer,
        if (on) "1" else "0", if (scanned) "1" else "0",
        charts.toString(), pictures.toString(), unprepared.toString(),
        bytes.toString(), bandLo.toString(), bandHi.toString(),
        if (managed) "1" else "0", heldBack.toString(),
        toPrepare.toString(), refused.toString(),
    ) + bandCount.map { it.toString() }

    private fun read(vararg sets: List<String>): Array<String> =
        sets.flatMap { it }.toTypedArray()

    private val list = ChartSets.decode(read(
        set("/charts/NOAA", "NOAA", producer = "US", charts = 7224,
            bytes = 3_100_000_000L, bandLo = 1, bandHi = 6, managed = true),
        set("/charts/local", "local", on = false, charts = 412, bandLo = 5, bandHi = 5),
        set("/charts/new", "new", scanned = false),
    ))

    @Test fun everySetIsReadInTheOrderAdded() {
        assertEquals(listOf("NOAA", "local", "new"), list.map { it.title })
        assertEquals(listOf("/charts/NOAA", "/charts/local", "/charts/new"), list.map { it.path })
    }

    @Test fun everyFieldOfASetIsRead() {
        val noaa = list[0]
        assertEquals("US", noaa.producer)
        assertTrue(noaa.on)
        assertTrue(noaa.scanned)
        assertEquals(7224, noaa.charts)
        assertEquals(3_100_000_000L, noaa.bytes)
        assertEquals(1, noaa.bandLo)
        assertEquals(6, noaa.bandHi)
        assertTrue(noaa.managed)
        assertEquals(0, noaa.heldBack)
    }

    @Test fun managedAndHeldBackAreRead() {
        val both = ChartSets.decode(read(
            set("/charts/mine", "mine", charts = 40, bandLo = 4, bandHi = 5, heldBack = 12),
            set("/charts/NOAA", "NOAA", managed = true),
        ))
        assertEquals(2, both.size)
        assertFalse(both[0].managed)
        assertEquals(12, both[0].heldBack)
        assertEquals(5, both[0].bandHi)
        assertTrue(both[1].managed)
        assertEquals("/charts/NOAA", both[1].path)
    }

    @Test fun theBandCountsAndWorkLeftAreRead() {
        val one = ChartSets.decode(read(
            set("/charts/mine", "mine", unprepared = 9, toPrepare = 7, refused = 2,
                bandCount = listOf(1, 2, 0, 0, 3, 1)),
            set("/charts/NOAA", "NOAA", managed = true),
        ))
        assertEquals(2, one.size)
        assertEquals(7, one[0].toPrepare)
        assertEquals(2, one[0].refused)
        assertEquals(listOf(1, 2, 0, 0, 3, 1), one[0].bandCount)
        assertTrue(one[1].managed)
    }

    /** A set switched off stays on the list. Removing is the other control. */
    @Test fun aSetSwitchedOffIsStillInstalled() {
        val local = list[1]
        assertFalse(local.on)
        assertEquals(412, local.charts)
    }

    /**
     * Every count is 0 until the background scan has read the folder, so the
     * panel has to know the difference between "none" and "not yet". Saying
     * "0 charts" of a set that has thousands is worse than saying nothing.
     */
    @Test fun anUnscannedSetSaysSoRatherThanReportingNone() {
        val fresh = list[2]
        assertFalse(fresh.scanned)
        assertEquals(0, fresh.charts)
    }

    /** The folder name, for the line under the title. */
    @Test fun theNameIsTheLastPathComponent() {
        assertEquals("NOAA", list[0].name)
        assertEquals("local", list[1].name)
    }

    @Test fun aReadThatSaidNothingIsNoSets() {
        assertTrue(ChartSets.decode(null).isEmpty())
        assertTrue(ChartSets.decode(emptyArray()).isEmpty())
    }

    /** A set cut short is dropped rather than read with the wrong fields. */
    @Test fun aTruncatedSetIsDropped() {
        assertTrue(ChartSets.decode(read(set("/a", "A")).copyOfRange(0, 8)).isEmpty())
    }
}
