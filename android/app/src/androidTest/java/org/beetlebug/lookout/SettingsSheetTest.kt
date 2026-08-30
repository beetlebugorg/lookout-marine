package org.beetlebug.lookout

import org.beetlebug.lookout.charts.ChartLinkController
import org.beetlebug.lookout.charts.ChartsModel
import org.beetlebug.lookout.charts.RasterCharts
import org.beetlebug.lookout.charts.RasterController
import org.beetlebug.lookout.engine.EngineAccess
import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.plugins.PluginSettingsController
import org.beetlebug.lookout.plugins.TableController
import org.beetlebug.lookout.settings.MI
import org.beetlebug.lookout.settings.MarinerState
import org.beetlebug.lookout.settings.Scheme
import org.beetlebug.lookout.settings.SettingsSheet

import android.content.Context
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The mariner's settings, driven on a device.
 *
 * The sheet takes the four controllers it uses rather than a whole
 * `ChartController`, so it composes with no engine behind it and no chart open.
 * That is the whole reason for the seam: before it, none of this could be shown
 * at all without a live handle and a render thread.
 *
 * What is checked here is the PRODUCT: which sections exist and in what order,
 * that each one's controls move the mariner state, and that the two-pane and
 * pushed layouts differ only in navigation. The wording is shared with every
 * other shell, so a changed string here is a changed string there.
 */
@RunWith(AndroidJUnit4::class)
class SettingsSheetTest {

    @get:Rule val compose = createComposeRule()

    private val ctx: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    /** The same threshold the sheet uses to choose two panes. */
    private val twoPane: Boolean
        get() = ctx.resources.configuration.screenWidthDp >= 600

    private lateinit var mariner: MarinerState

    private fun open(section: String?) {
        mariner = MarinerState()
        compose.setContent {
            LookoutTheme(dark = false) {
                val access = EngineAccess()
                SettingsSheet(
                    m = mariner,
                    charts = ChartsModel(ctx, null),
                    plugins = PluginSettingsController(ctx, access) {},
                    tables = TableController(access) { _, _ -> },
                    links = ChartLinkController(ctx, access),
                    raster = RasterController(access, RasterCharts(ctx)),
                    onRequestAccess = {},
                    onDismiss = {},
                    initialSection = section,
                )
            }
        }
        compose.waitForIdle()
    }

    /** A phone opens on the section list and has to be pushed into a section. */
    private fun openSection(name: String, id: String) {
        open(id)
        if (!twoPane) compose.onNodeWithText(name).performClick()
        compose.waitForIdle()
    }

    // ---- the sections -------------------------------------------------------

    /**
     * The core sections are always listed, whatever the plugins did. With no
     * plugin layer up — which is this build, and any build whose plugins failed
     * — Vessels, Alarms and Connections stay away rather than standing empty.
     */
    @Test fun theCoreSectionsAreAlwaysListed() {
        open(null)
        for (name in listOf("Display", "Depths", "Text", "Charts", "Plugins", "Advanced")) {
            // A tablet shows the name twice: the list row and the pane title.
            assertTrue(name, compose.onAllNodes(hasText(name)).fetchSemanticsNodes().isNotEmpty())
        }
    }

    @Test fun aSectionNoPluginFillsIsNotListed() {
        open(null)
        for (name in listOf("Vessels", "Alarms", "Connections")) {
            compose.onAllNodes(hasText(name)).assertCountEquals(0)
        }
    }

    // ---- Display ------------------------------------------------------------

    @Test fun theDisplaySectionOffersTheThreeSchemes() {
        openSection("Display", "display")
        compose.onNodeWithText("COLOUR SCHEME").assertIsDisplayed()
        for (s in Scheme.entries) compose.onNodeWithText(s.label).assertIsDisplayed()
    }

    /** Night keeps the mariner's eyes dark-adapted, so picking it has to take. */
    @Test fun pickingASchemeSetsIt() {
        openSection("Display", "display")
        compose.onNodeWithText("Night").performClick()
        compose.waitForIdle()
        assertEquals(Scheme.NIGHT, mariner.scheme)
    }

    /**
     * Each display category contains the one before it, so choosing Other must
     * leave Base and Standard on. The sheet offers one choice over three flags.
     */
    @Test fun choosingADisplayCategorySetsTheNestedFlags() {
        openSection("Display", "display")
        compose.onNodeWithText("Other").performClick()
        compose.waitForIdle()
        assertTrue(mariner.flag(MI.DISPLAY_BASE))
        assertTrue(mariner.flag(MI.DISPLAY_STANDARD))
        assertTrue(mariner.flag(MI.DISPLAY_OTHER))
    }

