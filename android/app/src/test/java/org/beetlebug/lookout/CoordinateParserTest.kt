package org.beetlebug.lookout

import org.beetlebug.lookout.chart.CoordinateParser

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * What the Go To field accepts.
 *
 * It takes what `CoordinateParser` on macOS and iOS takes, so a position copied
 * out of one shell pastes into another. A mariner also types these by hand on a
 * moving boat, so the accepted spellings are deliberately loose and the rejected
 * ones deliberately hard: a coordinate that silently parses wrong sends the
 * chart to the wrong water.
 */
class CoordinateParserTest {

    private fun parsed(s: String) =
        requireNotNull(CoordinateParser.parse(s)) { "did not parse: $s" }

    // ---- degrees, minutes, seconds -----------------------------------------

    @Test fun degreesMinutesAndSecondsWithHemispheres() {
        val (lat, lon) = parsed("38°58'34\"N 076°28'36\"W")
        assertEquals(38.0 + 58.0 / 60 + 34.0 / 3600, lat, 1e-9)
        assertEquals(-(76.0 + 28.0 / 60 + 36.0 / 3600), lon, 1e-9)
    }

    /** The form this shell itself prints. */
    @Test fun degreesAndDecimalMinutes() {
        val (lat, lon) = parsed("38°58.578'N 076°28.602'W")
        assertEquals(38.9763, lat, 1e-6)
        assertEquals(-76.4767, lon, 1e-6)
    }

    @Test fun degreesAlone() {
        val (lat, lon) = parsed("38°N 76°W")
        assertEquals(38.0, lat, 1e-9)
        assertEquals(-76.0, lon, 1e-9)
    }

    /** The prime and double-prime a chart uses, not only the typewriter forms. */
    @Test fun typographicMinuteAndSecondMarks() {
        val (lat, lon) = parsed("38°58′34″N 076°28′36″W")
        assertEquals(38.0 + 58.0 / 60 + 34.0 / 3600, lat, 1e-9)
        assertEquals(-(76.0 + 28.0 / 60 + 36.0 / 3600), lon, 1e-9)
    }

    @Test fun aLowercaseHemisphereIsAccepted() {
        val (lat, lon) = parsed("38°58.578'n 076°28.602'w")
        assertEquals(38.9763, lat, 1e-6)
        assertEquals(-76.4767, lon, 1e-6)
    }

    /** South and east, so both signs are exercised on both axes. */
    @Test fun southAndEast() {
        val (lat, lon) = parsed("33°52.128'S 151°12.558'E")
        assertEquals(-33.8688, lat, 1e-6)
        assertEquals(151.2093, lon, 1e-6)
    }

    // ---- the decimal pair ---------------------------------------------------

    @Test fun aCommaSeparatedDecimalPair() {
        val (lat, lon) = parsed("38.9763, -76.4767")
        assertEquals(38.9763, lat, 1e-9)
        assertEquals(-76.4767, lon, 1e-9)
    }

    @Test fun aSpaceSeparatedDecimalPair() {
        val (lat, lon) = parsed("38.9763 -76.4767")
        assertEquals(38.9763, lat, 1e-9)
        assertEquals(-76.4767, lon, 1e-9)
    }

    /** Latitude first, as every chart plotter writes it. */
    @Test fun theDecimalPairIsLatitudeThenLongitude() {
        val (lat, lon) = parsed("10, 20")
        assertEquals(10.0, lat, 1e-9)
        assertEquals(20.0, lon, 1e-9)
    }

    // ---- what it refuses ----------------------------------------------------

    @Test fun nothingIsNotAPosition() {
        assertNull(CoordinateParser.parse(""))
        assertNull(CoordinateParser.parse("   "))
    }

    @Test fun oneNumberIsNotAPosition() {
        assertNull(CoordinateParser.parse("38.9763"))
    }

    @Test fun wordsAreNotAPosition() {
        assertNull(CoordinateParser.parse("Annapolis"))
    }

    /**
     * Out of range is refused rather than clamped. A clamp would send the chart
     * somewhere plausible instead of saying the number is wrong.
     */
    @Test fun aLatitudePastThePoleIsRefused() {
        assertNull(CoordinateParser.parse("91, 0"))
        assertNull(CoordinateParser.parse("-91, 0"))
        assertNull(CoordinateParser.parse("91°N 0°E"))
    }

    @Test fun aLongitudePastTheAntimeridianIsRefused() {
        assertNull(CoordinateParser.parse("0, 181"))
        assertNull(CoordinateParser.parse("0, -181"))
    }

    /** A hemisphere on one axis only leaves the other unknown. */
    @Test fun oneHemisphereAloneIsRefused() {
        assertNull(CoordinateParser.parse("38°58.578'N"))
    }
}
