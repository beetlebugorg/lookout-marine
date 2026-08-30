package org.beetlebug.lookout

import org.beetlebug.lookout.pick.PickFeature
import org.beetlebug.lookout.pick.PickDecoded
import org.beetlebug.lookout.pick.S57

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * What one pick result shows.
 *
 * THE ENGINE COMPOSES THE REPORT. The core emits `{"report":…,"s57":…}` per
 * feature — the decoded page beside the raw payload — and nothing here decides
 * what a mariner reads. `tile57_s57_report` does that once, for every shell,
 * which is why the same keys are read by `PickDecoded` on macOS
 * (PickReport.swift:48).
 *
 * What this pins is the fallback behaviour, which is the half the core does not
 * control: a compose that failed must still show the cell's own words rather
 * than an empty card.
 */
@RunWith(RobolectricTestRunner::class)
class PickDecodedTest {

    private val envelope = """
        {"report":{
          "title":"Thomas Point Shoal Light",
          "subtitle":"Fl W 5s 43ft 16M",
          "chip":"Light",
          "notes":["Restricted area: no anchoring within 100 m."],
          "rows":[
            {"label":"Character","value":"Flashing white","depth":0},
            {"label":"Period","value":"5 s","depth":1},
            {"label":"Chart note","value":"US5MD1MC.TXT","depth":0,"file":true},
            {"label":"Photograph","value":"BRIDGE01.JPG","depth":0,"picture":true}],
          "footnote":"US5MD1MC · edition 12"},
         "s57":{"OBJNAM":"Thomas Point Shoal Light","LITCHR":2,"SECTR1":[10,20]}}
    """.trimIndent()

    private fun decoded(s57: String, cls: String = "LIGHTS", chart: String = "US5MD1MC") =
        PickDecoded(PickFeature(cls, s57, chart))

    // ---- the composed page --------------------------------------------------

    @Test fun theReportIsTakenWholeFromTheEngine() {
        val d = decoded(envelope)
        assertEquals("Thomas Point Shoal Light", d.title)
        assertEquals("Fl W 5s 43ft 16M", d.subtitle)
        assertEquals("Light", d.chip)
        assertEquals("US5MD1MC · edition 12", d.footnote)
        assertNull(d.empty)
    }

    /** A note is promoted above the attributes: it is what a mariner reads
     *  before anything else on the card. */
    @Test fun theNotesAreRead() {
        assertEquals(
            listOf("Restricted area: no anchoring within 100 m."),
            decoded(envelope).notes,
        )
    }

    @Test fun everyRowKeepsItsLabelValueAndIndent() {
        val rows = decoded(envelope).reportRows
        assertEquals(4, rows.size)
        assertEquals("Character", rows[0].label)
        assertEquals("Flashing white", rows[0].value)
        assertEquals(0, rows[0].depth)
        assertEquals(1, rows[1].depth)
    }

    /** A row naming a file the chart carries opens it, so the flag has to
     *  survive the decode: it is the whole reason that row exists. */
    @Test fun aRowNamingAFileOrAPictureSaysSo() {
        val rows = decoded(envelope).reportRows
        assertTrue(rows[2].file)
        assertTrue(rows[3].picture)
        assertTrue("an ordinary row opens nothing", !rows[0].file && !rows[0].picture)
    }

    // ---- when the compose says there is nothing to read ---------------------

    /** A blank body reads as a defect, so the engine says which kind of empty
     *  it is and the card explains itself. */
    @Test fun theTwoEmptyKindsAreDistinguished() {
        assertEquals(
            PickDecoded.EmptyKind.NO_ATTRIBUTES,
            decoded("""{"report":{"title":"T","empty":"none"},"s57":{}}""").empty,
        )
        assertEquals(
            PickDecoded.EmptyKind.SOURCE_ONLY,
            decoded("""{"report":{"title":"T","empty":"source"},"s57":{}}""").empty,
        )
        assertNull(decoded("""{"report":{"title":"T","empty":"other"},"s57":{}}""").empty)
    }

    // ---- the fallbacks ------------------------------------------------------