    /** The described-row pattern: every choice carries the sentence that says
     *  what picking it does. */
    @Test fun everyChoiceCarriesItsSentence() {
        openSection("Display", "display")
        compose.onNodeWithText("Coastline, safety contour, dangers and traffic lanes — never hidden")
            .assertIsDisplayed()
    }

    // ---- Depths -------------------------------------------------------------

    @Test fun theDepthsSectionShowsTheContoursInMetres() {
        openSection("Depths", "depths")
        compose.onNodeWithText("Safety contour").assertIsDisplayed()
        compose.onNodeWithText("Safety depth").assertIsDisplayed()
        compose.onNodeWithText("DEPTH UNIT").assertIsDisplayed()
    }

    /**
     * Two shades hides the shallow and deep contours, because with one
     * threshold they mean nothing. Four brings them back.
     */
    @Test fun theShallowAndDeepContoursFollowTheShadingChoice() {
        openSection("Depths", "depths")
        compose.onNodeWithText("Two shades").performClick()
        compose.waitForIdle()
        compose.onAllNodes(hasText("Shallow contour")).assertCountEquals(0)
        compose.onAllNodes(hasText("Deep contour")).assertCountEquals(0)

        compose.onNodeWithText("Four shades").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Shallow contour").assertIsDisplayed()
        compose.onNodeWithText("Deep contour").assertIsDisplayed()
    }

    /**
     * THE ENGINE ALWAYS TAKES METRES. Feet mode changes the labels and edits
     * through a conversion; sending "ft" numbers straight through as metres was
     * a real bug once.
     */
    @Test fun feetModeChangesTheLabelAndNotTheStoredUnit() {
        openSection("Depths", "depths")
        val before = mariner.safetyContour
        compose.onNodeWithText("Feet").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("CONTOURS (FT)").assertIsDisplayed()
        assertEquals("switching the unit must not move the contour", before, mariner.safetyContour, 1e-9)
    }

    /**
     * A contour is TYPED, not stepped to. It follows the boat's draught rather
     * than the last value, so the usual change is a large one and twenty taps
     * on a stepper is the wrong way to make it.
     */
    @Test fun aContourCanBeTypedStraightIn() {
        openSection("Depths", "depths")
        compose.onNodeWithTag("settings-pane").performScrollToNode(hasText("Safety contour"))
        safetyField().performTextReplacement("30")
        // Done is the commit. Writing through per keystroke would send "3"
        // to the engine on the way to "30" and shade the chart for it.
        safetyField().performImeAction()
        compose.waitForIdle()
        assertEquals(30.0, mariner.safetyContour, 1e-6)
    }

    /** Out of range clamps rather than being refused: 900 m is not a contour,
     *  and the deepest charted one is the honest answer. */
    @Test fun aTypedContourIsClampedToWhatACanCarry() {
        openSection("Depths", "depths")
        compose.onNodeWithTag("settings-pane").performScrollToNode(hasText("Safety contour"))
        safetyField().performTextReplacement("900")
        safetyField().performImeAction()
        compose.waitForIdle()
        assertEquals(660.0, mariner.safetyContour, 1e-6)
    }

    /**
     * Nonsense goes back to what is in force. A half-typed contour must never
     * land as a zero, which would shade the chart as if the water were safe
     * everywhere.
     */
    @Test fun anUnreadableContourFallsBackRatherThanZeroing() {
        openSection("Depths", "depths")
        compose.onNodeWithTag("settings-pane").performScrollToNode(hasText("Safety contour"))
        val before = mariner.safetyContour
        safetyField().performTextReplacement("")
        safetyField().performImeAction()
        compose.waitForIdle()
        assertEquals(before, mariner.safetyContour, 1e-9)
    }

    /** The steppers stay, for a nudge of a metre. */
    @Test fun aContourStepsInWholeUnits() {
        openSection("Depths", "depths")
        val before = mariner.safetyContour
        compose.onNodeWithContentDescriptionSafe("Increase Safety contour")
        compose.waitForIdle()
        assertEquals(before + 1.0, mariner.safetyContour, 1e-9)
    }

    /** The field for the safety contour, which is the row every branch of the
     *  Depths section shows. */
    private fun safetyField() = compose.onNodeWithTag("depth-Safety contour")

