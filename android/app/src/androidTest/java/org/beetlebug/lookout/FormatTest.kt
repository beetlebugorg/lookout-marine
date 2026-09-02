package org.beetlebug.lookout

import org.beetlebug.lookout.chart.CoordinateParser
import org.beetlebug.lookout.hud.bandString
import org.beetlebug.lookout.hud.coordString
import org.beetlebug.lookout.hud.dm
import org.beetlebug.lookout.hud.scaleString

import org.junit.Assert.assertEquals
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The position, scale and band strings.
 *
 * These are a CROSS-SHELL contract: `CoordFormat.dm` (macOS and iOS),
 * `lkw::FormatCoord` (Windows) and `lk_coord_format_dm` (Linux) are meant to
 * print exactly what [dm] prints, and `CoordFormat.band` and `lkw::BandForDenom`
 * exactly what [bandString] prints. Nothing in the repo checked that on any
 * platform. This is one shell's half of it, and the values here are the ones the
 * other three have to match.
 *
 * A mariner may read one of these over the radio or write it in a deck log, so
 * the digits matter more than most things this shell does.
 */
@RunWith(AndroidJUnit4::class)
class FormatTest {

    // ---- the position -------------------------------------------------------

    @Test fun aPositionIsDegreesAndDecimalMinutesWithAHemisphere() {
        // Annapolis, the water every fixture in this repo is on.
        assertEquals("38°58.578'N 076°28.602'W", coordString(38.9763, -76.4767))
    }

    /**
     * The longitude keeps three degree digits and the latitude two, so a pair
     * always occupies the same width and a column of them lines up.
     */
    @Test fun theLongitudeIsThreeDigitsAndTheLatitudeTwo() {
        assertEquals("00°00.000'N 000°00.000'E", coordString(0.0, 0.0))
        assertEquals("38°58.578'N", dm(38.9763, isLat = true))
        assertEquals("076°28.602'W", dm(-76.4767, isLat = false))
    }

    /** Minutes under ten keep their leading zero, for the same column. */
    @Test fun singleDigitMinutesArePadded() {
        assertEquals("38°03.000'N 076°30.000'W", coordString(38.05, -76.5))
    }

    /** South is negative latitude, west negative longitude. */
    @Test fun theHemisphereFollowsTheSign() {
        assertEquals("33°52.128'S 151°12.558'E", coordString(-33.8688, 151.2093))
        // A hair south of the equator is still south, however small the number.
        assertEquals("00°00.000'S", dm(-0.0000001, isLat = true))
    }

    /**
     * 59.9996' rounds to 60.000', which is the next whole degree and not a
     * minute value at all. Without the carry the readout prints "38°60.000'N".
     */
    @Test fun minutesRoundingUpToSixtyCarryIntoTheDegree() {
        assertEquals("39°00.000'N", dm(38.0 + 59.9996 / 60.0, isLat = true))
    }

    /** The format is stable across the shells only if it is stable here: what
     *  [dm] prints, [CoordinateParser] reads back. */
    @Test fun aPrintedPositionParsesBackToItself() {
        val lat = 38.9763
        val lon = -76.4767
        val parsed = CoordinateParser.parse(coordString(lat, lon))
        requireNotNull(parsed) { "the shell cannot read its own position format" }
        // Three decimal places of a minute is about two metres.
        assertEquals(lat, parsed.first, 1e-4)
        assertEquals(lon, parsed.second, 1e-4)
    }

    // ---- the scale ----------------------------------------------------------

    @Test fun theScaleIsOneToNWithGroupSeparators() {
        assertEquals("1:13,267", scaleString(13267.0))
        assertEquals("1:500", scaleString(500.0))
        assertEquals("1:1,000,000", scaleString(1_000_000.0))
    }

    /** No chart is open, or the view has no scale yet. A dash, never "1:0". */
    @Test fun noScaleReadsAsADash() {
        assertEquals("1:—", scaleString(0.0))
        assertEquals("1:—", scaleString(-1.0))
    }

    // ---- the band -----------------------------------------------------------

    /**
     * The S-52 navigational purpose bands, at and around every boundary. The
     * boundary belongs to the coarser band: 25,000 is Approach, not Harbor.
     */
    @Test fun everyBandBoundaryFallsOnTheCoarserSide() {
        assertEquals("Berthing", bandString(4_999.0))
        assertEquals("Harbor", bandString(5_000.0))
        assertEquals("Harbor", bandString(24_999.0))
        assertEquals("Approach", bandString(25_000.0))
        assertEquals("Approach", bandString(74_999.0))
        assertEquals("Coastal", bandString(75_000.0))
        assertEquals("Coastal", bandString(299_999.0))
        assertEquals("General", bandString(300_000.0))
        assertEquals("General", bandString(1_499_999.0))
        assertEquals("Overview", bandString(1_500_000.0))
        assertEquals("Overview", bandString(50_000_000.0))
    }

    /** No scale is not a band. */
    @Test fun noScaleHasNoBand() {
        assertEquals("—", bandString(0.0))
    }
}
