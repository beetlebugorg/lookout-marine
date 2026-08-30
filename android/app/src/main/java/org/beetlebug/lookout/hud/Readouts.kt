package org.beetlebug.lookout.hud

import org.beetlebug.lookout.Lookout

// What the HUD draws, as data.
//
// These live beside the HUD rather than beside the controller that fills them
// in: the readouts and the loader's steps are what the overlay is FOR, and
// putting them in `chart` made `hud` and `chart` import each other.

/** Everything the HUD shows, refreshed off the frame loop. */
data class Readouts(
    val lon: Double = 0.0,
    val lat: Double = 0.0,
    val zoom: Double = 0.0,
    val rotationDeg: Double = 0.0,
    val overscale: Double = 1.0,
    val scaleDenominator: Double = 0.0,
    val building: Boolean = false,
    /** 0 off, 1 following own ship, 2 armed and waiting for a fix. Polled,
     *  never remembered from a tap: the engine drops follow on a pan. */
    val followState: Int = 0,
    val courseUp: Boolean = false,
    /** A [Lookout] FIX_* state. The ship numbers mean nothing off FIX_LIVE. */
    val fixState: Int = Lookout.FIX_NONE,
    val shipLon: Double = 0.0,
    val shipLat: Double = 0.0,
)

/**
 * The startup loader's steps, the reference shell's LoadPhase: the one-time
 * symbol atlas bake, the open (one chart open per cell), then the first scene
 * build.
 */
enum class LoadPhase { SYMBOLS, MAPPING, TESSELLATING }
