package org.beetlebug.lookout

import org.beetlebug.lookout.pick.OverlayInfo
import org.beetlebug.lookout.pick.PickDecoded
import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.pick.OverlayBubble
import org.beetlebug.lookout.pick.PickReportCard

import androidx.compose.foundation.layout.Box
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The cursor pick report, and the bubble a tapped overlay object gets.
 *
 * One object at a time, decoded for the mariner: the operative fact as the
 * title, the attributes in chart language, and the raw S-57 rows one fold away.
 * The engine composes all of it; what this checks is that the card shows what
 * it was given, that the pick's other objects stay in sight beside it, and that
 * the two controls a chart problem gets reported through — the fold and the
 * copy — are there and work.
 */
@RunWith(AndroidJUnit4::class)
class PickReportUiTest {

    @get:Rule val compose = createComposeRule()

    private val light = one(PickFixture.feature(
        cls = "LIGHTS",
        chart = "US5MD1MC",
        title = "Thomas Point Shoal Light",
        subtitle = "Fl W 5s 43ft 16M",
        chip = "Light",
        footnote = "US5MD1MC · edition 12",
        notes = listOf("Restricted area: no anchoring within 100 m."),
        rows = listOf(
            PickFixture.row("Character", "Flashing white"),
            PickFixture.row("Chart note", "US5MD1MC.TXT", file = true),
        ),
        source = listOf(
            PickFixture.row("LITCHR", "2"),
            PickFixture.row("OBJNAM", "Thomas Point Shoal Light"),
            PickFixture.row("SECTR1"),
            PickFixture.row("", "10", depth = 1),
            PickFixture.row("", "20", depth = 1),
        ),
    ))

    private val buoy = one(PickFixture.feature(
        cls = "BOYLAT",
        chart = "US5MD1MC",
        title = "Green can buoy",
        subtitle = "Port hand",
        chip = "Buoy",
        footnote = "US5MD1MC",
        rows = listOf(PickFixture.row("Colour", "Green")),
        source = listOf(PickFixture.row("COLOUR", "4")),
    ))

    private fun one(feature: List<String>): PickDecoded =
        PickDecoded.decode(PickFixture.read(feature)).single()

    private var selected = 0
    private var dismissed = false
    private var openedFile: Pair<String, String>? = null

    private fun show(results: List<PickDecoded>, startAt: Int = 0) {
        selected = startAt
        dismissed = false
        openedFile = null
        compose.setContent {
            LookoutTheme(dark = false) {
                Box {
                    PickReportCard(
                        results = results,
                        selected = selected,
                        onSelect = { selected = it },
                        onDismiss = { dismissed = true },
                        width = 630.dp,
                        maxHeight = 700.dp,
                        onAuxFile = { cell, name -> openedFile = cell to name },
                    )
                }
            }
        }
    }

    // ---- the composed page --------------------------------------------------

    @Test fun theCardShowsWhatTheEngineComposed() {
        show(listOf(light))
        compose.onNodeWithText("Thomas Point Shoal Light").assertIsDisplayed()
        compose.onNodeWithText("Fl W 5s 43ft 16M").assertIsDisplayed()
        compose.onNodeWithText("Character").assertIsDisplayed()
        compose.onNodeWithText("Flashing white").assertIsDisplayed()
    }

    /** The provenance sits as one muted line, so a mariner can say which cell
     *  and which edition a wrong object came from. */
    @Test fun theSourceCellIsNamed() {
        show(listOf(light))
        compose.onNodeWithText("US5MD1MC · edition 12").assertIsDisplayed()
    }

    /** A note is read before the attributes: it is why the object was picked. */
    @Test fun aNoteIsPromotedAboveTheAttributes() {
        show(listOf(light))
        compose.onNodeWithText("Restricted area: no anchoring within 100 m.").assertIsDisplayed()
    }

    // ---- the pick's other objects -------------------------------------------

    /** A single object needs no list beside it. */
    @Test fun oneObjectGetsNoObjectList() {
        show(listOf(light))
        compose.onAllNodes(hasText("OBJECTS", substring = true)).assertCountEquals(0)
    }

    /**
     * The pick's objects stay in sight beside the report. There is no pager to
     * walk blind and nothing to go back from.
     */
    @Test fun severalObjectsAreListedBesideTheReport() {
        show(listOf(light, buoy))
        compose.onNodeWithText("2 OBJECTS").assertIsDisplayed()
        compose.onNodeWithText("Green can buoy").assertIsDisplayed()
    }

    @Test fun choosingAnotherObjectSelectsIt() {
        show(listOf(light, buoy))
        compose.onNodeWithText("Green can buoy").performClick()
        compose.waitForIdle()
        assertEquals(1, selected)
    }

    @Test fun theSelectedObjectIsTheOneReportedOn() {
        show(listOf(light, buoy), startAt = 1)
        // The attribute rows belong to the detail column alone, so they are
        // what says which object is being reported on. The title and subtitle
        // appear twice over — once in the header, once in the list row beside
        // it — which is the point of having the list.
        compose.onNodeWithText("Colour").assertIsDisplayed()
        compose.onNodeWithText("Green").assertIsDisplayed()
        compose.onAllNodes(hasText("Port hand")).assertCountEquals(2)
    }

