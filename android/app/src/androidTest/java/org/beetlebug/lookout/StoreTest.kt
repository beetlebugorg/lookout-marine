package org.beetlebug.lookout

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.beetlebug.lookout.charts.RasterCharts
import org.beetlebug.lookout.plugins.PluginPrefs
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.store.Store
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/**
 * What the shell remembers between launches.
 *
 * A chartplotter that reopens on the far side of the world from where it was
 * left, or forgets the gateway typed at the helm, is not one a mariner will
 * trust. Every store here exists to stop one of those.
 *
 * It is `lookout_store`, so this needs the engine loaded. Each test gets a
 * store in a directory of its own and the mariner's own store is put back
 * afterwards.
 */
@RunWith(AndroidJUnit4::class)
class StoreTest {

    private val ctx: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private lateinit var dir: File

    @Before fun openATemporaryStore() {
        dir = File(ctx.cacheDir, "store-" + UUID.randomUUID())
        Store.reopen(dir.absolutePath)
    }

    @After fun putTheMarinersStoreBack() {
        Store.close()
        dir.deleteRecursively()
    }

    // ---- the file ------------------------------------------------------------

    @Test fun aKeyThatWasNeverSetIsNotThere() {
        assertFalse(Store.has(Store.Group.VIEW, "lon"))
        assertNull(Store.text(Store.Group.VIEW, "lon"))
        assertEquals(3.0, Store.number(Store.Group.VIEW, "lon", 3.0), 0.0)
        assertTrue(Store.flag(Store.Group.RASTER, "chart_hidden", true))
    }

    @Test fun everyKindOfValueSurvivesAWriteAndARead() {
        Store.setText(Store.Group.MARINER, "date_view", "20260901")
        Store.setNumber(Store.Group.VIEW, "lon", -76.4767)
        Store.setFlag(Store.Group.RASTER, "chart_hidden", true)
        Store.setList(Store.Group.RASTER, "paths", listOf("/a", "/b"))

        assertEquals("20260901", Store.text(Store.Group.MARINER, "date_view"))
        assertEquals(-76.4767, Store.number(Store.Group.VIEW, "lon"), 1e-12)
        assertTrue(Store.flag(Store.Group.RASTER, "chart_hidden"))
        assertEquals(listOf("/a", "/b"), Store.list(Store.Group.RASTER, "paths"))
    }

    /** A double crosses whole: the pose was Float before this and a degree of
     *  longitude is 111 km. */
    @Test fun aNumberKeepsItsFullPrecision() {
        Store.setNumber(Store.Group.VIEW, "lat", 38.976_312_5)
        assertEquals(38.976_312_5, Store.number(Store.Group.VIEW, "lat"), 0.0)
    }

    /** The file is read again at the next launch, which is the whole point. */
    @Test fun whatWasWrittenIsThereAtTheNextOpen() {
        Store.setNumber(Store.Group.VIEW, "zoom", 14.5)
        Store.setList(Store.Group.CHARTSETS, "paths", listOf("/charts/a"))
        Store.close()

        Store.reopen(dir.absolutePath)
        assertEquals(14.5, Store.number(Store.Group.VIEW, "zoom"), 0.0)
        assertEquals(listOf("/charts/a"), Store.list(Store.Group.CHARTSETS, "paths"))
    }

    /** An empty list clears the key, so a read comes back empty rather than
     *  holding what was there before. */
    @Test fun anEmptyListClearsTheKey() {
        Store.setList(Store.Group.RASTER, "off", listOf("/a"))
        Store.setList(Store.Group.RASTER, "off", emptyList())
        assertTrue(Store.list(Store.Group.RASTER, "off").isEmpty())
    }

    @Test fun aRemovedKeyIsGone() {
        Store.setText(Store.Group.RECENTS, "library", "/charts")
        Store.remove(Store.Group.RECENTS, "library")
        assertFalse(Store.has(Store.Group.RECENTS, "library"))
    }

    /** The keys under a group come back in the order they were written, which
     *  is how the plugin values are read back. */
    @Test fun theKeysOfAGroupComeBackInWriteOrder() {
        Store.setNumber(Store.Group.PLUGINS, "b/one", 1.0)
        Store.setNumber(Store.Group.PLUGINS, "a/two", 2.0)
        assertEquals(listOf("b/one", "a/two"), Store.keys(Store.Group.PLUGINS))
    }

