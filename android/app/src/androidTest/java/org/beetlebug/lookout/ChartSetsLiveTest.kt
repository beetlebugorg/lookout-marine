package org.beetlebug.lookout

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.beetlebug.lookout.charts.ChartSets
import org.beetlebug.lookout.store.Store
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/**
 * The installed sets, against the real engine.
 *
 * The walk itself is checked on the JVM from a built array. This is the half a
 * built array cannot check: that a folder added is scanned, saved, composed
 * into the union, and still there at the next launch.
 */
@RunWith(AndroidJUnit4::class)
class ChartSetsLiveTest {

    private val ctx: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private lateinit var dir: File
    private lateinit var charts: File

    @Before fun openATemporaryStore() {
        dir = File(ctx.cacheDir, "sets-" + UUID.randomUUID()).apply { mkdirs() }
        charts = File(dir, "charts").apply { mkdirs() }
        Store.reopen(File(dir, "settings").absolutePath)
        ChartSets.reopen(File(dir, "prepared").absolutePath)
    }

    @After fun putTheMarinersStoreBack() {
        ChartSets.close()
        Store.close()
        dir.deleteRecursively()
    }

    @Test fun nothingAddedIsNoSets() {
        assertTrue(ChartSets.all().isEmpty())
        assertTrue(ChartSets.compose().isEmpty())
    }

    @Test fun addingAFolderPutsItOnTheList() {
        assertTrue(ChartSets.add(charts.absolutePath))
        assertEquals(listOf(charts.absolutePath), ChartSets.all().map { it.path })
    }

    /** The path is the identity, so the same folder twice is one row. */
    @Test fun addingTheSameFolderTwiceIsOneSet() {
        ChartSets.add(charts.absolutePath)
        assertFalse(ChartSets.add(charts.absolutePath))
        assertEquals(1, ChartSets.all().size)
    }

    /** A set switched off keeps its place on the list and leaves the chart. */
    @Test fun switchingASetOffKeepsItInstalled() {
        ChartSets.add(charts.absolutePath)
        assertTrue(ChartSets.setOn(charts.absolutePath, false))
        assertFalse(ChartSets.isOn(charts.absolutePath))
        assertEquals(1, ChartSets.all().size)
        assertFalse(ChartSets.all().single().on)

        assertTrue(ChartSets.setOn(charts.absolutePath, true))
        assertTrue(ChartSets.isOn(charts.absolutePath))
    }

    /** Setting the switch to what it already is changes nothing, which is what
     *  keeps the panel from reopening the chart on every recomposition. */
    @Test fun settingTheSwitchToWhatItIsChangesNothing() {
        ChartSets.add(charts.absolutePath)
        assertFalse(ChartSets.setOn(charts.absolutePath, true))
    }

    @Test fun removingTakesItOffTheList() {
        ChartSets.add(charts.absolutePath)
        assertTrue(ChartSets.remove(charts.absolutePath))
        assertTrue(ChartSets.all().isEmpty())
        assertFalse("removing what is not there changes nothing",
            ChartSets.remove(charts.absolutePath))
    }

    /**
     * The paths and the switches are saved; the CELLS are not, because a folder
     * changes underneath the app and a stored cell list would offer charts that
     * are no longer there.
     */
    @Test fun theListSurvivesTheNextLaunch() {
        ChartSets.add(charts.absolutePath)
        ChartSets.setOn(charts.absolutePath, false)
        ChartSets.close()
        Store.flush()

        ChartSets.reopen(File(dir, "prepared").absolutePath)
        val back = ChartSets.all().single()
        assertEquals(charts.absolutePath, back.path)
        assertFalse("the switch came back with the set", back.on)
    }

    /**
     * A folder that answered nothing STAYS LISTED: a drive that is not plugged
     * in is not a folder the mariner threw away.
     */
    @Test fun aFolderThatIsNotThereStaysOnTheList() {
        val gone = File(dir, "unplugged").absolutePath
        assertTrue(ChartSets.add(gone))
        assertEquals(listOf(gone), ChartSets.all().map { it.path })
    }

    /** A switched-off set holds no charts for the union to compose. */
    @Test fun theUnionHoldsOnlyWhatIsSwitchedOn() {
        ChartSets.add(charts.absolutePath)
        ChartSets.setOn(charts.absolutePath, false)
        assertTrue(ChartSets.compose().isEmpty())
    }
}
