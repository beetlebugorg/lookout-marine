package org.beetlebug.lookout

import org.beetlebug.lookout.hud.BuildingPill
import org.beetlebug.lookout.hud.ChromeBubble
import org.beetlebug.lookout.hud.LoadPhase
import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.hud.NorthBubble
import org.beetlebug.lookout.hud.ScaleBar
import org.beetlebug.lookout.hud.StartupLoader

import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The chrome over the chart: the round controls, the scale bar and the loader.
 *
 * All of it sits on top of a SurfaceView the engine presents to, so each piece
 * has to say what it is to a screen reader and take its own taps without
 * letting them through to the chart underneath.
 */
@RunWith(AndroidJUnit4::class)
class ChromeTest {

    @get:Rule val compose = createComposeRule()

    private fun show(content: @Composable () -> Unit) {
        compose.setContent { LookoutTheme(dark = false) { Box { content() } } }
    }

    // ---- the round controls -------------------------------------------------

    @Test fun aChromeBubbleSaysWhatItDoesAndDoesIt() {
        var pressed = false
        show { ChromeBubble(Icons.Default.Search, "Go to coordinate") { pressed = true } }
        compose.onNodeWithContentDescription("Go to coordinate").assertIsDisplayed()
        compose.onNodeWithContentDescription("Go to coordinate").performClick()
        compose.waitForIdle()
        assertTrue(pressed)
    }

    /**
     * The compass is always visible: a mariner reads the chart's orientation
     * from it, and its absence would be a reading too.
     */
    @Test fun theNorthBubbleShowsNorthUntilTheChartIsCourseUp() {
        show { NorthBubble(rotationDeg = 0.0, followState = 0, courseUp = false, onCycle = {}) }
        compose.onNodeWithText("N").assertIsDisplayed()
    }

    /** Under course-up the letter changes and stops turning: the rotation is
     *  the information then. */
    @Test fun courseUpShowsCRatherThanN() {
        show { NorthBubble(rotationDeg = 37.0, followState = 1, courseUp = true, onCycle = {}) }
        compose.onNodeWithText("C").assertIsDisplayed()
        compose.onAllNodes(hasText("N")).assertCountEquals(0)
    }

    @Test fun theCompassWalksTheOrientationLadder() {
        var cycled = 0
        show { NorthBubble(rotationDeg = 0.0, followState = 0, courseUp = false, onCycle = { cycled++ }) }
        compose.onNodeWithText("N").performClick()
        compose.waitForIdle()
        assertTrue(cycled == 1)
    }

    // ---- the scale bar ------------------------------------------------------

    /** The distance rounds down to a round number, so the label always reads
     *  as one. */
    @Test fun theScaleBarLabelIsARoundDistance() {
        show { ScaleBar(scaleDenominator = 13_267.0) }
        val nice = listOf("10 m", "20 m", "50 m", "100 m", "200 m", "500 m",
                          "1 km", "2 km", "5 km", "10 km", "20 km", "50 km")
        val shown = nice.count { compose.onAllNodes(hasText(it)).fetchSemanticsNodes().isNotEmpty() }
        assertTrue("the bar shows no round distance", shown == 1)
    }

    /** With no scale there is nothing to draw. */
    @Test fun noScaleIsNoBar() {
        show { ScaleBar(scaleDenominator = 0.0) }
        compose.onAllNodes(hasText("m", substring = true)).assertCountEquals(0)
    }

    /**
     * A linked chart's credit rides the scale bar, because tile usage policies
     * make the visible credit a condition of service and the bar is the one
     * HUD element always on screen.
     */
    @Test fun anActiveChartLinkCreditsItsSource() {
        show { ScaleBar(scaleDenominator = 13_267.0, attribution = "© OpenStreetMap contributors") }
        compose.onNodeWithText("© OpenStreetMap contributors").assertIsDisplayed()
    }

    // ---- the loader ---------------------------------------------------------

    /**
     * Opening a real library is one chart open per cell plus the atlas bake,
     * which is tens of seconds with a bare surface behind it. The loader says
     * what the wait is for, step by step.
     */
    @Test fun theLoaderNamesEveryStep() {
        show { StartupLoader(cells = 7224, phase = LoadPhase.MAPPING) }
        compose.onNodeWithText("Opening 7,224 charts").assertIsDisplayed()
        compose.onNodeWithText("Preparing chart symbols").assertIsDisplayed()
        compose.onNodeWithText("Mapping 7,224 cells").assertIsDisplayed()
        compose.onNodeWithText("Drawing the first scene").assertIsDisplayed()
    }

    /** The atlas bake happens on the first run only, so it says so while it is
     *  the step that is running. */
    @Test fun theAtlasStepSaysItIsAFirstRunOnly() {
        show { StartupLoader(cells = 12, phase = LoadPhase.SYMBOLS) }
        compose.onNodeWithText("first run only").assertIsDisplayed()
    }

    /** Past that step the aside goes: on every other run the bake is already
     *  done rather than skipped. */
    @Test fun theAtlasAsideGoesOnceTheStepIsPast() {
        show { StartupLoader(cells = 12, phase = LoadPhase.TESSELLATING) }
        compose.onAllNodes(hasText("first run only")).assertCountEquals(0)
    }

    /** One cell is not "1 charts". */
    @Test fun aSingleChartIsNamedInTheSingular() {
        show { StartupLoader(cells = 1, phase = LoadPhase.MAPPING) }
        compose.onNodeWithText("Opening the chart").assertIsDisplayed()
        compose.onNodeWithText("Mapping the chart").assertIsDisplayed()
    }

    /** A later rebuild is a pill, not the whole loader: the chart is up and
     *  filling in behind it. */
    @Test fun aRebuildIsJustAPill() {
        show { BuildingPill() }
        compose.onNodeWithText("Building").assertIsDisplayed()
        compose.onAllNodes(hasText("Opening", substring = true)).assertCountEquals(0)
    }
}
