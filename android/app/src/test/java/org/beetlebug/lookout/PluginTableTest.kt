package org.beetlebug.lookout

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * A plugin's declared table: the columns, the rows, and the units they read in.
 *
 * UNITS ARE THE SHELL'S. The core sorts a column numerically in SI; the mariner
 * reads knots and nautical miles. That split is why the formatting lives here
 * and is worth pinning: a CPA shown in metres when it should be miles is a
 * number a mariner will act on.
 *
 * A null cell is a dash. Never heard and heard as zero are different values.
 */
@RunWith(RobolectricTestRunner::class)
class PluginTableTest {

    private val specs = parseTableSpecs(Fixtures.tables)
    private val ais = specs.first { it.key == "targets" }

    // ---- the declarations ---------------------------------------------------

    @Test fun everyDeclaredTableIsRead() {
        assertEquals(
            listOf("org.beetlebug.ais/targets", "org.example.routes/legs"),
            specs.map { it.id },
        )
        assertEquals("AIS Targets", ais.title)
        assertEquals("Vessels", ais.menu)
    }

    @Test fun theColumnsKeepTheirOrderLabelAndType() {
        assertEquals(
            listOf("name", "mmsi", "range", "brg", "sog", "cpa", "tcpa", "state"),
            ais.columns.map { it.key },
        )
        assertEquals("Vessel", ais.columns[0].label)
        assertEquals("distance", ais.columns[2].type)
        assertEquals("", ais.columns[7].label)
    }

    /** Text and flags read left, everything else is a number and reads right,
     *  because a column of numbers is scanned down. */
    @Test fun onlyTextAndFlagColumnsAreNotNumeric() {
        val numeric = ais.columns.associate { it.key to it.numeric }
        assertFalse(numeric["name"]!!)
        assertFalse(numeric["mmsi"]!!)
        assertFalse(numeric["state"]!!)
        assertTrue(numeric["range"]!!)
        assertTrue(numeric["brg"]!!)
        assertTrue(numeric["cpa"]!!)
        assertTrue(numeric["tcpa"]!!)
    }

    @Test fun theDeclaredSortIsRead() {
        assertEquals("cpa", ais.sortKey)
        assertTrue(ais.sortAscending)
        assertEquals("leg", specs[1].sortKey)
    }

    /**
     * `at` is what says a row can be found on the chart. A table without it has
     * no rows to reveal, so its rows must not offer a tap that does nothing.
     */
    @Test fun onlyATableDeclaringAPositionIsLocatable() {
        assertTrue(ais.locatable)
        assertFalse(specs[1].locatable)
    }

    /** The menu name is the plugin's own wording and the section id is the
     *  core's, so the match has to ignore case: "Vessels" against "vessels". */
    @Test fun theMenuNameMatchesASectionIdIgnoringCase() {
        assertTrue(ais.menu.equals("vessels", ignoreCase = true))
        assertTrue(specs[1].menu.equals("advanced", ignoreCase = true))
    }

    @Test fun aTableWithNoColumnsIsSkippedWhole() {
        val out = parseTableSpecs("""{"tables":[
            {"plugin":"p","key":"k","title":"T","columns":[]},
            {"plugin":"p","key":"ok","title":"T","columns":[{"key":"c","label":"C","type":"text"}]}]}""")
        assertEquals(listOf("ok"), out.map { it.key })
    }

    @Test fun aMalformedDeclarationIsNoTables() {
        assertTrue(parseTableSpecs(null).isEmpty())
        assertTrue(parseTableSpecs("{").isEmpty())
        assertTrue(parseTableSpecs("""{"tables":"nope"}""").isEmpty())
    }

    // ---- the rows -----------------------------------------------------------

    private val batch = requireNotNull(parseTableRows(Fixtures.tableRows, ais.columns.size))

    @Test fun theBatchCarriesItsSeqAndEveryRow() {
        assertEquals(312, batch.seq)
        assertEquals(
            listOf("899000101", "899000102", "366123456", "noposition"),
            batch.rows.map { it.id },
        )
    }

    /** The band is the plugin's ordering, which the core sorts within and never
     *  across: an alarmed vessel stays on the top line however the mariner
     *  sorts the columns. */
    @Test fun theBandRidesOnEveryRow() {
        assertEquals(listOf(0, 1, 1, 1), batch.rows.map { it.band })
    }

    /** The core writes `at` as [lon, lat], which is the order the camera takes
     *  and the reverse of how a position is spoken. */
    @Test fun thePositionIsLongitudeThenLatitude() {
        val anne = batch.rows[0]
        assertEquals(-76.481, anne.lon!!, 1e-9)
        assertEquals(38.974, anne.lat!!, 1e-9)
    }

    /** A table may declare `at` and still hold a row nobody has heard a
     *  position from. */
    @Test fun aRowWithNoPositionHasNone() {
        val zulu = batch.rows.last()
        assertNull(zulu.lon)
        assertNull(zulu.lat)
    }

