package org.beetlebug.lookout

import org.beetlebug.lookout.plugins.PluginAlertSet
import org.beetlebug.lookout.plugins.PluginAlertSeverity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse

import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The alerts the plugins raise.
 *
 * An alarm is audible and a warning is visible; that is the whole of what
 * severity means. The rules that matter here are the two that decide whether a
 * mariner hears a collision alarm at all: an unreadable payload is "the core
 * said nothing", never "there are no alerts", and a severity this build does
 * not recognise is an alarm. Silence is never the fallback.
 */
@RunWith(RobolectricTestRunner::class)
class PluginAlertsParseTest {

    private val set = requireNotNull(PluginAlertSet.decode(PluginFixture.alertSet))

    @Test fun theSetCarriesItsSeqAndEveryAlert() {
        assertEquals(47L, set.seq)
        assertEquals(listOf(9001L, 9002L, 9003L, 9004L), set.alerts.map { it.id })
    }

    /** The core has already ordered them; the shell must not reorder. */
    @Test fun theOrderIsTheCoresOwn() {
        assertEquals(
            listOf("AIS CPA alarm", "AIS CPA alarm", "Gateway unreachable", "Forecast is 9 hours old"),
            set.alerts.map { it.title },
        )
    }

    @Test fun everyFieldIsRead() {
        val a = set.alerts[0]
        assertEquals("org.beetlebug.ais", a.plugin)
        assertEquals(PluginAlertSeverity.ALARM, a.severity)
        assertEquals("ANNE: CPA 124 m in 585 s", a.body)
        assertEquals(1_756_400_000_000L, a.raised)
        assertFalse(a.acknowledged)
        assertTrue(set.alerts[3].acknowledged)
    }

    // ---- severity -----------------------------------------------------------

    @Test fun eachSeverityIsRead() {
        assertEquals(PluginAlertSeverity.ALARM, set.alerts[0].severity)
        assertEquals(PluginAlertSeverity.WARNING, set.alerts[2].severity)
        assertEquals(PluginAlertSeverity.NOTICE, set.alerts[3].severity)
    }

    /** Only an alarm sounds. A warning is shown and never heard. */
    @Test fun onlyAnAlarmIsAudible() {
        assertTrue(PluginAlertSeverity.ALARM.audible)
        assertFalse(PluginAlertSeverity.WARNING.audible)
        assertFalse(PluginAlertSeverity.NOTICE.audible)
    }

    /**
     * A severity this build does not know is treated as an alarm, the same way
     * the core treats one it cannot read. Guessing quieter would silence
     * something a newer plugin meant to be heard.
     */
    @Test fun anUnknownSeverityIsAnAlarm() {
        assertEquals(PluginAlertSeverity.ALARM, PluginAlertSeverity.of(7))
        assertEquals(PluginAlertSeverity.ALARM, PluginAlertSeverity.of(-1))
    }

    // ---- what it refuses ----------------------------------------------------

    /**
     * THE IMPORTANT ONE. Null means the core said nothing, and the caller keeps
     * sampling. An empty list would mean the alarms had cleared, which would
     * take a sounding alarm off the chart because a read failed once.
     */
    @Test fun anUnreadableReadIsNullAndNotAnEmptySet() {
        assertNull(PluginAlertSet.decode(null))
        assertNull(PluginAlertSet.decode(emptyArray()))
        assertNull(PluginAlertSet.decode(arrayOf("not a seq")))
    }

    /** A readable payload with nothing in it IS an empty set. */
    @Test fun anEmptySetIsReadAsEmpty() {
        val empty = requireNotNull(PluginAlertSet.decode(PluginFixture.alerts(0)))
        assertEquals(0L, empty.seq)
        assertTrue(empty.alerts.isEmpty())
    }

    /** An alert with no words is not an alert. */
    @Test fun anAlertWithNoTitleIsSkipped() {
        val s = PluginAlertSet.decode(PluginFixture.alerts(
            1,
            PluginFixture.alert(1, "x", PluginFixture.SEVERITY_ALARM, ""),
            PluginFixture.alert(2, "x", PluginFixture.SEVERITY_ALARM, "Real"),
        ))!!
        assertEquals(listOf(2L), s.alerts.map { it.id })
    }

    /** A row cut short is dropped rather than read across the next alert. */
    @Test fun aShortRowIsDropped() {
        val flat = PluginFixture.alertSet.copyOfRange(0, 12)
        assertEquals(listOf(9001L), PluginAlertSet.decode(flat)!!.alerts.map { it.id })
    }

    @Test fun anAlertWithNoBodyReadsAsEmpty() {
        val s = PluginAlertSet.decode(PluginFixture.alerts(
            1, PluginFixture.alert(1, "x", PluginFixture.SEVERITY_ALARM, "T"),
        ))!!
        assertEquals("", s.alerts.single().body)
        assertFalse(s.alerts.single().acknowledged)
    }
}
