package org.beetlebug.lookout

import org.beetlebug.lookout.charts.RasterCharts
import org.beetlebug.lookout.plugins.PluginPrefs
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.settings.DisplayCategory
import org.beetlebug.lookout.settings.MI
import org.beetlebug.lookout.settings.MarinerState
import org.beetlebug.lookout.settings.Scheme
import org.beetlebug.lookout.store.ViewState

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * What the shell remembers between launches.
 *
 * A chartplotter that reopens on the far side of the world from where it was
 * left, or forgets the gateway typed at the helm, is not one a mariner will
 * trust. Every store here exists to stop one of those.
 */
@RunWith(RobolectricTestRunner::class)
class StoresTest {

    private val ctx: Context get() = ApplicationProvider.getApplicationContext()

    // ---- the camera pose ----------------------------------------------------

    @Test fun nothingSavedIsNoView() {
        assertNull(ViewState.load(ctx))
    }

    @Test fun theViewComesBackWhereItWasLeft() {
        ViewState.save(ctx, lon = -76.4767, lat = 38.9763, zoom = 14.5, rotationDeg = 37.0)
        val v = requireNotNull(ViewState.load(ctx))
        // Stored as Float, which still resolves a degree to about a metre.
        assertEquals(-76.4767, v.lon, 1e-4)
        assertEquals(38.9763, v.lat, 1e-4)
        assertEquals(14.5, v.zoom, 1e-4)
        assertEquals(37.0, v.rotationDeg, 1e-4)
    }

    // ---- the mariner's display settings -------------------------------------

    @Test fun anEditBumpsTheCounterAndALoadDoesNot() {
        val m = MarinerState()
        assertEquals(0, m.edits)

        m.safetyContour = 10.0
        assertEquals(1, m.edits)

        // A load is the engine telling us its state. Counting it as an edit
        // would write the settings file on every launch and echo the load
        // straight back at the engine.
        m.loadFrom(DoubleArray(Lookout.MARINER_LEN), "")
        assertEquals(1, m.edits)
    }

    @Test fun settingAFieldToWhatItAlreadyIsIsNotAnEdit() {
        val m = MarinerState()
        m.safetyContour = 10.0
        val after = m.edits
        m.safetyContour = 10.0
        assertEquals(after, m.edits)
    }

    /**
     * Base is contained in Standard is contained in Other (S-52 §10.2). The
     * engine stores three independent flags; the mariner gets one choice.
     */
    @Test fun theDisplayCategoriesNest() {
        val m = MarinerState()

        m.displayCategory = DisplayCategory.BASE
        assertTrue(m.flag(MI.DISPLAY_BASE))
        assertFalse(m.flag(MI.DISPLAY_STANDARD))
        assertFalse(m.flag(MI.DISPLAY_OTHER))
        assertEquals(DisplayCategory.BASE, m.displayCategory)

        m.displayCategory = DisplayCategory.STANDARD
        assertTrue(m.flag(MI.DISPLAY_BASE))
        assertTrue(m.flag(MI.DISPLAY_STANDARD))
        assertFalse(m.flag(MI.DISPLAY_OTHER))
        assertEquals(DisplayCategory.STANDARD, m.displayCategory)

        m.displayCategory = DisplayCategory.OTHER
        assertTrue(m.flag(MI.DISPLAY_BASE))
        assertTrue(m.flag(MI.DISPLAY_STANDARD))
        assertTrue(m.flag(MI.DISPLAY_OTHER))
        assertEquals(DisplayCategory.OTHER, m.displayCategory)
    }

    /** An ordinal the engine has that this build does not clamps rather than
     *  throwing: a newer core must not crash an older shell. */
    @Test fun anOrdinalPastTheEnumClampsIntoRange() {
        val m = MarinerState()
        m.setNum(MI.SCHEME, 99.0)
        assertEquals(Scheme.NIGHT, m.scheme)
        m.setNum(MI.SCHEME, -1.0)
        assertEquals(Scheme.DAY, m.scheme)
    }