    /** A row that carried fewer cells than the table has columns still lines
     *  up: the short row is padded, not misaligned. */
    @Test fun aShortRowIsPaddedToTheColumnCount() {
        for (row in batch.rows) assertEquals(ais.columns.size, row.cells.size)
        val zulu = batch.rows.last()
        assertEquals("ZULU", zulu.cells[0])
        assertEquals("244000001", zulu.cells[1])
        assertNull("everything past what was sent is missing, not zero", zulu.cells[2])
    }

    /** A JSON null is a cell the plugin did not send, and stays null. */
    @Test fun anExplicitNullStaysNull() {
        val charlie = batch.rows[2]
        assertNull(charlie.cells[5])
        assertNull(charlie.cells[6])
        assertNull(charlie.cells[7])
    }

    @Test fun aRowWithNoIdIsSkipped() {
        val b = parseTableRows("""{"seq":1,"rows":[{"band":0,"cells":[]},{"id":"a","cells":[]}]}""", 1)!!
        assertEquals(listOf("a"), b.rows.map { it.id })
    }

    @Test fun aMalformedBatchIsNull() {
        assertNull(parseTableRows("{", 3))
        assertNull(parseTableRows("""{"seq":1}""", 3))
    }

    // ---- what a cell reads --------------------------------------------------

    /**
     * Under a tenth of a mile the metres are what matters: a CPA of "0.07 nm"
     * tells a mariner far less than "124 m".
     */
    @Test fun aShortDistanceReadsInMetresAndALongOneInMiles() {
        assertEquals("124 m", PluginTableFormat.text(124.0, "distance"))
        assertEquals("185 m", PluginTableFormat.text(185.0, "distance"))
        assertEquals("0.10 nm", PluginTableFormat.text(185.2, "distance"))
        assertEquals("0.67 nm", PluginTableFormat.text(1240.0, "distance"))
        assertEquals("1.13 nm", PluginTableFormat.text(2100.0, "distance"))
    }

    /** The core holds metres per second; a mariner reads knots. */
    @Test fun aSpeedReadsInKnots() {
        assertEquals("7.0 kn", PluginTableFormat.text(3.6, "speed"))
        assertEquals("9.9 kn", PluginTableFormat.text(5.1, "speed"))
        assertEquals("0.0 kn", PluginTableFormat.text(0.0, "speed"))
    }

    /** Three digits, always, so a column of bearings lines up. */
    @Test fun aBearingIsThreeDigitsAndWrapsIntoRange() {
        assertEquals("275°", PluginTableFormat.text(275.0, "bearing"))
        assertEquals("012°", PluginTableFormat.text(12.0, "bearing"))
        assertEquals("000°", PluginTableFormat.text(0.0, "bearing"))
        assertEquals("355°", PluginTableFormat.text(-5.0, "bearing"))
        assertEquals("010°", PluginTableFormat.text(370.0, "bearing"))
    }

    /** Minutes and seconds, and hours once there are any. */
    @Test fun aDurationCountsDownTheWayAMarinerDoes() {
        assertEquals("9:45", PluginTableFormat.text(585.0, "duration"))
        assertEquals("30:00", PluginTableFormat.text(1800.0, "duration"))
        assertEquals("0:05", PluginTableFormat.text(5.0, "duration"))
        assertEquals("1:00:00", PluginTableFormat.text(3600.0, "duration"))
        assertEquals("1:01:01", PluginTableFormat.text(3661.0, "duration"))
    }

    /** A TCPA already past reads negative rather than wrapping. */
    @Test fun aNegativeDurationKeepsItsSign() {
        assertEquals("-2:30", PluginTableFormat.text(-150.0, "duration"))
    }

    @Test fun aFlagReadsAsAWord() {
        assertEquals("ALARM", PluginTableFormat.text("alarm", "flag"))
        assertEquals("WARNING", PluginTableFormat.text("warning", "flag"))
    }

    @Test fun textIsPassedThroughUntouched() {
        assertEquals("ANNE", PluginTableFormat.text("ANNE", "text"))
        assertEquals("899000101", PluginTableFormat.text("899000101", "text"))
    }

    /**
     * A cell the plugin did not send is a dash, and never reads as a zero: a
     * vessel nobody has heard a CPA from has not reported a CPA of nothing.
     */
    @Test fun aMissingCellIsADashInEveryColumnType() {
        for (type in listOf("text", "flag", "distance", "speed", "bearing", "duration", "number")) {
            assertEquals(type, PluginTableFormat.MISSING, PluginTableFormat.text(null, type))
        }
    }

    /** A number that is not a number is missing, not "NaN". */
    @Test fun aNonFiniteNumberIsMissing() {
        assertEquals(PluginTableFormat.MISSING, PluginTableFormat.text(Double.NaN, "distance"))
        assertEquals(PluginTableFormat.MISSING, PluginTableFormat.text(Double.POSITIVE_INFINITY, "speed"))
    }

    /**
     * A column type this build does not know still prints its number. `%g` is a
     * poor choice for it — 42 comes out "42.0000" — but the alternative today
     * is a blank cell, and a plugin declaring an unknown type is a manifest
     * this shell is older than.
     */
    @Test fun anUnknownColumnTypeStillPrintsItsNumber() {
        assertTrue(PluginTableFormat.text(42.0, "number").startsWith("42"))
    }
}
