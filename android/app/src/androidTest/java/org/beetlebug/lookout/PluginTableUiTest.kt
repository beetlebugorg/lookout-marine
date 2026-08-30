package org.beetlebug.lookout

import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.plugins.PluginTable
import org.beetlebug.lookout.plugins.TableBatch
import org.beetlebug.lookout.plugins.TableColumn
import org.beetlebug.lookout.plugins.TableRow
import org.beetlebug.lookout.plugins.TableSpec

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A plugin's declared table, on screen.
 *
 * The shell knows nothing about what any plugin does: it draws the columns the
 * manifest declared, in the units of the sea, in the order the core sorted
 * them. What it has to get right is that a number reads as a mariner expects,
 * that a missing value never reads as a zero, and that the sort a header offers
 * is one the core can actually do.
 */
@RunWith(AndroidJUnit4::class)
class PluginTableUiTest {

    @get:Rule val compose = createComposeRule()

    private val ais = TableSpec(
        plugin = "org.beetlebug.ais",
        key = "targets",
        title = "AIS Targets",
        menu = "Vessels",
        columns = listOf(
            TableColumn("name", "Vessel", "text"),
            TableColumn("mmsi", "MMSI", "text"),
            TableColumn("cpa", "CPA", "distance"),
            TableColumn("tcpa", "TCPA", "duration"),
            TableColumn("sog", "SOG", "speed"),
            TableColumn("state", "", "flag"),
        ),
        sortKey = "cpa",
        sortAscending = true,
        locatable = true,
    )

    private val batch = TableBatch(
        seq = 1,
        rows = listOf(
            TableRow("899000101", 0, -76.481, 38.974,
                listOf("ANNE", "899000101", 124.0, 585.0, 3.6, "alarm")),
            TableRow("899000102", 1, -76.462, 38.981,
                listOf("BRAVO", "899000102", 2100.0, 1800.0, 5.1, null)),
            TableRow("noposition", 1, null, null,
                listOf("ZULU", "244000001", null, null, null, null)),
        ),
    )

    private var sorted: String? = null
    private var revealed: Pair<Double, Double>? = null
    private var closed = false

    private fun show(
        spec: TableSpec = ais,
        rows: TableBatch? = batch,
        sortKey: String = "cpa",
        ascending: Boolean = true,
    ) {
        sorted = null; revealed = null; closed = false
        compose.setContent {
            LookoutTheme(dark = false) {
                PluginTable(
                    spec = spec,
                    batch = rows,
                    sortKey = sortKey,
                    sortAscending = ascending,
                    onSort = { sorted = it },
                    onReveal = { lon, lat -> revealed = lon to lat },
                    onDismiss = { closed = true },
                )
            }
        }
    }

    // ---- the columns --------------------------------------------------------

    @Test fun theTableIsTitledAndCarriesItsDeclaredColumns() {
        show()
        compose.onNodeWithText("AIS Targets").assertIsDisplayed()
        compose.onNodeWithText("Vessel").assertIsDisplayed()
        compose.onNodeWithText("MMSI").assertIsDisplayed()
        compose.onNodeWithText("SOG").assertIsDisplayed()
    }

    /** The sorted column carries the arrow, and only that one. */
    @Test fun theSortedColumnIsMarkedAndTheOthersAreNot() {
        show(sortKey = "cpa", ascending = true)
        compose.onNodeWithText("CPA ▲").assertIsDisplayed()
        compose.onAllNodes(hasText("▲", substring = true)).assertCountEquals(1)
        compose.onAllNodes(hasText("▼", substring = true)).assertCountEquals(0)
    }

    @Test fun theArrowFollowsTheDirection() {
        show(sortKey = "cpa", ascending = false)
        compose.onNodeWithText("CPA ▼").assertIsDisplayed()
    }

    @Test fun aHeaderTapAsksForThatColumn() {
        show()
        compose.onNodeWithText("Vessel").performClick()
        compose.waitForIdle()
        assertEquals("name", sorted)
    }

    // ---- the rows -----------------------------------------------------------

    /** Units are the shell's: the core holds metres and metres per second. */
    @Test fun everyNumberReadsInTheUnitsOfTheSea() {
        show()
        compose.onNodeWithText("124 m").assertIsDisplayed()
        compose.onNodeWithText("1.13 nm").assertIsDisplayed()
        compose.onNodeWithText("9:45").assertIsDisplayed()
        compose.onNodeWithText("30:00").assertIsDisplayed()
        compose.onNodeWithText("7.0 kn").assertIsDisplayed()
    }

    /**
     * A cell the plugin never sent is a dash. Never heard and heard as zero are
     * different values, and a vessel nobody has a CPA for has not reported a
     * CPA of nothing.
     */
    @Test fun aMissingCellIsADashAndNotAZero() {
        show()
        compose.onNodeWithText("ZULU").assertIsDisplayed()
        assertTrue(compose.onAllNodes(hasText("—")).fetchSemanticsNodes().size >= 3)
    }

    @Test fun aFlagReadsAsAWord() {
        show()
        compose.onNodeWithText("ALARM").assertIsDisplayed()
    }

    // ---- finding a row on the chart -----------------------------------------

    /** Tapping a row centres the chart on it. */
    @Test fun aRowWithAPositionRevealsItOnTheChart() {
        show()
        compose.onNodeWithText("ANNE").performClick()
        compose.waitForIdle()
        assertEquals(-76.481, revealed!!.first, 1e-9)
        assertEquals(38.974, revealed!!.second, 1e-9)
    }

    /** A table may declare `at` and still hold a row nobody has heard a
     *  position from, and that row must not offer a tap that does nothing. */
    @Test fun aRowWithNoPositionRevealsNothing() {
        show()
        compose.onNodeWithText("ZULU").performClick()
        compose.waitForIdle()
        assertNull(revealed)
    }

    /** A table that declared no position has no rows to find at all. */
    @Test fun aTableWithNoPositionColumnRevealsNothing() {
        show(spec = ais.copy(locatable = false))
        compose.onNodeWithText("ANNE").performClick()
        compose.waitForIdle()
        assertNull(revealed)
    }

    // ---- nothing to show ----------------------------------------------------

    /**
     * The plugin builds no rows until somebody is looking, so the first read
     * finds none. An empty table says so rather than showing a bare grid.
     */
    @Test fun anEmptyTableSaysSo() {
        show(rows = null)
        compose.onNodeWithText("Nothing to show yet.").assertIsDisplayed()
    }

    @Test fun aTableWhosePluginWentSaysTheSame() {
        show(rows = TableBatch(0, emptyList()))
        compose.onNodeWithText("Nothing to show yet.").assertIsDisplayed()
    }

    @Test fun theTableCloses() {
        show()
        compose.onNodeWithText("Close").performClick()
        compose.waitForIdle()
        assertTrue(closed)
    }
}
