package org.beetlebug.lookout

import org.beetlebug.lookout.hud.Readouts
import org.beetlebug.lookout.charts.RasterSet
import org.beetlebug.lookout.charts.RasterState
import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.hud.ReadoutsCapsule
import org.beetlebug.lookout.hud.coordString

import androidx.compose.foundation.layout.Box
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The readouts capsule, on a device.
 *
 * The capsule is the one piece of chrome that is always on screen, and the one
 * a mariner reads a number off. The rules it has to keep are the reference
 * shell's, checked there by CompactHudTests.swift and until now by nothing here:
 * the position is always readable, the fix state is never carried by colour
 * alone, and a number that is not own ship's reported fix never sits beside a
 * GPS pill.
 */
@RunWith(AndroidJUnit4::class)
class HudTest {

    @get:Rule val compose = createComposeRule()

    /** Annapolis: the chart centre, with own ship a little west of it. */
    private fun readouts(
        fix: Int = Lookout.FIX_LIVE,
        overscale: Double = 1.0,
        scale: Double = 13_267.0,
    ) = Readouts(
        lon = -76.4767, lat = 38.9763,
        zoom = 14.5, rotationDeg = 0.0,
        overscale = overscale, scaleDenominator = scale,
        fixState = fix,
        shipLon = -76.4820, shipLat = 38.9801,
    )

    private fun show(
        r: Readouts = readouts(),
        compact: Boolean = false,
        raster: RasterState = RasterState(),
        onScaleTap: () -> Unit = {},
        onConfigureGps: () -> Unit = {},
        onRasterSelect: (Int) -> Unit = {},
        onToggleChart: () -> Unit = {},
        onAddRasterCharts: () -> Unit = {},
    ) {
        compose.setContent {
            LookoutTheme(dark = false) {
                Box {
                    ReadoutsCapsule(
                        readouts = r,
                        compact = compact,
                        onScaleTap = onScaleTap,
                        raster = raster,
                        onRasterSelect = onRasterSelect,
                        onToggleChart = onToggleChart,
                        onAddRasterCharts = onAddRasterCharts,
                        onConfigureGps = onConfigureGps,
                    )
                }
            }
        }
    }

    // ---- what the wide capsule carries --------------------------------------

    @Test fun theWideCapsuleCarriesTheBandScaleAndZoom() {
        show()
        compose.onNodeWithText("Harbor").assertIsDisplayed()
        compose.onNodeWithText("1:13,267").assertIsDisplayed()
        compose.onNodeWithText("z14.5").assertIsDisplayed()
    }

    /** The band is what says how much the chart has generalised what it shows,
     *  and it moves with the scale. */
    @Test fun theBandFollowsTheScale() {
        show(readouts(scale = 4_000.0))
        compose.onNodeWithText("Berthing").assertIsDisplayed()
    }

    // ---- the fix ------------------------------------------------------------

    /** Three states that differ in more than colour, so no one signal carries
     *  the fix alone. */
    @Test fun aLiveFixShowsTheGpsPillAndOwnShipsPosition() {
        show(readouts(fix = Lookout.FIX_LIVE))
        compose.onNodeWithText("GPS").assertIsDisplayed()
        compose.onNodeWithText(coordString(38.9801, -76.4820)).assertIsDisplayed()
    }

    /**
     * THE SHIP-OR-NOTHING RULE. A lost fix shows no position at all: the map
     * centre or a dead-reckoned number beside a fix pill is a wrong position a
     * mariner may write in a log.
     */
    @Test fun aLostFixShowsNoNumbersAtAll() {
        show(readouts(fix = Lookout.FIX_LOST))
        compose.onNodeWithText("NO GPS").assertIsDisplayed()
        assertNoCoordinateAnywhere()
    }

    /** Never having had a source carries a fix-it, not a warning. */
    @Test fun withNoSourceThePillOffersToConfigureOne() {
        var asked = false
        show(readouts(fix = Lookout.FIX_NONE), onConfigureGps = { asked = true })
        compose.onNodeWithText("Configure GPS").assertIsDisplayed()
        compose.onNodeWithText("Configure GPS").performClick()
        compose.waitForIdle()
        assertTrue("the pill must open Connections", asked)
    }

    @Test fun withNoSourceThereIsNoPositionEither() {
        show(readouts(fix = Lookout.FIX_NONE))
        assertNoCoordinateAnywhere()
    }

    // ---- the narrow capsule -------------------------------------------------

    /**
     * A phone will not take the whole row on one line, so it falls to two
     * rather than dropping the position: the position is the one readout a
     * mariner may have to write down or pass over the radio.
     */
    @Test fun theNarrowCapsuleKeepsThePositionOnASecondLine() {
        show(compact = true)
        compose.onNodeWithText("Harbor").assertIsDisplayed()
        compose.onNodeWithText("1:13,267").assertIsDisplayed()
        compose.onNodeWithText("z14.5").assertIsDisplayed()
    }

    /**
     * And on a phone the position it keeps is OWN SHIP'S, once there is a fix.
     * The same rule as the wide row: what sits beside a GPS pill is the
     * vessel's reported fix and nothing else.
     */
    @Test fun theNarrowCapsuleShowsOwnShipsPositionWhenThereIsAFix() {
        show(compact = true, r = readouts(fix = Lookout.FIX_LIVE))
        compose.onNodeWithText("GPS").assertIsDisplayed()
        compose.onNodeWithText(coordString(38.9801, -76.4820)).assertIsDisplayed()
    }

    @Test fun theNarrowCapsuleShowsNoPositionWithoutAFix() {
        show(compact = true, r = readouts(fix = Lookout.FIX_LOST))
        compose.onNodeWithText("NO GPS").assertIsDisplayed()
        assertNoCoordinateAnywhere()
    }

