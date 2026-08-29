package org.beetlebug.lookout

import org.beetlebug.lookout.chart.ChartScreen
import org.beetlebug.lookout.hud.Chrome
import org.beetlebug.lookout.pick.CalloutEdge
import org.beetlebug.lookout.pick.PICK_MARGIN
import org.beetlebug.lookout.pick.PICK_MARKER_SIZE
import org.beetlebug.lookout.pick.calloutPlacement
import org.beetlebug.lookout.pick.pickReportWidth

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Where the pick report stands over the mark.
 *
 * Pure geometry, so it needs no device and no Compose runtime. The rules it
 * encodes are all about not covering the thing the mariner just asked about:
 * the card holds one edge against the mark, stops clear of the HUD, keeps out
 * from under the status bar, and never runs off either side.
 */
class CalloutPlacementTest {

    /** The bottom band the readouts capsule owns, as ChartScreen computes it. */
    private val hudBand = Chrome.capsule + Chrome.margin * 2

    private fun place(
        x: Int, y: Int,
        width: Int = 430,
        viewWidth: Int = 800,
        viewHeight: Int = 1000,
        topInset: Int = 0,
    ) = calloutPlacement(
        pointX = x.dp, pointY = y.dp, width = width.dp,
        viewWidth = viewWidth.dp, viewHeight = viewHeight.dp,
        hudBand = hudBand, topInset = topInset.dp,
    )

    /** The gap the card keeps from the mark, so the mark stays visible. */
    private val clear = PICK_MARKER_SIZE / 2 + 6.dp

    // ---- which side of the mark ---------------------------------------------

    @Test fun withRoomAboveTheCardSitsAboveTheMark() {
        val p = place(x = 400, y = 600)
        assertEquals(CalloutEdge.ABOVE, p.edge)
        assertEquals(600.dp - clear, p.y)
    }

    /** Near the top there is nowhere to read a report, so it goes under. */
    @Test fun withNoRoomAboveTheCardDropsBelowTheMark() {
        val p = place(x = 400, y = 100)
        assertEquals(CalloutEdge.BELOW, p.edge)
        assertEquals(100.dp + clear, p.y)
    }

    /**
     * Above wins once there is enough to read a report in, even when below has
     * more. A card that jumps sides as the mariner picks down the screen is
     * harder to follow than one that stays put.
     */
    @Test fun enoughRoomAboveWinsEvenWhenBelowHasMore() {
        val p = place(x = 400, y = 300)
        assertEquals(CalloutEdge.ABOVE, p.edge)
        assertTrue("below really does have more room here", p.room < 700.dp)
    }

    // ---- the room it may use ------------------------------------------------

    /** `room` is a hard limit, so a long report scrolls rather than growing
     *  over the mark it describes. */
    @Test fun theRoomIsTheGapBetweenTheMarkAndTheEdge() {
        val above = place(x = 400, y = 600)
        assertEquals(600.dp - clear - PICK_MARGIN, above.room)

        val below = place(x = 400, y = 100)
        val floor = 1000.dp - hudBand
        assertEquals(floor - (100.dp + clear), below.room)
    }

    /** The room is never negative, whatever the mark's position. */
    @Test fun theRoomNeverGoesNegative() {
        assertTrue(place(x = 400, y = 0).room >= 0.dp)
        assertTrue(place(x = 400, y = 1000).room >= 0.dp)
        assertTrue(place(x = 400, y = 500, viewHeight = 60).room >= 0.dp)
    }

    // ---- the status bar -----------------------------------------------------

    /**
     * The ceiling is the safe area, not the view: a card that runs under the
     * status bar is read through the clock.
     */
    @Test fun theTopInsetRaisesTheCeiling() {
        val without = place(x = 400, y = 400, topInset = 0)
        val with = place(x = 400, y = 400, topInset = 48)
        assertEquals(CalloutEdge.ABOVE, without.edge)
        assertEquals(CalloutEdge.ABOVE, with.edge)
        assertEquals("48 dp of status bar is 48 dp less to read in",
            without.room - 48.dp, with.room)
    }

    /**
     * An inset can flip the card to the other side of the mark, and does so
     * sooner than it looks: at y=260 the room above is 225 dp bare and 177 dp
     * behind a 48 dp status bar, and 200 dp is the floor for reading a report.
     */
    @Test fun aTopInsetCanForceTheCardBelow() {
        assertEquals(CalloutEdge.ABOVE, place(x = 400, y = 260, topInset = 0).edge)
        assertEquals(CalloutEdge.BELOW, place(x = 400, y = 260, topInset = 48).edge)
    }

    // ---- the horizontal placement -------------------------------------------

    @Test fun theCardIsCentredOnTheMark() {
        assertEquals(400.dp - 430.dp / 2, place(x = 400, y = 600).x)
    }

    @Test fun aMarkNearTheLeftEdgeClampsToTheMargin() {
        assertEquals(PICK_MARGIN, place(x = 20, y = 600).x)
    }

    @Test fun aMarkNearTheRightEdgeClampsToTheOppositeMargin() {
        assertEquals(800.dp - PICK_MARGIN - 430.dp, place(x = 790, y = 600).x)
    }

    /** A card wider than the view still starts at the margin rather than at a
     *  negative offset. */
    @Test fun aCardWiderThanTheViewStartsAtTheMargin() {
        assertEquals(PICK_MARGIN, place(x = 150, y = 600, viewWidth = 300).x)
    }

    // ---- how wide the report is ---------------------------------------------

    @Test fun aSingleObjectGetsTheDetailColumnAlone() {
        assertEquals(430.dp, pickReportWidth(count = 1, viewWidth = 800.dp))
    }

    @Test fun severalObjectsAddTheObjectListBesideIt() {
        assertEquals(630.dp, pickReportWidth(count = 3, viewWidth = 800.dp))
    }

    /**
     * On a phone the card is clamped to the view. This is the parity gap the
     * review names: the object list keeps its fixed 200 dp out of the 387 the
     * card gets, leaving 187 dp of detail column to read a chart note in.
     */
    @Test fun aPhoneClampsTheCardToTheViewAndTheListEatsMostOfIt() {
        assertEquals(387.dp, pickReportWidth(count = 3, viewWidth = 411.dp))
    }

    /** Below a floor the card stops shrinking and overhangs instead: a report
     *  narrower than this cannot be read at all. */
    @Test fun theCardNeverShrinksBelowItsFloor() {
        assertEquals(280.dp, pickReportWidth(count = 1, viewWidth = 200.dp))
        assertEquals(280.dp, pickReportWidth(count = 3, viewWidth = 100.dp))
    }
}