    // ---- the controls -------------------------------------------------------

    @Test fun theCardCloses() {
        show(listOf(light))
        compose.onNodeWithContentDescription("Close the pick report").performClick()
        compose.waitForIdle()
        assertTrue(dismissed)
    }

    /** The copy is how a chart problem gets reported. */
    @Test fun theCopyControlIsThere() {
        show(listOf(light))
        compose.onNodeWithContentDescription("Copy this report").assertIsDisplayed()
        compose.onNodeWithContentDescription("Copy this report").performClick()
        compose.waitForIdle()
    }

    // ---- the fold -----------------------------------------------------------

    /** The raw payload is one fold away, and folded by default: the decoded
     *  page is what a mariner reads. */
    @Test fun theRawAttributesAreFoldedAway() {
        show(listOf(light))
        compose.onAllNodes(hasText("LITCHR", substring = true)).assertCountEquals(0)
        compose.onNode(hasText("S-57 source attributes", substring = true)).assertIsDisplayed()
    }

    @Test fun theFoldOpensTheCellsOwnWords() {
        show(listOf(light))
        compose.onNode(hasText("S-57 source attributes", substring = true)).performClick()
        compose.waitForIdle()
        compose.onNode(hasText("LITCHR", substring = true)).assertIsDisplayed()
        compose.onNode(hasText("SECTR1", substring = true)).assertIsDisplayed()
    }

    @Test fun theFoldClosesAgain() {
        show(listOf(light))
        val fold = hasText("S-57 source attributes", substring = true)
        compose.onNode(fold).performClick()
        compose.waitForIdle()
        compose.onNode(fold).performClick()
        compose.waitForIdle()
        compose.onAllNodes(hasText("LITCHR", substring = true)).assertCountEquals(0)
    }

    // ---- a file the chart carries -------------------------------------------

    /**
     * A row naming a file the chart carries opens it. A chart note or a bridge
     * photograph is the whole reason that row exists.
     */
    @Test fun aFileRowOpensTheFileItNames() {
        show(listOf(light))
        compose.onNodeWithText("US5MD1MC.TXT").performClick()
        compose.waitForIdle()
        assertEquals("US5MD1MC" to "US5MD1MC.TXT", openedFile)
    }

    @Test fun anOrdinaryRowOpensNothing() {
        show(listOf(light))
        compose.onNodeWithText("Flashing white").performClick()
        compose.waitForIdle()
        assertEquals(null, openedFile)
    }

    // ---- when the cell says nothing -----------------------------------------

    /** A blank body reads as a defect, so the card says which kind of empty. */
    @Test fun anObjectWithNoAttributesSaysSo() {
        show(listOf(one(PickFixture.feature("DEPARE", "US5MD1MC", title = "Depth area",
            empty = PickFixture.NO_ATTRIBUTES))))
        compose.onNodeWithText("The cell carries no attributes for this object.").assertIsDisplayed()
    }

    @Test fun anObjectWithOnlySourceDataSaysSo() {
        show(listOf(one(PickFixture.feature("M_NSYS", "US5MD1MC", title = "Nav system",
            empty = PickFixture.SOURCE_ONLY))))
        compose.onNodeWithText("The cell carries only source data for this object.").assertIsDisplayed()
    }

    /** A compose that failed still shows the object class and the cell. */
    @Test fun aRawPayloadStillMakesACard() {
        show(listOf(one(PickFixture.feature("BOYLAT", "US5MD1MC",
            source = listOf(PickFixture.row("OBJNAM", "Green can"))))))
        compose.onNodeWithText("BOYLAT").assertIsDisplayed()
        compose.onNodeWithText("US5MD1MC").assertIsDisplayed()
    }

    // ---- the overlay bubble -------------------------------------------------

    @Test fun aTappedTargetShowsWhatItSaysAboutItself() {
        var closed = false
        compose.setContent {
            LookoutTheme(dark = false) {
                Box {
                    OverlayBubble(
                        info = OverlayInfo(
                            title = "ANNE",
                            rows = listOf(
                                "MMSI" to "899000101",
                                "Speed" to "7.0 kn",
                                "Closest approach" to "124 m",
                            ),
                        ),
                        onDismiss = { closed = true },
                    )
                }
            }
        }
        compose.onNodeWithText("ANNE").assertIsDisplayed()
        compose.onNodeWithText("MMSI").assertIsDisplayed()
        compose.onNodeWithText("899000101").assertIsDisplayed()
        compose.onNodeWithText("Closest approach").assertIsDisplayed()
        compose.onNodeWithText("124 m").assertIsDisplayed()

        compose.onNodeWithContentDescription("Close").performClick()
        compose.waitForIdle()
        assertTrue(closed)
    }

    /** The bubble renders whatever rows the plugin chose and knows nothing
     *  about what any of them mean. */
    @Test fun aBubbleWithNoRowsIsStillATitle() {
        compose.setContent {
            LookoutTheme(dark = false) {
                Box { OverlayBubble(info = OverlayInfo("Waypoint 3", emptyList()), onDismiss = {}) }
            }
        }
        compose.onNodeWithText("Waypoint 3").assertIsDisplayed()
    }
}
