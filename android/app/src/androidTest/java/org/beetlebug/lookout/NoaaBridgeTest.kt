package org.beetlebug.lookout

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The NOAA and palette natives, against the real core.
 *
 * A missing JNI symbol links fine and fails at the call, so the point of this
 * is that the calls resolve and answer what the C ABI says they answer. Both
 * of these read tables the core holds, so neither needs a chart open.
 */
@RunWith(AndroidJUnit4::class)
class NoaaBridgeTest {

    /**
     * Nine Coast Guard districts, four strings each. District 3 was
     * disestablished and ships no cells, so it is not among them.
     */
    @Test
    fun regionsAreTheDistricts() {
        val flat = Lookout.noaaRegions()
        assertEquals("four strings per region", 0, flat.size % 4)
        val ids = (flat.indices step 4).map { flat[it] }
        assertEquals(9, ids.size)
        for (id in listOf("d1", "d5", "d7", "d8", "d9", "d11", "d13", "d14", "d17")) {
            assertTrue("no region $id", ids.contains(id))
        }
        assertFalse("district 3 ships no cells", ids.contains("d3"))

        // Each row carries a name, a line of water and an extent that parses.
        for (i in flat.indices step 4) {
            assertTrue("region ${flat[i]} has no name", flat[i + 1].isNotEmpty())
            assertTrue("region ${flat[i]} has no blurb", flat[i + 2].isNotEmpty())
            val extent = flat[i + 3].split(",").mapNotNull { it.toDoubleOrNull() }
            assertEquals("region ${flat[i]} extent", 4, extent.size)
            assertTrue("west is east of east", extent[0] < extent[2])
            assertTrue("south is north of north", extent[1] < extent[3])
        }
    }

    /** The palette answers for the tokens a depth page draws with. */
    @Test
    fun theDepthShadesHaveColours() {
        val rgba = FloatArray(4)
        for (token in listOf("DEPVS", "DEPMS", "DEPMD", "DEPDW", "LANDA", "DEPCN")) {
            assertTrue("no colour for $token", Lookout.s52Color(token, 0, rgba))
            for (c in rgba) assertTrue("$token is out of 0..1: $c", c in 0f..1f)
            assertTrue("$token is transparent", rgba[3] > 0f)
        }
        // The four shades of water get lighter as the water gets deeper.
        val shade = listOf("DEPVS", "DEPMS", "DEPMD", "DEPDW").map {
            Lookout.s52Color(it, 0, rgba)
            rgba[0] + rgba[1] + rgba[2]
        }
        assertEquals("four shades", 4, shade.size)
        assertTrue("the shades do not lighten: $shade", shade == shade.sorted())
    }

    /** A token the table does not hold is refused rather than answered. */
    @Test
    fun anUnknownTokenIsRefused() {
        assertFalse(Lookout.s52Color("NOSUCH", 0, FloatArray(4)))
    }
}