    @Test fun theSettingsComeBackAcrossALaunch() {
        val saved = DoubleArray(Lookout.MARINER_LEN)
        saved[MI.SCHEME] = Scheme.NIGHT.ordinal.toDouble()
        saved[MI.SAFETY_CONTOUR] = 7.5
        saved[MI.SIZE_SCALE] = 1.25
        MarinerState.save(ctx, saved, "20260401")

        // The overlay lands on the ENGINE's defaults, so anything unsaved keeps
        // whatever the engine chose.
        val fromEngine = DoubleArray(Lookout.MARINER_LEN) { 3.0 }
        val date = MarinerState.applySavedOverlay(ctx, fromEngine)

        assertEquals("20260401", date)
        assertEquals(Scheme.NIGHT.ordinal.toDouble(), fromEngine[MI.SCHEME], 0.0)
        assertEquals(7.5, fromEngine[MI.SAFETY_CONTOUR], 1e-4)
        assertEquals(1.25, fromEngine[MI.SIZE_SCALE], 1e-4)
    }

    /** A key never written leaves the engine's own default alone, so a setting
     *  added in a later release is not zeroed by an older store. */
    @Test fun anUnsavedFieldKeepsTheEnginesDefault() {
        val fromEngine = DoubleArray(Lookout.MARINER_LEN) { 3.0 }
        assertNull(MarinerState.applySavedOverlay(ctx, fromEngine))
        assertTrue(fromEngine.all { it == 3.0 })
    }

    /**
     * A zero size multiplier means "unset", not "invisible". Obeying a stored
     * zero would draw a chart with no symbols on it.
     */
    @Test fun aZeroSizeMultiplierIsIgnoredRatherThanObeyed() {
        val zeroed = DoubleArray(Lookout.MARINER_LEN)
        zeroed[MI.SIZE_SCALE] = 0.0
        zeroed[MI.TEXT_SIZE_SCALE] = 0.0
        zeroed[MI.SOUNDING_SIZE_SCALE] = 0.0
        MarinerState.save(ctx, zeroed, "")

        val fromEngine = DoubleArray(Lookout.MARINER_LEN) { 1.0 }
        MarinerState.applySavedOverlay(ctx, fromEngine)
        assertEquals(1.0, fromEngine[MI.SIZE_SCALE], 0.0)
        assertEquals(1.0, fromEngine[MI.TEXT_SIZE_SCALE], 0.0)
        assertEquals(1.0, fromEngine[MI.SOUNDING_SIZE_SCALE], 0.0)
    }

    // ---- the plugin settings the mariner typed ------------------------------

    @Test fun aConnectionListSurvivesTheNextLaunch() {
        val schema = PluginRegistry.parse(Fixtures.registry)
            .lists("connections").first { it.key == "connections" }
        val json = """[{"id":"row-1","host":"192.168.1.50","port":10110,"enabled":true}]"""

        assertNull("nothing is saved until the mariner edits it",
            PluginPrefs.savedRows(ctx, schema))
        PluginPrefs.saveRows(ctx, schema, json)
        assertEquals(json, PluginPrefs.savedRows(ctx, schema))
    }

    /** Toggles ride as 1 and 0; the live schema decides the JSON shape at
     *  restore. Stored as raw double bits, because preferences have no double. */
    @Test fun aScalarSurvivesWithItsFullPrecision() {
        PluginPrefs.saveScalar(ctx, "org.beetlebug.ais", "cpa_limit", 926.0)
        PluginPrefs.saveScalar(ctx, "org.beetlebug.ais", "cpa_alarm", 1.0)
        PluginPrefs.saveScalar(ctx, "org.beetlebug.ais", "min_sog", 0.1)

        val all = PluginPrefs.savedScalars(ctx)
        assertEquals(926.0, all["org.beetlebug.ais/cpa_limit"]!!, 0.0)
        assertEquals(1.0, all["org.beetlebug.ais/cpa_alarm"]!!, 0.0)
        assertEquals("0.1 is not representable as a float", 0.1, all["org.beetlebug.ais/min_sog"]!!, 0.0)
    }

