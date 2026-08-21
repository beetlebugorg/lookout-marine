package org.beetlebug.lookout

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
 * The fix in three states that differ in more than colour, so no one signal
 * carries it alone (the reference's PositionReadout): live is a filled "GPS"
 * pill, lost is an outlined "NO GPS" — with NO numbers anywhere near it — and
 * never-had-a-source is a "Configure GPS" button that opens Connections,
 * because that state carries a fix-it, not a warning.
 */
@Composable
private fun FixPill(fixState: Int, onConfigure: () -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    when (fixState) {
        Lookout.FIX_LIVE -> Surface(shape = RoundedCornerShape(50), color = accent) {
            Text(
                "GPS",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onPrimary,
                modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
            )
        }
        Lookout.FIX_LOST -> Surface(
            shape = RoundedCornerShape(50),
            color = Color.Transparent,
            border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.error),
        ) {
            Text(
                "NO GPS",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
            )
        }
        else -> Surface(
            shape = RoundedCornerShape(50),
            color = Color.Transparent,
            border = androidx.compose.foundation.BorderStroke(1.dp, accent),
            modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onConfigure),
        ) {
            Text(
                "Configure GPS",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = accent,
                modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
            )
        }
    }
}

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
    raster: RasterState = RasterState(),
    onRasterSelect: (Int) -> Unit = {},
    onToggleChart: () -> Unit = {},
    onAddRasterCharts: () -> Unit = {},
    onConfigureGps: () -> Unit = {},
) {
    // A phone will not take the whole row on one line: the position alone is
    // 44% of its width, and the raster chart pill pushed it past the screen,
    // where it lost its shape and clipped. So a narrow window takes TWO lines
    // rather than dropping a readout — the position is the one a mariner may
    // have to write down or pass over the radio, and it becomes the vessel's
    // own once there is a GPS.
    Surface(
        modifier = modifier
            .heightIn(min = Chrome.capsule)
            // Chrome refuses the chart's gestures: a tap on the capsule's own
            // face used to fall through to the SurfaceView and pick whatever
            // sat under the HUD.
            .pointerInput(Unit) { detectTapGestures { } },
        // A capsule at one line and a rounded block at two: the radius is half
        // the one-line height, so the settled shape is the capsule it has
        // always been.
        shape = RoundedCornerShape(Chrome.capsule / 2),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        tonalElevation = 2.dp,
        shadowElevation = 4.dp,
    ) {
      Column(
          horizontalAlignment = Alignment.CenterHorizontally,
          modifier = Modifier.padding(
              horizontal = if (compact) 14.dp else 18.dp,
              vertical = if (compact) 6.dp else 0.dp,
          ),
      ) {
        Row(
            modifier = if (compact) Modifier else Modifier.height(Chrome.capsule),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(if (compact) 10.dp else 12.dp),
        ) {
            FixPill(readouts.fixState, onConfigureGps)
            // The band survives on a phone where the position does not: six
            // characters against twenty-seven, and it is the one readout here
            // that says how much the chart has generalised what it shows.
            Text(
                text = bandString(readouts.scaleDenominator),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
            Separator()
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
            // The zoom is a number about the tile pyramid, not about the water.
            // It is the first thing to go when the width runs out.
            if (!compact) {
                Separator()
                Text(
                    text = String.format(Locale.US, "z%.1f", readouts.zoom),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
                // Own ship's REPORTED fix, and nothing else: the map centre or
                // a dead-reckoned number here is a wrong position a mariner
                // may write in a log (the reference's ship-or-nothing rule).
                if (readouts.fixState == Lookout.FIX_LIVE) {
                    Separator()
                    Text(
                        text = coordString(readouts.shipLat, readouts.shipLon),
                        style = MaterialTheme.typography.bodyMedium,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                    )
                }
            }
            if (readouts.overscale > OVERSCALE_VISIBLE_AT) {
                OverscaleBadge(readouts.overscale)
            }
            // The raster-chart pill. It appears only where a raster chart is in
            // view, at any zoom, and goes when the mariner leaves the coverage.
            // Where they carry nothing there is nothing to press.
            if (raster.visible.isNotEmpty()) {
                Separator()
                RasterPill(
                    raster = raster,
                    onSelect = onRasterSelect,
                    onToggleChart = onToggleChart,
                    onAdd = onAddRasterCharts,
                )
            }
        }
        if (compact) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.padding(top = 2.dp),
            ) {
                Text(
                    text = coordString(readouts.lat, readouts.lon),
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                )
                Separator()
                Text(
                    text = String.format(Locale.US, "z%.1f", readouts.zoom),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        }
      }
    }
}

/**
 * Names the raster chart set drawn over this view and opens the list of what
 * covers it.
 *
 * The COLOUR reports the raster chart, not the ENC: blue while the picture is
 * drawn, amber while one is here and off. Hiding the ENC above it does not
 * change the colour, because the picture is still drawn — the "ENC OFF" text
 * carries that, and a warning colour there would say the picture was off when
 * it is the only thing on screen.
 */
@Composable
private fun RasterPill(
    raster: RasterState,
    onSelect: (Int) -> Unit,
    onToggleChart: () -> Unit,
    onAdd: () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val visible = raster.visible
    // The set the pill NAMES: the drawn one when it is in view, otherwise the
    // first one that is. Naming one set and reporting the state of another is
    // how a pill comes to read "NAVIONICS | OFF" while Navionics is drawn.
    val named = visible.firstOrNull { it.id == raster.active } ?: visible.firstOrNull()
    val drawn = named != null && named.id == raster.active
    val amber = Color(0xFFFFA726)
    val tint = if (drawn) MaterialTheme.colorScheme.primary else amber
    val stateWord = when {
        !drawn -> "off"
        raster.chartHidden -> "drawn, ENC hidden"
        else -> "drawn"
    }

    Box {
        Surface(
            color = tint.copy(alpha = if (drawn) 0.18f else 0.28f),
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .clickable { open = true }
                .semantics {
                    contentDescription = "Raster chart ${named?.name ?: ""}, $stateWord"
                },
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
            ) {
                Text(
                    text = (named?.name ?: "").uppercase(Locale.US),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = tint,
                    maxLines = 1,
                )
                if (!drawn || raster.chartHidden) {
                    Text("|", color = tint.copy(alpha = 0.5f),
                         style = MaterialTheme.typography.labelMedium)
                    Text(
                        text = if (!drawn) "OFF" else "ENC OFF",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                        color = tint,
                        maxLines = 1,
                    )
                }
                // The chevron is a promise: a press opens a list. It is
                // therefore always shown, because a press always does.
                Icon(
                    imageVector = Icons.Filled.ArrowDropDown,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            visible.forEach { set ->
                DropdownMenuItem(
                    text = { Text(set.name) },
                    leadingIcon = {
                        if (set.id == raster.active) {
                            Icon(Icons.Filled.Check, contentDescription = null)
                        }
                    },
                    onClick = { open = false; onSelect(set.id) },
                )
            }
            DropdownMenuItem(
                text = { Text("None") },
                leadingIcon = {
                    if (raster.active < 0) Icon(Icons.Filled.Check, contentDescription = null)
                },
                onClick = { open = false; onSelect(-1) },
            )
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(if (raster.chartHidden) "Show ENC Over Raster" else "Hide ENC Over Raster") },
                onClick = { open = false; onToggleChart() },
            )
            DropdownMenuItem(
                text = { Text("Add Raster Charts…") },
                onClick = { open = false; onAdd() },
            )
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
    "${dm(lat, true)} ${dm(lon, false)}"

/**
 * Degrees and DECIMAL MINUTES with a hemisphere. The longitude has three degree
 * digits, so a pair keeps its column width. It agrees with CoordFormat.dm
 * (macOS and iOS), lkw::FormatCoord (Windows) and lk_coord_format_dm (Linux).
 * Each host prints the same string.
 *
 * WHY NOT DEGREES, MINUTES AND SECONDS. Decimal minutes is what a mariner works
 * in: it is what a GPS and a chartplotter show, what goes in the deck log, and
 * what is passed over the radio. One minute of latitude is one nautical mile,
 * so a decimal minute reads as distance directly. Seconds belong to surveying.
 */
private fun dm(value: Double, isLat: Boolean): String {
    val hemi = if (isLat) (if (value >= 0) "N" else "S") else (if (value >= 0) "E" else "W")
    val a = abs(value)
    var deg = a.toInt()
    var minutes = (a - deg) * 60
    // Carry the rounding. 59.9996' prints as 60.000', which is the next degree.
    if (Math.round(minutes * 1000) >= 60000) {
        minutes = 0.0
        deg++
    }
    val fmt = if (isLat) "%02d\u00B0%06.3f'%s" else "%03d\u00B0%06.3f'%s"
    return String.format(Locale.US, fmt, deg, minutes, hemi)
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
