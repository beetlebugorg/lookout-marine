package org.beetlebug.lookout

import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.plugins.AlertBanner
import org.beetlebug.lookout.plugins.PluginAlert
import org.beetlebug.lookout.plugins.PluginAlertSeverity

import androidx.compose.foundation.layout.Box
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The alerts over the chart.
 *
 * AN ALARM IS AUDIBLE AND A WARNING IS VISIBLE, and acknowledging silences ONE
 * alert: the mariner who has seen the vessel crossing ahead has not seen the
 * one coming up astern. The banner also covers water, so what it must never do
 * is grow: during a collision alarm the target it names is on the chart
 * underneath it.
 */
@RunWith(AndroidJUnit4::class)
class AlertBannerTest {

    @get:Rule val compose = createComposeRule()

    private fun alert(
        id: Long,
        title: String,
        body: String = "",
        severity: PluginAlertSeverity = PluginAlertSeverity.ALARM,
        acknowledged: Boolean = false,
    ) = PluginAlert(
        id = id, plugin = "org.beetlebug.ais", severity = severity,
        title = title, body = body, raised = 0L, acknowledged = acknowledged,
    )

    private var answered: PluginAlert? = null

    private fun show(alerts: List<PluginAlert>) {
        answered = null
        compose.setContent {
            LookoutTheme(dark = false) {
                Box { AlertBanner(alerts = alerts, onAcknowledge = { answered = it }) }
            }
        }
    }

    // ---- what is shown ------------------------------------------------------

    @Test fun anUnansweredAlarmIsOnTheChart() {
        show(listOf(alert(1, "AIS CPA alarm", "ANNE: CPA 124 m in 585 s")))
        compose.onNodeWithText("AIS CPA alarm").assertIsDisplayed()
        compose.onNodeWithText("ANNE: CPA 124 m in 585 s").assertIsDisplayed()
    }

    /** Nothing to answer means nothing over the water. */
    @Test fun noAlertsIsNoBanner() {
        show(emptyList())
        compose.onAllNodes(hasText("Acknowledge")).assertCountEquals(0)
    }

    /**
     * Acknowledging takes a row off the chart. What is still dangerous after
     * that is the chart's to show: the target stays red and carries its own
     * state when it is tapped.
     */
    @Test fun anAcknowledgedAlertLeavesTheChart() {
        show(listOf(alert(1, "AIS CPA alarm", acknowledged = true)))
        compose.onAllNodes(hasText("AIS CPA alarm")).assertCountEquals(0)
    }

    @Test fun anAcknowledgedAlertDoesNotHideAnUnansweredOne() {
        show(
            listOf(
                alert(1, "Answered already", acknowledged = true),
                alert(2, "Still ringing"),
            )
        )
        compose.onAllNodes(hasText("Answered already")).assertCountEquals(0)
        compose.onNodeWithText("Still ringing").assertIsDisplayed()
    }

    // ---- how much water it may cover ----------------------------------------

    /**
     * Two rows, and the rest counted on one line. The strip must not cover the
     * water the mariner is reading, least of all during a collision alarm.
     */
    @Test fun onlyTwoAlertsAreShownAndTheRestAreCounted() {
        show(
            listOf(
                alert(1, "First alarm"),
                alert(2, "Second alarm"),
                alert(3, "Third alarm"),
                alert(4, "Fourth alarm"),
            )
        )
        compose.onNodeWithText("First alarm").assertIsDisplayed()
        compose.onNodeWithText("Second alarm").assertIsDisplayed()
        compose.onAllNodes(hasText("Third alarm")).assertCountEquals(0)
        compose.onNodeWithText("2 more").assertIsDisplayed()
    }

    /** Exactly two fits, so nothing is counted. */
    @Test fun twoAlertsNeedNoOverflowLine() {
        show(listOf(alert(1, "First alarm"), alert(2, "Second alarm")))
        compose.onAllNodes(hasText("more", substring = true)).assertCountEquals(0)
    }

    /** The count is of what is UNANSWERED, not of everything raised. */
    @Test fun theOverflowCountsOnlyWhatStillNeedsAnswering() {
        show(
            listOf(
                alert(1, "First alarm"),
                alert(2, "Second alarm"),
                alert(3, "Third alarm"),
                alert(4, "Answered", acknowledged = true),
                alert(5, "Also answered", acknowledged = true),
            )
        )
        compose.onNodeWithText("1 more").assertIsDisplayed()
    }

    // ---- silencing one, and only one ----------------------------------------

    /**
     * THE ONE THAT MATTERS. A control that silenced every alert would hide the
     * second vessel. Each row answers for itself.
     */
    @Test fun acknowledgingAnswersThatRowAndNoOther() {
        val first = alert(1, "Crossing ahead")
        val second = alert(2, "Overtaking astern")
        show(listOf(first, second))

        // The rows are in the core's order, so the first Acknowledge is the
        // first alert's.
        compose.onAllNodes(hasText("Acknowledge")).assertCountEquals(2)
        compose.onAllNodes(hasText("Acknowledge"))[0].performClick()
        compose.waitForIdle()

        assertEquals(first.id, answered?.id)
    }

    @Test fun theSecondRowAnswersForItself() {
        val first = alert(1, "Crossing ahead")
        val second = alert(2, "Overtaking astern")
        show(listOf(first, second))

        compose.onAllNodes(hasText("Acknowledge"))[1].performClick()
        compose.waitForIdle()

        assertEquals(second.id, answered?.id)
    }

    @Test fun nothingIsAnsweredUntilSomethingIsPressed() {
        show(listOf(alert(1, "Crossing ahead")))
        assertNull(answered)
    }

    // ---- severity -----------------------------------------------------------

    /** A warning is shown and never sounded, and it is still answerable. */
    @Test fun aWarningIsShownBesideAnAlarm() {
        show(
            listOf(
                alert(1, "AIS CPA alarm", severity = PluginAlertSeverity.ALARM),
                alert(2, "Gateway unreachable", severity = PluginAlertSeverity.WARNING),
            )
        )
        compose.onNodeWithText("AIS CPA alarm").assertIsDisplayed()
        compose.onNodeWithText("Gateway unreachable").assertIsDisplayed()
    }

    @Test fun aNoticeIsShownToo() {
        show(listOf(alert(1, "Forecast is 9 hours old", severity = PluginAlertSeverity.NOTICE)))
        compose.onNodeWithText("Forecast is 9 hours old").assertIsDisplayed()
    }

    /** An alert with no body is still a row: the title is the alarm. */
    @Test fun anAlertWithNoBodyIsStillARow() {
        show(listOf(alert(1, "Anchor dragging")))
        compose.onNodeWithText("Anchor dragging").assertIsDisplayed()
        compose.onAllNodes(hasText("Acknowledge")).assertCountEquals(1)
    }
}