    @Test fun noScalarsSavedIsAnEmptyMap() {
        assertTrue(PluginPrefs.savedScalars(ctx).isEmpty())
    }

    // ---- the mariner's raster charts ----------------------------------------

    @Test fun addingReturnsOnlyWhatWasNew() {
        val r = RasterCharts(ctx)
        assertEquals(listOf("/a.mbtiles", "/b.mbtiles"), r.add(listOf("/a.mbtiles", "/b.mbtiles")))
        assertEquals(listOf("/c.mbtiles"), r.add(listOf("/a.mbtiles", "/c.mbtiles")))
        assertEquals(listOf("/a.mbtiles", "/b.mbtiles", "/c.mbtiles"), r.paths)
    }

    /** "Order added" IS the contract: the newest covering set is the one the
     *  mariner just added while looking at this water. */
    @Test fun theOrderAddedSurvivesARelaunch() {
        RasterCharts(ctx).add(listOf("/z.mbtiles", "/a.mbtiles", "/m.mbtiles"))
        assertEquals(
            listOf("/z.mbtiles", "/a.mbtiles", "/m.mbtiles"),
            RasterCharts(ctx).paths,
        )
    }

    /**
     * The store used to be an unordered StringSet, which reloaded `.sorted()`
     * and silently turned "order added" into alphabetical. An old store still
     * has to open.
     */
    @Test fun anOldUnorderedStoreStillLoads() {
        ctx.getSharedPreferences("rastercharts.v1", Context.MODE_PRIVATE).edit()
            .putStringSet("paths", setOf("/b.mbtiles", "/a.mbtiles"))
            .apply()
        assertEquals(listOf("/a.mbtiles", "/b.mbtiles"), RasterCharts(ctx).paths)
    }

    /** Off keeps the file and stops drawing it: these are half-gigabyte
     *  downloads, and a mariner carrying four providers wants three quiet. */
    @Test fun switchingAChartOffKeepsIt() {
        val r = RasterCharts(ctx)
        r.add(listOf("/a.mbtiles"))
        assertTrue(r.isEnabled("/a.mbtiles"))
        r.setEnabled("/a.mbtiles", false)
        assertFalse(r.isEnabled("/a.mbtiles"))
        assertEquals(listOf("/a.mbtiles"), r.paths)
        assertFalse("and it is still off next launch", RasterCharts(ctx).isEnabled("/a.mbtiles"))
    }

    @Test fun forgettingAChartTakesItsSwitchWithIt() {
        val r = RasterCharts(ctx)
        r.add(listOf("/a.mbtiles", "/b.mbtiles"))
        r.setEnabled("/a.mbtiles", false)
        r.remove("/a.mbtiles")
        assertEquals(listOf("/b.mbtiles"), r.paths)
        assertTrue("a path added again starts on", r.isEnabled("/a.mbtiles"))
    }

    /**
     * The engine owns the election; the shell only remembers it. An entry for a
     * set not installed this launch is KEPT, because an unplugged drive is not a
     * change of mind.
     */
    @Test fun aHiddenSetSurvivesItsFilesBeingAbsent() {
        val r = RasterCharts(ctx)
        r.noteShown(listOf("NOAA" to true, "Navionics" to false))
        assertEquals(setOf("Navionics"), r.hidden)

        // Next launch the Navionics drive is not plugged in, so the engine does
        // not report that set at all.
        r.noteShown(listOf("NOAA" to true))
        assertEquals(setOf("Navionics"), r.hidden)

        // Plugged back in and shown again, it goes.
        r.noteShown(listOf("NOAA" to true, "Navionics" to true))
        assertTrue(r.hidden.isEmpty())
    }

    @Test fun theEncSwitchIsRemembered() {
        val r = RasterCharts(ctx)
        assertFalse(r.chartHidden)
        r.setChartHidden(true)
        assertTrue(RasterCharts(ctx).chartHidden)
    }
}
