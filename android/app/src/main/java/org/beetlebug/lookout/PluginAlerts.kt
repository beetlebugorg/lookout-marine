package org.beetlebug.lookout

import android.content.Context
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.json.JSONObject

/**
 * The alerts the plugins raise, on screen and out loud. The Android twin of
 * PluginAlerts.swift.
 *
 * A plugin raises an alert with a severity, a title and a body. The core holds
 * it and hands it over through lookout_plugin_alerts_json, already ordered:
 * what nobody has answered first, then the loudest, then the oldest. This file
 * shows it, sounds the alarms, and acknowledges one when the mariner silences
 * it.
 *
 * AN ALARM IS AUDIBLE AND A WARNING IS VISIBLE. That is the whole of what
 * severity means here. An alarm repeats until it is acknowledged: it does not
 * stop because the mariner looked at it, and it does not time out. Silence is
 * a decision somebody makes.
 *
 * Acknowledging silences ONE alert. The mariner who has seen the vessel
 * crossing ahead has not seen the one coming up astern, and a control that
 * silenced both would hide the second.
 */

// ---- what the core hands over ----------------------------------------------

enum class PluginAlertSeverity {
    ALARM,
    WARNING,
    NOTICE,
    ;

    /** True when this severity is sounded rather than only shown. */
    val audible: Boolean get() = this == ALARM

    companion object {
        /**
         * A severity this build does not know is treated as an alarm, the same
         * way the core treats one it cannot read. Silence is never the
         * fallback.
         */
        fun parse(s: String?): PluginAlertSeverity = when (s) {
            "warning" -> WARNING
            "notice" -> NOTICE
            else -> ALARM
        }
    }
}

data class PluginAlert(
    val id: Long,
    val plugin: String,
    val severity: PluginAlertSeverity,
    val title: String,
    val body: String,
    /** When the plugin first raised it, in milliseconds since the epoch. */
    val raised: Long,
    val acknowledged: Boolean,
)

/**
 * The alert list as the core last stated it. [seq] moves on every change to the
 * set, so a caller that keeps the last one can skip rebuilding the list while
 * it stands still.
 */
data class PluginAlertSet(val seq: Long, val alerts: List<PluginAlert>) {
    companion object {
        /** Null for a payload that will not parse, which the caller treats as
         *  "the core said nothing", not as "there are no alerts". */
        fun parse(json: String?): PluginAlertSet? {
            if (json.isNullOrEmpty()) return null
            return try {
                val top = JSONObject(json)
                val arr = top.optJSONArray("alerts")
                val list = buildList {
                    for (i in 0 until (arr?.length() ?: 0)) {
                        val o = arr!!.optJSONObject(i) ?: continue
                        val title = o.optString("title")
                        if (title.isEmpty()) continue
                        add(
                            PluginAlert(
                                id = o.optLong("id"),
                                plugin = o.optString("plugin"),
                                severity = PluginAlertSeverity.parse(o.optString("severity")),
                                title = title,
                                body = o.optString("body"),
                                raised = o.optLong("raised"),
                                acknowledged = o.optBoolean("acknowledged"),
                            ),
                        )
                    }
                }
                PluginAlertSet(top.optLong("seq", -1), list)
            } catch (e: Exception) {
                Log.w("lookout", "alerts: unreadable JSON: $e")
                null
            }
        }
    }
}

// ---- the sound --------------------------------------------------------------

/**
 * The alarm tone, repeated while anything is unacknowledged.
 *
 * WHICH sound is a stand-in. A marine alarm has to cut through wind and engine
 * noise, and settling what that sounds like is not the shell's to do, so a
 * short system sonification takes the part, as it does in the reference shell.
 * WHERE it plays is not a stand-in: USAGE_ALARM puts it on the alarm stream, so
 * a tablet whose notifications are silenced still sounds a collision alarm.
 *
 * The device's own ALARM tone is deliberately not the one played. A stock
 * Android alarm runs for tens of seconds, longer than the repeat interval, so
 * restarting it every ten seconds yields unbroken noise: it takes away the gap
 * to speak on the radio, and a mariner cannot count how long an alarm has been
 * going when it never stops.
 *
 * MAIN THREAD only: the repeat runs on the main looper and Ringtone is not
 * safe to drive from two threads.
 */
