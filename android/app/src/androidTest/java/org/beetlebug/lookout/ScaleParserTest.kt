package org.beetlebug.lookout

import org.beetlebug.lookout.chart.ScaleParser
import org.beetlebug.lookout.chart.zoomDeltaForScale

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.ln

/**
 * What the scale entry accepts, and the zoom it turns into.
 *
 * A mariner asks for a scale the way it is written on a chart, which is any of
 * "25000", "1:25,000" or "25k". The sanity range is what stops a typo from
 * throwing the camera to a scale no chart has.
 */
@RunWith(AndroidJUnit4::class)
class ScaleParserTest {

    @Test fun aPlainNumber() {
        assertEquals(25_000.0, ScaleParser.parse("25000")!!, 0.0)
    }

    @Test fun groupSeparatorsAndSpacesAreIgnored() {
        assertEquals(25_000.0, ScaleParser.parse("25,000")!!, 0.0)
        assertEquals(25_000.0, ScaleParser.parse(" 25 000 ")!!, 0.0)
    }

    /** "1:25000" is how a chart states it; the 1 is not part of the number. */
    @Test fun theOneToPrefixIsDropped() {
        assertEquals(25_000.0, ScaleParser.parse("1:25000")!!, 0.0)
        assertEquals(25_000.0, ScaleParser.parse("1:25,000")!!, 0.0)
    }

    @Test fun thousandsAndMillionsSuffixes() {
        assertEquals(25_000.0, ScaleParser.parse("25k")!!, 0.0)
        assertEquals(25_000.0, ScaleParser.parse("25K")!!, 0.0)
        assertEquals(2_500_000.0, ScaleParser.parse("2.5M")!!, 0.0)
        assertEquals(2_500_000.0, ScaleParser.parse("1:2.5M")!!, 0.0)
    }

    /**
     * The range is the reference shell's: no chart is 1:5 and none is
     * 1:5,000,000,000, so both are a typo rather than a request.
     */
    @Test fun theSanityRangeIsInclusiveAtBothEnds() {
        assertEquals(100.0, ScaleParser.parse("100")!!, 0.0)
        assertEquals(100_000_000.0, ScaleParser.parse("100000000")!!, 0.0)
        assertNull(ScaleParser.parse("99"))
        assertNull(ScaleParser.parse("1:5"))
        assertNull(ScaleParser.parse("100000001"))
    }

    @Test fun nonsenseIsRefused() {
        assertNull(ScaleParser.parse(""))
        assertNull(ScaleParser.parse("   "))
        assertNull(ScaleParser.parse("harbour"))
        assertNull(ScaleParser.parse("1:"))
    }

    // ---- the zoom it becomes ------------------------------------------------

    /**
     * The denominator halves for every zoom level, so a factor of two is
     * exactly one level. The engine does the move, which is what keeps its
     * limits and its easing.
     */
    @Test fun halvingTheDenominatorIsOneZoomLevelIn() {
        assertEquals(1.0, zoomDeltaForScale(50_000.0, 25_000.0), 1e-12)
        assertEquals(-1.0, zoomDeltaForScale(25_000.0, 50_000.0), 1e-12)
        assertEquals(0.0, zoomDeltaForScale(25_000.0, 25_000.0), 1e-12)
        assertEquals(2.0, zoomDeltaForScale(100_000.0, 25_000.0), 1e-12)
    }

    @Test fun anArbitraryPairIsTheLogRatio() {
        assertEquals(ln(13_267.0 / 5_000.0) / ln(2.0), zoomDeltaForScale(13_267.0, 5_000.0), 1e-12)
    }

    /**
     * The band presets the entry dialog offers must each be a scale the parser
     * would have accepted, or a chip would set a value the Zoom button refuses.
     */
    @Test fun everyBandPresetIsItselfAValidScale() {
        for (n in listOf(2_000, 12_000, 50_000, 150_000, 700_000)) {
            assertEquals("preset $n", n.toDouble(), ScaleParser.parse(n.toString())!!, 0.0)
        }
    }
}
