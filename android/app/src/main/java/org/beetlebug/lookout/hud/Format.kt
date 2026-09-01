package org.beetlebug.lookout.hud

import org.beetlebug.lookout.Lookout

// How a position, a scale and a scale band are written for a mariner.
//
// The engine writes them. Every shell calls the same format kit, so the same
// number prints the same string on every platform.
//
// `internal`, not private: they are the shell's, and the suite has to reach them.

fun coordString(lat: Double, lon: Double): String = Lookout.fmtPosition(lat, lon)

/**
 * Degrees and DECIMAL MINUTES with a hemisphere. The longitude has three degree
 * digits, so a pair keeps its column width.
 *
 * WHY NOT DEGREES, MINUTES AND SECONDS. Decimal minutes is what a mariner works
 * in: it is what a GPS and a chartplotter show, what goes in the deck log, and
 * what is passed over the radio. One minute of latitude is one nautical mile,
 * so a decimal minute reads as distance directly. Seconds belong to surveying.
 */
internal fun dm(value: Double, isLat: Boolean): String = Lookout.fmtCoordDm(value, isLat)

/** The full 1:N with group separators: `1:13,267`. */
internal fun scaleString(n: Double): String = Lookout.fmtScale(n)

/** The S-52 navigational purpose band for a display scale. */
internal fun bandString(n: Double): String = Lookout.bandName(n)