    // ---- the overscale badge ------------------------------------------------

    /** An overscale badge that is always up is decoration; this one means
     *  "you are magnifying past the survey". */
    @Test fun theOverscaleBadgeStaysAwayUntilItMeansSomething() {
        show(readouts(overscale = 1.0))
        compose.onAllNodesWithTextContaining("×").assertCountEquals(0)
    }

    @Test fun theOverscaleBadgeAppearsPastTheThreshold() {
        show(readouts(overscale = 2.4))
        compose.onNodeWithText("×2.4").assertIsDisplayed()
    }

    // ---- the scale entry ----------------------------------------------------

    /** The scale readout opens the scale entry. It shares its row with other
     *  readouts, so the inner control has to win on its own area. */
    @Test fun theScaleReadoutOpensItsEntry() {
        var tapped = false
        show(onScaleTap = { tapped = true })
        compose.onNodeWithText("1:13,267").performClick()
        compose.waitForIdle()
        assertTrue("a tap on the scale must open the entry", tapped)
    }

    // ---- the raster chart pill ----------------------------------------------

    private val covering = RasterState(
        active = 0,
        sets = listOf(
            RasterSet(0, "Navionics", inView = true, shown = true),
            RasterSet(1, "OpenSeaMap", inView = true, shown = false),
            RasterSet(2, "Elsewhere", inView = false, shown = false),
        ),
    )

    /** The pill exists only where a raster chart is in view. Where the mariner
     *  carries nothing there is nothing to press. */
    @Test fun withNoRasterChartInViewThereIsNoPill() {
        show(raster = RasterState())
        compose.onAllNodesWithTextContaining("NAVIONICS").assertCountEquals(0)
    }

    @Test fun thePillNamesTheSetDrawnOverThisView() {
        show(raster = covering)
        compose.onNodeWithText("NAVIONICS").assertIsDisplayed()
    }

    /**
     * The pill NAMES the drawn set when one is drawn, and reports the state of
     * the set it names. Naming one set and reporting another is how a pill
     * comes to read "NAVIONICS | OFF" while Navionics is drawn.
     */
    @Test fun aDrawnSetIsNotReportedAsOff() {
        show(raster = covering)
        compose.onAllNodesWithTextContaining("OFF").assertCountEquals(0)
    }

    @Test fun aSetInViewButNotDrawnReportsItselfOff() {
        show(raster = covering.copy(active = -1))
        compose.onNodeWithText("NAVIONICS").assertIsDisplayed()
        compose.onNodeWithText("OFF").assertIsDisplayed()
    }

    /** Hiding the ENC leaves the raster chart drawn, so the pill keeps naming
     *  it and says which layer is off. */
    @Test fun hidingTheEncSaysSoWithoutSayingThePictureIsOff() {
        show(raster = covering.copy(chartHidden = true))
        compose.onNodeWithText("NAVIONICS").assertIsDisplayed()
        compose.onNodeWithText("ENC OFF").assertIsDisplayed()
    }

    /** The state at a glance, for a reader who cannot see the colour. */
    @Test fun thePillSaysItsStateToAScreenReader() {
        show(raster = covering)
        compose.onNodeWithContentDescription("Raster chart Navionics, drawn").assertIsDisplayed()
    }

    /**
     * A TAP ON THE PILL OPENS THE LIST. This is the one that catches a pill
     * which draws correctly and does nothing when pressed.
     */
    @Test fun tappingThePillOpensTheListOfWhatCoversThisWater() {
        show(raster = covering)
        compose.onNodeWithText("NAVIONICS").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("OpenSeaMap").assertIsDisplayed()
        compose.onNodeWithText("None").assertIsDisplayed()
    }

    /** Only the sets covering THIS water are offered. */
    @Test fun theListOffersOnlyWhatCoversThisWater() {
        show(raster = covering)
        compose.onNodeWithText("NAVIONICS").performClick()
        compose.waitForIdle()
        compose.onAllNodesWithTextContaining("Elsewhere").assertCountEquals(0)
    }

    @Test fun choosingASetSelectsIt() {
        var chosen = -99
        show(raster = covering, onRasterSelect = { chosen = it })
        compose.onNodeWithText("NAVIONICS").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("OpenSeaMap").performClick()
        compose.waitForIdle()
        assertEquals(1, chosen)
    }

    /** "None" stops drawing, which is half of the comparison the whole feature
     *  exists for. */
    @Test fun choosingNoneTurnsTheDrawnSetOff() {
        var chosen = -99
        show(raster = covering, onRasterSelect = { chosen = it })
        compose.onNodeWithText("NAVIONICS").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("None").performClick()
        compose.waitForIdle()
        assertEquals(-1, chosen)
    }

    @Test fun theListCarriesTheEncSwitchAndTheWayToAddCharts() {
        var toggled = false
        var added = false
        show(raster = covering, onToggleChart = { toggled = true }, onAddRasterCharts = { added = true })

        compose.onNodeWithText("NAVIONICS").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Hide ENC Over Raster").performClick()
        compose.waitForIdle()
        assertTrue(toggled)

        compose.onNodeWithText("NAVIONICS").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Add Raster Charts…").performClick()
        compose.waitForIdle()
        assertTrue(added)
    }

    // ---- helpers ------------------------------------------------------------

    /** No degrees sign anywhere on screen: the capsule is showing no position. */
    private fun assertNoCoordinateAnywhere() {
        compose.onAllNodesWithTextContaining("°").assertCountEquals(0)
    }
}

/** Substring matching, which the capsule needs: a readout sits in a merged row. */
private fun androidx.compose.ui.test.junit4.ComposeContentTestRule.onAllNodesWithTextContaining(
    text: String,
) = onAllNodes(hasText(text, substring = true))