    /**
     * A payload without the envelope is a raw object, which is the core's
     * fallback when a compose fails. The card still fills in from the feature,
     * and the fold still shows everything the cell said.
     */
    @Test fun aRawPayloadFallsBackToTheFeatureAndKeepsItsRows() {
        val d = decoded("""{"OBJNAM":"Green can","COLOUR":4}""", cls = "BOYLAT", chart = "US5MD1MC")
        assertEquals("BOYLAT", d.title)
        assertNull(d.subtitle)
        assertEquals("BOYLAT", d.chip)
        assertEquals("US5MD1MC", d.footnote)
        assertEquals(
            listOf("COLOUR" to "4", "OBJNAM" to "Green can"),
            d.rawRows.map { it.name to it.value },
        )
    }

    @Test fun anEmptyPayloadIsStillACard() {
        val d = decoded("", cls = "DEPARE")
        assertEquals("DEPARE", d.title)
        assertTrue(d.reportRows.isEmpty())
        assertTrue(d.rawRows.isEmpty())
    }

    @Test fun anUnparseablePayloadDoesNotThrow() {
        val d = decoded("{ not json", cls = "SOUNDG")
        assertEquals("SOUNDG", d.title)
        assertTrue(d.rawRows.isEmpty())
    }

    // ---- the raw fold -------------------------------------------------------

    /** The fold shows the payload the cell states, out of the envelope when
     *  there is one, with nothing the decode did applied to it. */
    @Test fun theFoldShowsTheRawHalfOfTheEnvelope() {
        val rows = decoded(envelope).rawRows
        assertEquals(
            listOf("LITCHR" to "2", "OBJNAM" to "Thomas Point Shoal Light", "SECTR1" to ""),
            rows.filter { it.depth == 0 }.map { it.name to it.value },
        )
    }

    /** Keys are sorted, so two picks of the same object class read alike. */
    @Test fun theRawRowsAreSortedByKey() {
        val rows = S57.rows(org.json.JSONObject("""{"ZZZ":1,"AAA":2,"MMM":3}"""))
        assertEquals(listOf("AAA", "MMM", "ZZZ"), rows.map { it.name })
    }

    /** A list is its name, then its members one level in. */
    @Test fun anArrayIndentsItsMembersUnderItsName() {
        val rows = S57.rows(org.json.JSONObject("""{"SECTR1":[10,20]}"""))
        assertEquals(listOf("SECTR1" to "", "" to "10", "" to "20"), rows.map { it.name to it.value })
        assertEquals(listOf(0, 1, 1), rows.map { it.depth })
    }

    @Test fun anObjectIndentsItsKeysUnderItsName() {
        val rows = S57.rows(org.json.JSONObject("""{"QUALTY":{"POSACC":5}}"""))
        assertEquals(listOf("QUALTY" to "", "POSACC" to "5"), rows.map { it.name to it.value })
        assertEquals(listOf(0, 1), rows.map { it.depth })
    }

    /** A whole number prints whole: "5", never "5.0". */
    @Test fun aWholeNumberHasNoTrailingZero() {
        val rows = S57.rows(org.json.JSONObject("""{"A":5.0,"B":5.5}"""))
        assertEquals(listOf("5", "5.5"), rows.map { it.value })
    }

    @Test fun nothingAtAllIsNoRows() {
        assertTrue(S57.rows(null).isEmpty())
        assertTrue(S57.rows(org.json.JSONObject.NULL).isEmpty())
    }

    // ---- the clipboard ------------------------------------------------------

    /**
     * The copy is how a chart problem gets reported, so it carries the cell's
     * own words: the raw payload, out of the envelope, under a header naming
     * the object and the cell.
     */
    @Test fun theClipboardTextIsTheRawPayloadUnderAHeader() {
        val text = S57.plainText(PickFeature("LIGHTS", envelope, "US5MD1MC"))
        val lines = text.trimEnd().lines()
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

    @Test fun theClipboardTextOfARawPayloadIsTheWholeObject() {
        val text = S57.plainText(PickFeature("BOYLAT", """{"OBJNAM":"Green can"}""", "US5MD1MC"))
        assertEquals(listOf("BOYLAT  US5MD1MC", "OBJNAM: Green can"), text.trimEnd().lines())
    }
}
