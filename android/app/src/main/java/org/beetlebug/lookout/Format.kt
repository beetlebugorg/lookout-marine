package org.beetlebug.lookout

import java.util.Locale
import kotlin.math.abs

// How a position, a scale and a scale band are written for a mariner.
//
// THIS IS A CROSS-SHELL CONTRACT, not a local formatting choice. The same three
// formats are implemented in CoordFormat (macOS and iOS), lkw::FormatCoord and
// lkw::BandForDenom (Windows) and lk_coord_format_dm (Linux), and every host is
// meant to print the same string for the same number. Nothing in the repo
// checked that until FormatTest, which is this shell's half of the promise.
//
// `internal`, not private: they are the shell's, and the suite has to reach them.

fun coordString(lat: Double, lon: Double): String =
    "${dm(lat, true)} ${dm(lon, false)}"

/**
 * Degrees and DECIMAL MINUTES with a hemisphere. The longitude has three degree
 * digits, so a pair keeps its column width. It agrees with CoordFormat.dm
 * (macOS and iOS), lkw::FormatCoord (Windows) and lk_coord_format_dm (Linux).
 * Each host prints the same string.
 *
 * WHY NOT DEGREES, MINUTES AND SECONDS. Decimal minutes is what a mariner works
 * in: it is what a GPS and a chartplotter show, what goes in the deck log, and
 * what is passed over the radio. One minute of latitude is one nautical mile,
 * so a decimal minute reads as distance directly. Seconds belong to surveying.
 */
internal fun dm(value: Double, isLat: Boolean): String {
    val hemi = if (isLat) (if (value >= 0) "N" else "S") else (if (value >= 0) "E" else "W")
    val a = abs(value)
    var deg = a.toInt()
    var minutes = (a - deg) * 60
    // Carry the rounding. 59.9996' prints as 60.000', which is the next degree.
    if (Math.round(minutes * 1000) >= 60000) {
        minutes = 0.0
        deg++
    }
    val fmt = if (isLat) "%02d\u00B0%06.3f'%s" else "%03d\u00B0%06.3f'%s"
    return String.format(Locale.US, fmt, deg, minutes, hemi)
}

/** The full 1:N with group separators: `1:13,267`, as every shell prints it. */
internal fun scaleString(n: Double): String =
    if (n <= 0) "1:\u2014" else String.format(Locale.US, "1:%,d", Math.round(n))

/**
 * The S-52 navigational purpose band for a display scale. It agrees with
 * CoordFormat.band (macOS and iOS) and lkw::BandForDenom (Windows).
 */
internal fun bandString(n: Double): String = when {
    n < 0.001 -> "\u2014"
    n < 5_000 -> "Berthing"
    n < 25_000 -> "Harbor"
    n < 75_000 -> "Approach"
    n < 300_000 -> "Coastal"
    n < 1_500_000 -> "General"
    else -> "Overview"
}

