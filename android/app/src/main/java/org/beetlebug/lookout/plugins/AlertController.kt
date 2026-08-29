package org.beetlebug.lookout.plugins

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.engine.EngineAccess

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * What the plugins are alarming about, and whether it is sounding.
 *
 * A plugin raises an alert from its own thread with no gesture behind it, so
 * nothing the mariner does brings one to the screen. The core offers no way to
 * be told: there is no callback for a raise, and the `seq` that says the set
 * moved is only reachable by building the whole alerts JSON. So this SAMPLES,
 * and says so.
 *
 * What it does not do is arm a clock of its own for it. The frame loop is
 * already running and already visits every frame, so an idle chart gains no
 * wakeup it did not already have; [sampleIfDue] only decides how often that
 * existing visit crosses into the core. A second matches the reference shell
 * and is a fifth of the alarm repeat, so an alarm is on screen well before it
 * sounds twice. With no surface there are no frames to ride on, and the
 * engine's background visit calls [publish] directly instead.
 */
class AlertController(appContext: Context, private val access: EngineAccess) {

    /**
     * Every alert the plugins have raised, most urgent first. The banner over
     * the chart is built from this.
     */
    var alerts by mutableStateOf<List<PluginAlert>>(emptyList())
        private set

    private val siren = AlarmSiren(appContext)

    /**
     * The set the core last reported, as its `seq`. The list is rebuilt only
     * when it moves. [UNREAD] is never a real seq, which is what lets it stand
     * for "the core has not answered".
     */
    private var seq = UNREAD
    private var lastSampleNs = 0L

    /** A new chart, so a registry nobody has seen and a seq that means nothing. */
    fun reset() {
        seq = UNREAD
        lastSampleNs = 0L
    }

    /**
     * The once-a-second look, off the frame loop. RENDER THREAD.
     */
    fun sampleIfDue(l: Lookout, frameTimeNanos: Long) {
        if (lastSampleNs != 0L && frameTimeNanos - lastSampleNs < INTERVAL_NS) return
        lastSampleNs = frameTimeNanos
        publish(l)
    }

    /**
     * Read the alerts and hand the list to the UI when it has moved. RENDER
     * THREAD: [seq] is its own, and the native call takes the api lock.
     *
     * Also called straight after an acknowledgement, so the row leaves the
     * chart on the press rather than at the next sample.
     */
    fun publish(l: Lookout) {
        val got = PluginAlertSet.parse(l.pluginAlertsJson())
        if (got == null) {
            // Nothing came back. The sampling carries on: giving up here would
            // leave the boat deaf for the rest of the session because the core
            // once had nothing to say.
            if (seq == UNREAD) return
            seq = UNREAD
            access.onMain { apply(emptyList()) }
            return
        }
        if (got.seq == seq) return
        seq = got.seq
        access.onMain { apply(got.alerts) }
    }

    /**
     * Silence one alert and take it off the chart. ONE alert: a mariner who has
     * seen the vessel crossing ahead has not seen the one coming up astern, and
     * a control for both would hide the second.
     */
    fun acknowledge(alert: PluginAlert) = access.onEngine { l ->
        if (!l.pluginAlertAck(alert.id)) Log.w(TAG, "alert ack refused: ${alert.id}")
        publish(l)
    }

    /**
     * The chart is going away with the plugins that raised the alarms, so
     * nothing is left to acknowledge and nothing may go on sounding.
     *
     * MAIN THREAD: Compose state, and the siren, whose strike runnable lives on
     * the main handler and whose flag is not volatile.
     */
    fun clear() {
        apply(emptyList())
    }

    /** MAIN THREAD. The list and the siren move together. */
    private fun apply(next: List<PluginAlert>) {
        alerts = next
        // An alarm nobody has answered keeps sounding. A warning is shown and
        // never sounded, so it is not counted here.
        siren.setSounding(next.any { it.severity.audible && !it.acknowledged })
    }

    private companion object {
        const val TAG = "lookout"

        /** No `seq` the core reports, so it can stand for "not answered yet". */
        const val UNREAD = -1L

        /**
         * How often the frame loop crosses into the core for the alerts. See
         * the class comment for why this is a sample and not a wake.
         */
        const val INTERVAL_NS = 1_000_000_000L
    }
}