    // ---- Text ---------------------------------------------------------------

    @Test fun theTextSectionTogglesWhatIsWrittenOnTheChart() {
        openSection("Text", "text")
        compose.onNodeWithText("Feature names").assertIsDisplayed()
        compose.onNodeWithText("Light descriptions").assertIsDisplayed()
        compose.onNodeWithText("Simplified point symbols").assertIsDisplayed()

        val before = mariner.flag(MI.TEXT_NAMES)
        compose.onNodeWithText("Feature names").performClick()
        compose.waitForIdle()
        assertEquals(!before, mariner.flag(MI.TEXT_NAMES))
    }

    // ---- Advanced -----------------------------------------------------------

    @Test fun theAdvancedSectionCarriesSafetySizingAndDates() {
        openSection("Advanced", "advanced")
        compose.onNodeWithText("SAFETY & QUALITY").assertIsDisplayed()
        compose.onNodeWithText("Data quality overlay").assertIsDisplayed()
        compose.onNodeWithText("SIZING").assertIsDisplayed()
        compose.onNodeWithText("Symbols & lines").assertIsDisplayed()
    }

    @Test fun anAdvancedToggleTakes() {
        openSection("Advanced", "advanced")
        val before = mariner.flag(MI.DATA_QUALITY)
        compose.onNodeWithText("Data quality overlay").performClick()
        compose.waitForIdle()
        assertEquals(!before, mariner.flag(MI.DATA_QUALITY))
    }

    /** About sits at the foot of Advanced, where every other shell puts it. */
    @Test fun aboutIsAtTheFootOfAdvanced() {
        openSection("Advanced", "advanced")
        compose.onNodeWithTag("about-licenses").performScrollTo()
        compose.onNodeWithText("Version").assertIsDisplayed()
        compose.onNodeWithText("Licenses").assertIsDisplayed()
    }

    // ---- Charts -------------------------------------------------------------

    /** Which chart DRAWS is the tab's headline decision, so the picker leads. */
    @Test fun theChartsSectionLeadsWithTheChartChoice() {
        openSection("Charts", "charts")
        compose.onNodeWithText("CHART").assertIsDisplayed()
        compose.onNodeWithText("Lookout chart").assertIsDisplayed()
        compose.onNodeWithText("The built-in portrayal of your opened cells.").assertIsDisplayed()
    }

    /**
     * Charts are read where they lie, so the library needs read access outside
     * the app's own folder. Without it the pane says so and offers the grant
     * rather than showing an empty browser.
     */
    @Test fun theChartsSectionAsksForAccessBeforeShowingALibrary() {
        openSection("Charts", "charts")
        compose.onNodeWithTag("settings-pane").performScrollToNode(hasText("Grant file access"))
        compose.onNodeWithText("Grant file access").assertIsDisplayed()
        compose.onNode(hasText("nothing is copied", substring = true)).assertIsDisplayed()
    }

    // ---- Plugins ------------------------------------------------------------

    /**
     * The bundled set is the product, not something the mariner manages, so
     * with nothing installed the section says so rather than standing empty.
     */
    @Test fun thePluginsSectionSaysWhenNothingIsInstalled() {
        openSection("Plugins", "plugins")
        compose.onNodeWithText("INSTALLED PLUGINS").assertIsDisplayed()
        compose.onNode(hasText("No plugins installed", substring = true)).assertIsDisplayed()
        compose.onNodeWithText("Nothing is installed before its permissions are shown.")
            .assertIsDisplayed()
    }

    // ---- navigation ---------------------------------------------------------

    /**
     * A phone pushes and a tablet shows both at once. The list IS the
     * navigation, so on a tablet it must stay beside the pane.
     */
    @Test fun theSectionListStaysBesideThePaneOnlyWhereThereIsRoom() {
        openSection("Depths", "depths")
        val listRows = compose.onAllNodes(hasText("Display")).fetchSemanticsNodes()
        if (twoPane) {
            assertTrue("the section list went away on a tablet", listRows.isNotEmpty())
        } else {
            assertTrue("the section list is still behind the pane on a phone", listRows.isEmpty())
        }
    }
}

/** performClick on a content description, without failing the whole file when
 *  the control is off screen. */
private fun androidx.compose.ui.test.junit4.ComposeContentTestRule
    .onNodeWithContentDescriptionSafe(description: String) {
    onNode(androidx.compose.ui.test.hasContentDescription(description)).performClick()
}