    // ---- the plugin settings the mariner typed ------------------------------

    @Test fun aConnectionListSurvivesTheNextLaunch() {
        val schema = PluginRegistry(PluginFixture.shipped)
            .lists("connections").first { it.key == "connections" }
        val json = """[{"id":"row-1","host":"192.168.1.50","port":10110,"enabled":true}]"""

        assertNull("nothing is saved until the mariner edits it",
            PluginPrefs.savedRows(ctx, schema))
        PluginPrefs.saveRows(ctx, schema, json)
        assertEquals(json, PluginPrefs.savedRows(ctx, schema))
    }

    /** A scalar keeps its full precision: a contour depth of 3.6 m is not 3.6f. */
    @Test fun aScalarSurvivesWithItsFullPrecision() {
        PluginPrefs.saveScalar(ctx, "org.beetlebug.ais", "min_sog", 0.123_456_789)
        assertEquals(
            0.123_456_789,
            PluginPrefs.savedScalars(ctx)["org.beetlebug.ais/min_sog"]!!,
            0.0,
        )
    }

    @Test fun noScalarsSavedIsAnEmptyMap() {
        assertTrue(PluginPrefs.savedScalars(ctx).isEmpty())
    }

    /** A saved row list lives in the same group as the scalars and is not one
     *  of them: reading it as a number would give every list a value of 0. */
    @Test fun aSavedRowListIsNotReadAsAScalar() {
        val schema = PluginRegistry(PluginFixture.shipped)
            .lists("connections").first { it.key == "connections" }
        PluginPrefs.saveRows(ctx, schema, "[]")
        PluginPrefs.saveScalar(ctx, "org.beetlebug.ais", "min_sog", 0.5)
        assertEquals(setOf("org.beetlebug.ais/min_sog"), PluginPrefs.savedScalars(ctx).keys)
    }

    // ---- the mariner's raster charts ----------------------------------------

    @Test fun addingReturnsOnlyWhatWasNew() {
        val r = RasterCharts(ctx)
        assertEquals(listOf("/a", "/b"), r.add(listOf("/a", "/b")))
        assertEquals(listOf("/c"), r.add(listOf("/a", "/c")))
        assertEquals(listOf("/a", "/b", "/c"), r.paths)
    }

    /** "Order added" IS the contract: the list a mariner built is theirs. */
    @Test fun theOrderAddedSurvivesARelaunch() {
        RasterCharts(ctx).add(listOf("/z", "/a", "/m"))
        assertEquals(listOf("/z", "/a", "/m"), RasterCharts(ctx).paths)
    }

    @Test fun switchingAChartOffKeepsIt() {
        val r = RasterCharts(ctx)
        r.add(listOf("/a"))
        r.setEnabled("/a", false)
        assertFalse(r.isEnabled("/a"))
        assertEquals(listOf("/a"), RasterCharts(ctx).paths)
        assertFalse(RasterCharts(ctx).isEnabled("/a"))
    }

    @Test fun forgettingAChartTakesItsSwitchWithIt() {
        val r = RasterCharts(ctx)
        r.add(listOf("/a"))
        r.setEnabled("/a", false)
        r.remove("/a")
        assertTrue(RasterCharts(ctx).paths.isEmpty())
        assertTrue("the switch came back with the chart", RasterCharts(ctx).isEnabled("/a"))
    }

    /** By NAME, not path: an unplugged drive is not a change of mind, so a set
     *  the mariner turned off survives its files being absent for a launch. */
    @Test fun aHiddenSetSurvivesItsFilesBeingAbsent() {
        val r = RasterCharts(ctx)
        r.noteShown(listOf("Navionics" to false, "OpenSeaMap" to true))
        assertEquals(setOf("Navionics"), RasterCharts(ctx).hidden)
        // A launch that sees neither leaves both alone.
        RasterCharts(ctx).noteShown(emptyList())
        assertEquals(setOf("Navionics"), RasterCharts(ctx).hidden)
    }

    @Test fun theEncSwitchIsRemembered() {
        val r = RasterCharts(ctx)
        assertFalse(r.chartHidden)
        r.setChartHidden(true)
        assertTrue(RasterCharts(ctx).chartHidden)
    }
}
