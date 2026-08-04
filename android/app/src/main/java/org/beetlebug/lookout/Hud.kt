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
import androidx.compose.foundation.layout.height
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.CircularProgressIndicator
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
fun ReadoutsCapsule(
    readouts: Readouts,
    compact: Boolean,
    onScaleTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.height(Chrome.capsule),
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        tonalElevation = 2.dp,
        shadowElevation = 4.dp,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = if (compact) 14.dp else 18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(if (compact) 10.dp else 12.dp),
        ) {
            Surface(
                modifier = Modifier.size(10.dp),
                shape = CircleShape,
                color = Color(0xFFF59E0B),
                content = {},
            )
            // The band is the first thing a mariner reads, and the first thing
            // a narrow screen gives up.
            if (!compact) {
                Text(
                    text = bandString(readouts.scaleDenominator),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
                Separator()
            }
            Text(
                text = scaleString(readouts.scaleDenominator),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.primary,
                maxLines = 1,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(onClick = onScaleTap)
                    .padding(horizontal = 5.dp, vertical = 3.dp),
            )
            Separator()
            Text(
                text = String.format(Locale.US, "z%.1f", readouts.zoom),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
            Separator()
            Text(
                text = coordString(readouts.lat, readouts.lon),
                style = MaterialTheme.typography.bodyMedium,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
            )
            if (readouts.overscale > OVERSCALE_VISIBLE_AT) {
                OverscaleBadge(readouts.overscale)
            }
        }
    }
}

@Composable
private fun Separator() {
    Surface(
        modifier = Modifier.size(width = 1.dp, height = 20.dp),
        color = MaterialTheme.colorScheme.outlineVariant,
        content = {},
    )
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

/** The full 1:N with group separators: `1:13,267`, as every shell prints it. */
private fun scaleString(n: Double): String =
    if (n <= 0) "1:\u2014" else String.format(Locale.US, "1:%,d", Math.round(n))

/**
 * The S-52 navigational purpose band for a display scale. It agrees with
 * CoordFormat.band (macOS and iOS) and lkw::BandForDenom (Windows).
 */
private fun bandString(n: Double): String = when {
    n < 0.001 -> "\u2014"
    n < 5_000 -> "Berthing"
    n < 25_000 -> "Harbor"
    n < 75_000 -> "Approach"
    n < 300_000 -> "Coastal"
    n < 1_500_000 -> "General"
    else -> "Overview"
}

/**
 * The startup loader. Opening a real library is one chart open per cell, the
 * atlas bake and the GPU bring-up, which is tens of seconds; the surface is
 * bare until the first frame. The loader says what the wait is for.
 */
@Composable
fun StartupLoader(cells: Int, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        tonalElevation = 3.dp,
        shadowElevation = 8.dp,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 28.dp, vertical = 22.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CircularProgressIndicator(Modifier.size(30.dp), strokeWidth = 3.dp)
            Text(
                text = if (cells > 1) {
                    String.format(Locale.US, "Mapping %,d cells", cells)
                } else {
                    "Mapping the chart"
                },
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "The chart draws as soon as the first scene is built.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** A later rebuild: the chart is up and filling in behind this. */
@Composable
fun BuildingPill(modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
        tonalElevation = 2.dp,
        shadowElevation = 3.dp,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            CircularProgressIndicator(Modifier.size(13.dp), strokeWidth = 2.dp)
            Text(
                text = "Building",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
