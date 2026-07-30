package org.beetlebug.lookout

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.util.Locale
import kotlin.math.abs

/**
 * Native, translucent readouts drawn OVER the chart — deliberately not drawn by
 * the engine, which stays the chart surface. The Android twin of
 * HUDOverlay.swift.
 */

/** Amber, and only past a threshold: an overscale badge that is always up is
 *  just decoration, and this one means "you are magnifying past the survey". */
private const val OVERSCALE_VISIBLE_AT = 1.05

/**
 * Lat/lon, 1:N scale and zoom in one row at the bottom of the chart. The
 * overscale badge shows when the view is zoomed past the data. The position is
 * in degrees, minutes and seconds, the format that each host uses.
 */
@Composable
fun ReadoutsBar(readouts: Readouts, modifier: Modifier = Modifier) {
    // A full-width BAR, not a floating capsule: the surface runs under the
    // navigation bar so the chart never peeks out below it.
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.86f),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                // The Surface above runs edge-to-edge; only the CONTENT insets,
                // so the bar's material extends through the navigation bar and
                // the chart never peeks out beneath it.
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                Icons.Default.LocationOn,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = coordString(readouts.lat, readouts.lon),
                style = MaterialTheme.typography.bodyMedium,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
            )
            if (readouts.overscale > OVERSCALE_VISIBLE_AT) {
                OverscaleBadge(readouts.overscale)
            }
            Spacer(Modifier.weight(1f))
            HudLabel(Icons.Default.Straighten, scaleString(readouts.scaleDenominator))
            HudLabel(Icons.Default.ZoomIn, String.format(Locale.US, "z%.1f", readouts.zoom))
        }
    }
}

@Composable
private fun OverscaleBadge(overscale: Double) {
    val amber = Color(0xFFFFA726)
    Surface(color = amber.copy(alpha = 0.25f), shape = CircleShape) {
        Text(
            text = String.format(Locale.US, "×%.1f", overscale),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = amber,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

@Composable
private fun HudLabel(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            modifier = Modifier.size(13.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = text,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
        )
    }
}

/**
 * A compass rose that turns with the view and snaps back to north when tapped.
 * Hidden while the chart is north-up: a control that only ever does nothing is
 * clutter, and its appearance is the cue that the chart has been rotated.
 */
@Composable
fun CompassBadge(rotationDeg: Double, onReset: () -> Unit, modifier: Modifier = Modifier) {
    if (abs(rotationDeg) < 0.5) return
    Surface(
        modifier = modifier
            .size(40.dp)
            .clickable(onClick = onReset),
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.86f),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.rotate(-rotationDeg.toFloat()),
        ) {
            Icon(
                Icons.Default.Navigation,
                contentDescription = "Reset to north-up",
                modifier = Modifier.size(18.dp),
                tint = Color(0xFFE53935),
            )
            Text(
                "N",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

/** One line per feature under the last tap: object class + source cell. */
@Composable
fun IdentifyPanel(
    results: List<PickFeature>,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.width(280.dp),
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        tonalElevation = 3.dp,
    ) {
        Column(Modifier.padding(start = 12.dp, top = 6.dp, end = 4.dp, bottom = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Pick report",
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss, modifier = Modifier.size(28.dp)) {
                    Icon(
                        Icons.Default.Close,
                        contentDescription = "Dismiss",
                        modifier = Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            for (f in results) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.padding(top = 3.dp),
                ) {
                    Text(
                        text = f.cls.ifEmpty { f.s57 },
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                    )
                    Text(
                        text = f.chart,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

// ---- formatting -------------------------------------------------------------

private fun coordString(lat: Double, lon: Double): String =
    "${dms(lat, true)} ${dms(lon, false)}"

/**
 * Degrees, minutes and seconds with a hemisphere. The longitude has three degree
 * digits, so a pair keeps its column width. It agrees with CoordFormat.dms
 * (macOS and iOS), lkw::FormatCoord (Windows) and lk_coord_format_dms (Linux).
 * Each host prints the same string.
 */
private fun dms(value: Double, isLat: Boolean): String {
    val hemi = if (isLat) (if (value >= 0) "N" else "S") else (if (value >= 0) "E" else "W")
    val a = abs(value)
    var deg = a.toInt()
    var minutes = ((a - deg) * 60).toInt()
    var seconds = ((a - deg) * 60 - minutes) * 60
    // Carry the rounding. 59.96" prints as 60.0", which is the next minute.
    if (Math.round(seconds * 10) >= 600) {
        seconds = 0.0
        minutes++
    }
    if (minutes >= 60) {
        minutes = 0
        deg++
    }
    val pattern = if (isLat) "%02d\u00B0%02d'%04.1f\"%s" else "%03d\u00B0%02d'%04.1f\"%s"
    return String.format(Locale.US, pattern, deg, minutes, seconds, hemi)
}

/** Compact 1:N — "1:24k" / "1:2.1M": the HUD is a glance, not a survey. */
private fun scaleString(n: Double): String = when {
    n <= 0 -> "1:—"
    n >= 1_000_000 -> String.format(Locale.US, "1:%.1fM", n / 1_000_000)
    n >= 10_000 -> String.format(Locale.US, "1:%.0fk", n / 1_000)
    else -> String.format(Locale.US, "1:%,d", n.toInt())
}
