package org.beetlebug.lookout

import org.beetlebug.lookout.chart.ChartMenuPanel
import org.beetlebug.lookout.chart.ChartController
import org.beetlebug.lookout.chart.GoToCoordinateDialog
import org.beetlebug.lookout.chart.MarkerRenameDialog
import org.beetlebug.lookout.chart.ScaleEntryDialog
import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.pick.AuxFile
import org.beetlebug.lookout.pick.AuxFileDialog

import androidx.compose.foundation.layout.Box
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The dialogs the chart raises: go to a position, zoom to a scale, the
 * long-press menu, renaming a mark, and a file the chart itself carries.
 */
@RunWith(AndroidJUnit4::class)
class DialogsTest {

    @get:Rule val compose = createComposeRule()

    // ---- go to a coordinate -------------------------------------------------

    private var went: Pair<Double, Double>? = null

    private fun goTo() {
        went = null
        compose.setContent {
            LookoutTheme(dark = false) {
                GoToCoordinateDialog(onDismiss = {}, onGo = { lat, lon -> went = lat to lon })
            }
        }
    }

    /** Nothing typed is not a position, so Go stays shut. */
    @Test fun goIsRefusedUntilThePositionParses() {
        goTo()
        compose.onNodeWithText("Go").assertIsNotEnabled()
        compose.onNodeWithText("Latitude and longitude").performTextInput("38.9763, -76.4767")
        compose.waitForIdle()
        compose.onNodeWithText("Go").assertIsEnabled()
    }

    @Test fun aParsedPositionIsHandedOverLatitudeFirst() {
        goTo()
        compose.onNodeWithText("Latitude and longitude").performTextInput("38.9763, -76.4767")
        compose.waitForIdle()
        compose.onNodeWithText("Go").performClick()
        compose.waitForIdle()
        assertEquals(38.9763, went!!.first, 1e-9)
        assertEquals(-76.4767, went!!.second, 1e-9)
    }

    /** Nonsense is marked, not accepted. */
    @Test fun nonsenseKeepsGoShut() {
        goTo()
        compose.onNodeWithText("Latitude and longitude").performTextInput("Annapolis")
        compose.waitForIdle()
        compose.onNodeWithText("Go").assertIsNotEnabled()
    }

    // ---- zoom to a scale ----------------------------------------------------

    private var zoomed: Double? = null

    private fun scaleEntry(current: Double = 13_267.0) {
        zoomed = null
        compose.setContent {
            LookoutTheme(dark = false) {
                ScaleEntryDialog(current = current, onDismiss = {}, onZoomToScale = { zoomed = it })
            }
        }
    }

    /** The field opens on the scale the chart is already at. */
    @Test fun theEntryOpensOnTheCurrentScale() {
        scaleEntry()
        compose.onNodeWithText("13267").assertIsDisplayed()
    }

    /**
     * The bands are offered as chips so a mariner picks a purpose rather than
     * a number.
     */
    @Test fun theBandsAreOfferedAsChips() {
        scaleEntry()
        for (band in listOf("Berthing", "Harbor", "Approach", "Coastal", "General")) {
            compose.onNodeWithText(band).assertIsDisplayed()
        }
    }

    @Test fun aBandChipFillsInItsScale() {
        scaleEntry()
        compose.onNodeWithText("Harbor").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("12000").assertIsDisplayed()
    }

    @Test fun aTypedScaleIsHandedOver() {
        scaleEntry()
        compose.onNodeWithText("13267").performTextReplacement("1:25,000")
        compose.waitForIdle()
        compose.onNodeWithText("Zoom").performClick()
        compose.waitForIdle()
        assertEquals(25_000.0, zoomed!!, 0.0)
    }

    /** No chart is 1:5. */
    @Test fun aScaleOutsideTheSaneRangeKeepsZoomShut() {
        scaleEntry()
        compose.onNodeWithText("13267").performTextReplacement("5")
        compose.waitForIdle()
        compose.onNodeWithText("Zoom").assertIsNotEnabled()
    }

    // ---- the long-press menu ------------------------------------------------

