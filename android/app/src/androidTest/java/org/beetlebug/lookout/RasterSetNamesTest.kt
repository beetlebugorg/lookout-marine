package org.beetlebug.lookout

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.beetlebug.lookout.charts.RasterCharts
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The names the settings rows group raster charts by. They come from the
 * engine, so these run on a device where the engine is loaded.
 */
@RunWith(AndroidJUnit4::class)
class RasterSetNamesTest {

    private val ctx: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun aProviderInTheFileNameNamesTheSet() {
        assertEquals("Navionics", RasterCharts.providerLabel("/x/navionics-chesapeake.mbtiles"))
        assertEquals("OpenSeaMap", RasterCharts.providerLabel("/x/OpenSeaMap.mbtiles"))
        assertEquals("ArcGIS", RasterCharts.providerLabel("/x/ArcGIS.z12.mbtiles"))
    }

    /** One provider per file, so a variant is not a set of its own. */
    @Test fun aVariantIsTheSameSet() {
        assertEquals("ArcGIS", RasterCharts.providerLabel("/x/ArcGIS.Imagery.z12.mbtiles"))
    }

    /** A file from a provider the engine has no name for is its own stem. */
    @Test fun anUnknownProviderIsTheFileStem() {
        assertEquals("chesapeake.z14", RasterCharts.providerLabel("/x/chesapeake.z14.mbtiles"))
    }

    /**
     * A sheet this app baked belongs to the bake it came from. A bundle holds
     * hundreds of sheets and each one as its own set is not a choice a mariner
     * can make.
     */
    @Test fun aBakedSheetBelongsToItsBake() {
        assertEquals("NOAA", RasterCharts.providerLabel("/charts/NOAA/US5MD1MC/US5MD1MC.pmtiles"))
    }

    /** One switch per set, one per file. */
    @Test fun theChartsGroupBySetName() {
        val added = listOf("/x/Navionics.a.mbtiles", "/x/Navionics.b.mbtiles", "/x/OpenSeaMap.mbtiles")
        val r = RasterCharts(ctx)
        try {
            r.add(added)
            val groups = r.groups.toMap()
            assertEquals(2, groups["Navionics"]?.count { it in added })
            assertEquals(1, groups["OpenSeaMap"]?.count { it in added })
        } finally {
            added.forEach { r.remove(it) }
        }
    }
}
