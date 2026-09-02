package org.beetlebug.lookout

import org.beetlebug.lookout.pick.PickDecoded

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * What one pick result shows.
 *
 * THE ENGINE COMPOSES THE REPORT. lookout_picks_read hands over the composed
 * page beside the payload the cell states, and nothing here decides what a
 * mariner reads. `tile57_s57_report` does that once, for every shell, and the
 * fold's own rules are checked in src/pick.zig.
 *
 * What this pins is the walk and the fallbacks, which is the half the core does
 * not control: a page the compose left blank must still show the class and the
 * cell rather than an empty card.
 */
@RunWith(RobolectricTestRunner::class)
class PickDecodedTest {

    private val light = PickDecoded.decode(PickFixture.read(PickFixture.light)).single()

    // ---- the composed page --------------------------------------------------

    @Test fun theReportIsTakenWholeFromTheEngine() {
        assertEquals("Thomas Point Shoal Light", light.title)
        assertEquals("Fl W 5s 43ft 16M", light.subtitle)
        assertEquals("Light", light.chip)
        assertEquals("US5MD1MC · edition 12", light.footnote)
        assertNull(light.empty)
    }

    /** A note is promoted above the attributes: it is what a mariner reads
     *  before anything else on the card. */
    @Test fun theNotesAreRead() {
        assertEquals(listOf("Restricted area: no anchoring within 100 m."), light.notes)
    }

    @Test fun everyRowKeepsItsLabelValueAndIndent() {
        val rows = light.reportRows
        assertEquals(4, rows.size)
        assertEquals("Character", rows[0].label)
        assertEquals("Flashing white", rows[0].value)
        assertEquals(0, rows[0].depth)
        assertEquals(1, rows[1].depth)
    }

    /** A row naming a file the chart carries opens it, so the flag has to
     *  survive the crossing: it is the whole reason that row exists. */
    @Test fun aRowNamingAFileOrAPictureSaysSo() {
        val rows = light.reportRows
        assertTrue(rows[2].file)
        assertTrue(rows[3].picture)
        assertTrue("an ordinary row opens nothing", !rows[0].file && !rows[0].picture)
    }

    /** The fold is the payload the cell states, in the order the core put it
     *  in, with nothing the shell did applied to it. */
    @Test fun theFoldIsTheSourceRows() {
        assertEquals(
            listOf("LITCHR" to "2", "OBJNAM" to "Thomas Point Shoal Light", "SECTR1" to ""),
            light.rawRows.filter { it.depth == 0 }.map { it.label to it.value },
        )
        assertEquals(listOf("" to "10", "" to "20"),
            light.rawRows.filter { it.depth == 1 }.map { it.label to it.value })
    }

    // ---- more than one feature ----------------------------------------------

    /** The features come back in the core's order, best first, and each one's
     *  body has to end where the next one begins. */
    @Test fun everyFeatureIsReadInOrder() {
        val out = PickDecoded.decode(PickFixture.read(PickFixture.light, PickFixture.bareBuoy))
        assertEquals(listOf("LIGHTS", "BOYLAT"), out.map { it.cls })
        assertEquals(4, out[0].reportRows.size)
        assertEquals(2, out[1].rawRows.size)
    }

    // ---- when the compose says there is nothing to read ---------------------

    /** A blank body reads as a defect, so the engine says which kind of empty
     *  it is and the card explains itself. */
    @Test fun theTwoEmptyKindsAreDistinguished() {
        assertEquals(PickDecoded.EmptyKind.NO_ATTRIBUTES, kind(PickFixture.NO_ATTRIBUTES))
        assertEquals(PickDecoded.EmptyKind.SOURCE_ONLY, kind(PickFixture.SOURCE_ONLY))
        assertNull(kind(PickFixture.READS))
    }

    private fun kind(empty: Int) = PickDecoded.decode(PickFixture.read(
        PickFixture.feature("T", "C", title = "T", empty = empty),
    )).single().empty

    // ---- the fallbacks ------------------------------------------------------

    /**
     * A page the compose left blank still fills in from the class and the cell,
     * and the fold still shows everything the cell said.
     */
    @Test fun aBlankPageFallsBackToTheClassAndTheCell() {
        val d = PickDecoded.decode(PickFixture.read(PickFixture.bareBuoy)).single()
        assertEquals("BOYLAT", d.title)
        assertNull(d.subtitle)
        assertEquals("BOYLAT", d.chip)
        assertEquals("US5MD1MC", d.footnote)
        assertEquals(
            listOf("COLOUR" to "4", "OBJNAM" to "Green can"),
            d.rawRows.map { it.label to it.value },
        )
    }

    @Test fun aReadThatSaidNothingIsNoFeatures() {
        assertTrue(PickDecoded.decode(null).isEmpty())
        assertTrue(PickDecoded.decode(emptyArray()).isEmpty())
    }

    /** A feature cut short is dropped rather than read across the next one. */
    @Test fun aTruncatedFeatureIsDropped() {
        val flat = PickFixture.read(PickFixture.light)
        assertTrue(PickDecoded.decode(flat.copyOfRange(0, 14)).isEmpty())
    }

    // ---- the clipboard ------------------------------------------------------

    /**
     * The copy is how a chart problem gets reported, so it carries the cell's
     * own words: the source fold, under a header naming the object and the
     * cell.
     */
    @Test fun theClipboardTextIsTheFoldUnderAHeader() {
        val lines = light.plainText.trimEnd().lines()
        assertEquals("LIGHTS  US5MD1MC", lines[0])
        assertEquals("LITCHR: 2", lines[1])
        assertEquals("OBJNAM: Thomas Point Shoal Light", lines[2])
        assertEquals("SECTR1:", lines[3])
        // A WART, pinned rather than fixed here: a list member has no name of
        // its own, and plainText still gives it the "name: value" shape, so it
        // pastes as ": 10" with a bare colon. The fold on screen renders the
        // same row correctly, because it draws the name and the value in two
        // columns and an empty name is simply an empty column.
        assertEquals("  : 10", lines[4])
        assertEquals("  : 20", lines[5])
    }

    @Test fun theClipboardTextOfABlankPageIsStillTheFold() {
        val d = PickDecoded.decode(PickFixture.read(PickFixture.bareBuoy)).single()
        val lines = d.plainText.trimEnd().lines()
        assertEquals("BOYLAT  US5MD1MC", lines[0])
        assertEquals("COLOUR: 4", lines[1])
        assertEquals("OBJNAM: Green can", lines[2])
    }
}