    private fun chartMenu(markerId: Long = 0L, markerName: String = "") {
        compose.setContent {
            LookoutTheme(dark = false) {
                Box {
                    ChartMenuPanel(
                        menu = ChartController.ChartMenu(
                            at = Offset(200f, 300f),
                            lon = -76.4767, lat = 38.9763,
                            markerId = markerId, markerName = markerName,
                        ),
                        onPick = {}, onDropMarker = {}, onRenameMarker = {},
                        onRemoveMarker = {}, onDismiss = {},
                    )
                }
            }
        }
    }

    /** The header says WHERE, so a position can be read or copied without
     *  opening anything. */
    @Test fun theMenuHeaderCarriesThePosition() {
        chartMenu()
        compose.onNodeWithText("38°58.578'N 076°28.602'W").assertIsDisplayed()
        compose.onNodeWithText("Copy position").assertIsDisplayed()
    }

    /** Over open water the menu drops a mark. */
    @Test fun overWaterTheMenuDropsAMark() {
        chartMenu()
        compose.onNodeWithText("Drop marker").assertIsDisplayed()
        compose.onAllNodes(hasText("Rename marker")).assertCountEquals(0)
        compose.onAllNodes(hasText("Remove marker")).assertCountEquals(0)
    }

    /** Over a mark it renames and removes instead. */
    @Test fun overAMarkTheMenuRenamesAndRemoves() {
        chartMenu(markerId = 7L, markerName = "Mark 1")
        compose.onNodeWithText("Mark 1").assertIsDisplayed()
        compose.onNodeWithText("Rename marker").assertIsDisplayed()
        compose.onNodeWithText("Remove marker").assertIsDisplayed()
        compose.onAllNodes(hasText("Drop marker")).assertCountEquals(0)
    }

    @Test fun theMenuAlwaysOffersThePickReport() {
        chartMenu()
        compose.onNodeWithText("Pick report").assertIsDisplayed()
    }

    // ---- renaming a mark ----------------------------------------------------

    @Test fun aRenameOpensOnTheCurrentNameAndCommitsTheNewOne() {
        var committed: String? = null
        compose.setContent {
            LookoutTheme(dark = false) {
                MarkerRenameDialog(current = "Mark 1", onCommit = { committed = it }, onCancel = {})
            }
        }
        compose.onNodeWithText("Mark 1").assertIsDisplayed()
        compose.onNodeWithText("Mark 1").performTextReplacement("Anchorage")
        compose.waitForIdle()
        compose.onNodeWithText("Rename").performClick()
        compose.waitForIdle()
        assertEquals("Anchorage", committed)
    }

    /** The core clips at 32 characters, and so does the field. */
    @Test fun aNameIsClippedInTheFieldAsWellAsInTheCore() {
        compose.setContent {
            LookoutTheme(dark = false) {
                MarkerRenameDialog(current = "", onCommit = {}, onCancel = {})
            }
        }
        val long = "a".repeat(40)
        compose.onNodeWithText("").performTextInput(long)
        compose.waitForIdle()
        compose.onAllNodes(hasText(long)).assertCountEquals(0)
    }

    // ---- a file the chart carries -------------------------------------------

    /** A TXTDSC chart note is shown whole. */
    @Test fun aTextFileIsShownAsText() {
        val note = "Anchoring prohibited within 100 metres of the cable crossing."
        compose.setContent {
            LookoutTheme(dark = false) {
                AuxFileDialog(
                    file = AuxFile("US5MD1MC.TXT", note.toByteArray(), "text/plain"),
                    onDismiss = {},
                )
            }
        }
        compose.onNodeWithText("US5MD1MC.TXT").assertIsDisplayed()
        compose.onNodeWithText(note).assertIsDisplayed()
    }

    /** Bytes that are neither a picture nor readable text say so rather than
     *  showing an empty pane. */
    @Test fun anUnreadableFileSaysSo() {
        compose.setContent {
            LookoutTheme(dark = false) {
                AuxFileDialog(file = AuxFile("EMPTY.TXT", ByteArray(0), ""), onDismiss = {})
            }
        }
        compose.onNodeWithText("The chart does not carry this file.").assertIsDisplayed()
    }

    @Test fun theFileDialogCloses() {
        var closed = false
        compose.setContent {
            LookoutTheme(dark = false) {
                AuxFileDialog(file = AuxFile("A.TXT", "x".toByteArray(), ""), onDismiss = { closed = true })
            }
        }
        compose.onNodeWithText("Close").performClick()
        compose.waitForIdle()
        assertTrue(closed)
    }
}