class AlarmSiren(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var sounding = false
    private var tone: Ringtone? = null

    private val strike = object : Runnable {
        override fun run() {
            if (!sounding) return
            play()
            main.postDelayed(this, REPEAT_MS)
        }
    }

    /**
     * Start or stop the repeat. Sounding starts at once: the first alarm is not
     * held back for a timer.
     */
    fun setSounding(on: Boolean) {
        if (on == sounding) return
        sounding = on
        if (!on) {
            main.removeCallbacks(strike)
            tone?.stop()
            return
        }
        strike.run()
    }

    private fun play() {
        val r = tone ?: load() ?: return
        // Restart rather than overlap: a tone still playing would otherwise
        // swallow the next strike and the repeat would go quiet.
        if (r.isPlaying) r.stop()
        r.play()
    }

    /**
     * The device's notification sound, or its alarm sound where it has none.
     * Held after the first strike, because resolving the URI touches settings
     * and the media store.
     */
    private fun load(): Ringtone? {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: return null
        val r = RingtoneManager.getRingtone(context, uri) ?: return null
        r.audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        tone = r
        return r
    }

    private companion object {
        /**
         * How often an unacknowledged alarm sounds again. Once a second is
         * right on a boat and unusable at a desk; ten seconds still cannot be
         * mistaken for a one-off chime, and leaves room to speak on the radio
         * between soundings.
         */
        const val REPEAT_MS = 10_000L
    }
}

// ---- the banner -------------------------------------------------------------

/**
 * The alerts, over the chart. The palette is the chrome's, so the panel stays
 * readable at night without a hardcoded red burning the mariner's dark
 * adaptation.
 */
@Composable
fun AlertBanner(
    alerts: List<PluginAlert>,
    onAcknowledge: (PluginAlert) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Only what still needs answering. Acknowledging takes a row off the chart,
    // because the panel covers the water and its job is to say something needs
    // attention now. What is still dangerous after that is the chart's to show:
    // the target stays red and carries its own state when it is tapped.
    val unanswered = alerts.filter { !it.acknowledged }
    if (unanswered.isEmpty()) return
    Surface(
        // The banner keeps its taps. Without this a press on Acknowledge also
        // reaches the chart underneath, which reads it as a tap on open water
        // and opens a pick report over the alarm being answered.
        modifier = modifier
            .widthIn(max = ALERT_BANNER_MAX_WIDTH)
            .pointerInput(Unit) { detectTapGestures { } },
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 3.dp,
        shadowElevation = 6.dp,
    ) {
        Column {
            for ((i, alert) in unanswered.take(MAX_VISIBLE).withIndex()) {
                if (i > 0) HorizontalDivider()
                AlertRow(alert) { onAcknowledge(alert) }
            }
            if (unanswered.size > MAX_VISIBLE) {
                HorizontalDivider()
                Text(
                    "${unanswered.size - MAX_VISIBLE} more",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
                )
            }
        }
    }
}

/** One alert: the severity bar, the words, and the control that silences it. */
@Composable
private fun AlertRow(alert: PluginAlert, onAcknowledge: () -> Unit) {
    val tint = severityTint(alert.severity)
    // One line. The words say which danger and which vessel; the water under
    // them is what the mariner is actually looking at, so the row stays the
    // height of its text and the body truncates rather than wrapping into a
    // second line.
    //
    // IntrinsicSize.Min is what gives the severity bar a height to fill. A Row
    // that wraps its content passes an unbounded height down, and a bar asked
    // to fill that comes out at nothing.
    Row(
        modifier = Modifier.height(IntrinsicSize.Min),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .fillMaxHeight()
                .width(4.dp)
                .background(tint),
        )
        Icon(
            severityGlyph(alert.severity),
            contentDescription = null,
            modifier = Modifier
                .padding(start = 10.dp)
                .size(18.dp),
            tint = tint,
        )
        Text(
            alert.title,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            modifier = Modifier.padding(start = 8.dp, top = 8.dp, bottom = 8.dp),
        )
        // The body takes whatever is left and truncates into it, so it is the
        // gap between the words and the button as well as the words.
        Text(
            alert.body,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .padding(start = 8.dp)
                .weight(1f),
        )
        Spacer(Modifier.width(8.dp))
        TextButton(onClick = onAcknowledge, modifier = Modifier.padding(end = 4.dp)) {
            Text(
                "Acknowledge",
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
            )
        }
    }
}

/**
 * Alarm takes the palette's strongest warning colour, a warning takes amber.
 * Both come from the chrome, so they follow the scheme the chart is in.
 */
@Composable
private fun severityTint(s: PluginAlertSeverity): Color = when (s) {
    PluginAlertSeverity.ALARM -> MaterialTheme.colorScheme.error
    PluginAlertSeverity.WARNING -> Chrome.amber
    PluginAlertSeverity.NOTICE -> MaterialTheme.colorScheme.primary
}

private fun severityGlyph(s: PluginAlertSeverity): ImageVector = when (s) {
    PluginAlertSeverity.ALARM -> Icons.Filled.Warning
    PluginAlertSeverity.WARNING -> Icons.Filled.Error
    PluginAlertSeverity.NOTICE -> Icons.Filled.Info
}

/**
 * How many alerts are shown. The strip must not cover the water the mariner is
 * reading, least of all during a collision alarm, when the target it names is
 * on the chart underneath. The rest are counted on the last line and take their
 * turn as the ones above are answered.
 */
private const val MAX_VISIBLE = 2

/** Wide enough for a title, a vessel and a closest approach on one line. */
private val ALERT_BANNER_MAX_WIDTH = 560.dp
