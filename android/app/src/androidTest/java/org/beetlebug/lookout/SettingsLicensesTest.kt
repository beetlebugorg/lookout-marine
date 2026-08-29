package org.beetlebug.lookout

import org.beetlebug.lookout.chart.ChartController
import org.beetlebug.lookout.charts.ChartsModel
import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.licenses.LicenseManifest
import org.beetlebug.lookout.settings.MarinerState
import org.beetlebug.lookout.settings.SettingsSheet

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The way in to the licenses, through the settings the mariner actually opens.
 *
 * The route is Mariner Settings > Advanced > About, the same one every other
 * shell uses. What differs between a phone and a tablet is where the licenses
 * land: a phone has no room for two columns, so they take the sheet and the
 * section list is left behind; a tablet is wide enough for both, and the list
 * must stay beside them — the list IS the navigation, and a sheet with it
 * hidden has no way back to another section.
 *
 * Both cases run from the same test: the device decides which one applies, the
 * way the sheet itself decides.
 */
@RunWith(AndroidJUnit4::class)
class SettingsLicensesTest {

    @get:Rule val compose = createComposeRule()

    /** The same threshold the sheet uses to choose two panes. */
    private val twoPane: Boolean
        get() = InstrumentationRegistry.getInstrumentation()
            .targetContext.resources.configuration.screenWidthDp >= 600

    /** The settings, open on Advanced, where the About section lives. */
    private fun openAdvanced() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        compose.setContent {
            LookoutTheme {
                SettingsSheet(
                    m = MarinerState(),
                    charts = ChartsModel(ctx, null),
                    controller = ChartController(ctx),
                    onRequestAccess = {},
                    onDismiss = {},
                    initialSection = "advanced",
                )
            }
        }
        // A phone opens on the section list, so Advanced has to be chosen; a
        // tablet already shows it beside the list.
        compose.waitForIdle()
        if (!twoPane) compose.onNodeWithText("Advanced").performClick()
        compose.onNodeWithText("SAFETY & QUALITY").assertIsDisplayed()
    }

    /**
     * The pane scrolls, and About is at the foot of Advanced. The row that
     * opens the licences is the last of them, so scrolling to the heading
     * leaves it off screen and a tap on it lands nowhere.
     */
    private fun scrollToAbout() {
        compose.waitForIdle()
        compose.onNodeWithTag("about-licenses").performScrollTo()
    }

    private fun openLicenses() {
        scrollToAbout()
        compose.onNodeWithTag("about-licenses").performClick()
        compose.waitForIdle()
    }

    private fun back() = compose.onNodeWithContentDescription("Back")


    /** Every row of the About section, and the count it promises. */
    @Test fun theAboutSectionCarriesTheVersionEngineAndLicencesRow() {
        openAdvanced()
        val count = LicenseManifest.current?.components?.size ?: 0
        assertTrue("the baked licence list would not parse", count > 0)

        scrollToAbout()
        compose.onNodeWithText("Version").assertIsDisplayed()
        compose.onNodeWithText("Chart engine").assertIsDisplayed()
        compose.onNodeWithText("Licenses").assertIsDisplayed()
        compose.onNodeWithText("$count components").assertIsDisplayed()
    }

    /** The row opens the list, and Back comes home to Advanced. */
    @Test fun theLicencesRowOpensTheListAndBackReturns() {
        openAdvanced()
        openLicenses()

        compose.onNodeWithText("THIS APP").assertIsDisplayed()
        compose.onNodeWithTag("licenses-list").assertIsDisplayed()

        back().performClick()
        compose.onNodeWithText("SAFETY & QUALITY").assertIsDisplayed()
    }

    /** A row opens its terms, and Back returns to the list rather than out. */
    @Test fun aRowOpensItsTermsAndBackReturnsToTheList() {
        openAdvanced()
        openLicenses()

        compose.onNodeWithTag("licenses-list").performScrollToNode(hasText("zlib"))
        compose.onNodeWithText("zlib").performClick()
        compose.onNodeWithText("Upstream").assertIsDisplayed()

        back().performClick()
        compose.onNodeWithText("THIS APP").assertIsDisplayed()
    }

    /**
     * A tablet keeps the section list beside the licences; a phone does not.
     * One test, decided by the device, because that is how the sheet decides.
     */
    @Test fun theSectionListStaysBesideTheLicencesOnlyWhereThereIsRoomForIt() {
        openAdvanced()
        openLicenses()
        compose.onNodeWithText("THIS APP").assertIsDisplayed()

        // "Display" is a row of the section list and of nothing else.
        val sections = compose.onAllNodes(hasText("Display")).fetchSemanticsNodes()
        if (twoPane) {
            assertTrue(
                "the section list vanished when the licences opened on a tablet",
                sections.isNotEmpty(),
            )
            // Beside, not over: the list ends before the licences begin.
            val listRight = sections.first().boundsInRoot.right
            val licences = compose.onNodeWithTag("licenses-list").fetchSemanticsNode()
            assertTrue(
                "the licences are drawn over the section list " +
                    "(list ends at $listRight, licences begin at ${licences.boundsInRoot.left})",
                licences.boundsInRoot.left >= listRight,
            )
        } else {
            assertTrue(
                "the section list is still on screen behind the licences on a phone",
                sections.isEmpty(),
            )
        }
    }
}
