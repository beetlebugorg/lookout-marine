package org.beetlebug.lookout.hud

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.chart.ChartController
import org.beetlebug.lookout.chart.Readouts
import org.beetlebug.lookout.charts.RasterState

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
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.Canvas
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.unit.dp
import java.util.Locale

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
            }
            // The position slot, where the reference keeps it: the fix pill,
            // and beside it own ship's REPORTED fix — nothing else. The map
            // centre or a dead-reckoned number here is a wrong position a
            // mariner may write in a log (the ship-or-nothing rule).
            Separator()
            FixPill(readouts.fixState, onConfigureGps)
            if (!compact && readouts.fixState == Lookout.FIX_LIVE) {
                Text(
                    text = coordString(readouts.shipLat, readouts.shipLon),
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                )
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
                // THE SHIP-OR-NOTHING RULE, the same one the wide row keeps.
                // This line used to print the MAP CENTRE, unconditionally, a
                // few points under the fix pill: with the chart panned away
                // from the boat it read as a position, beside a "GPS" badge,
                // and a mariner could write it in a log or pass it over the
                // radio. Own ship's reported fix or no numbers at all.
                if (readouts.fixState == Lookout.FIX_LIVE) {
                    Text(
                        text = coordString(readouts.shipLat, readouts.shipLon),
                        style = MaterialTheme.typography.bodyMedium,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                    )
                    Separator()
                }
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
    val tint = if (drawn) MaterialTheme.colorScheme.primary else Chrome.amber
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
    // The reference's overscale red-orange (theme tertiary), NOT amber:
    // zoomed past the survey is stronger news than a plugin's warning.
    val c = MaterialTheme.colorScheme.tertiary
    Surface(color = c.copy(alpha = 0.2f), shape = CircleShape) {
        Text(
            text = String.format(Locale.US, "×%.1f", overscale),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = c,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

/**
 * The startup loader. Opening a real library is one chart open per cell, the
 * atlas bake and the GPU bring-up, which is tens of seconds; the surface is
 * bare until the first frame. The loader says what the wait is for, step by
 * step, the way the reference's StartupLoader does: the one-time symbol
 * atlas, the mapping pass, then the first scene.
 */
@Composable
fun StartupLoader(
    cells: Int,
    phase: ChartController.LoadPhase,
    modifier: Modifier = Modifier,
) {
    val step = when (phase) {
        ChartController.LoadPhase.SYMBOLS -> 0
        ChartController.LoadPhase.MAPPING -> 1
        ChartController.LoadPhase.TESSELLATING -> 2
    }
    val mapping = if (cells > 1) {
        String.format(Locale.US, "Mapping %,d cells", cells)
    } else {
        "Mapping the chart"
    }
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        tonalElevation = 3.dp,
        shadowElevation = 8.dp,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 28.dp, vertical = 22.dp),
            horizontalAlignment = Alignment.Start,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CompassMark(Modifier.size(24.dp))
                Text(
                    text = if (cells > 1) {
                        String.format(Locale.US, "Opening %,d charts", cells)
                    } else {
                        "Opening the chart"
                    },
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            LinearProgressIndicator(Modifier.width(240.dp))
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                // The atlas bake happens on the first run only, so on every
                // other run it is already done rather than skipped.
                BakeStep(
                    state = if (step > 0) StepState.DONE else StepState.RUNNING,
                    label = "Preparing chart symbols",
                    detail = if (step > 0) "" else "first run only",
                )
                BakeStep(
                    state = when {
                        step > 1 -> StepState.DONE
                        step == 1 -> StepState.RUNNING
                        else -> StepState.WAITING
                    },
                    label = mapping,
                    detail = if (step == 1) "not loading them, so this is quick" else "",
                )
                BakeStep(
                    state = if (step == 2) StepState.RUNNING else StepState.WAITING,
                    label = "Drawing the first scene",
                    detail = "",
                )
            }
        }
    }
}

private enum class StepState { WAITING, RUNNING, DONE }

/** One loader step: a state mark, its label, and an aside when one helps. */
@Composable
private fun BakeStep(state: StepState, label: String, detail: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when (state) {
            StepState.RUNNING -> CircularProgressIndicator(
                Modifier.size(14.dp),
                strokeWidth = 2.dp,
            )
            StepState.DONE -> Icon(
                Icons.Default.Check,
                contentDescription = null, // the label carries the meaning
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(14.dp),
            )
            StepState.WAITING -> Spacer(Modifier.size(14.dp))
        }
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            color = if (state == StepState.WAITING) {
                MaterialTheme.colorScheme.onSurfaceVariant
            } else {
                MaterialTheme.colorScheme.onSurface
            },
        )
        if (detail.isNotEmpty()) {
            Text(
                text = detail,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * The compass rose of the loader. It is drawn, not a Material icon, so the
 * shape is the same on each platform (the reference's CompassMark).
 */
@Composable
private fun CompassMark(modifier: Modifier = Modifier) {
    val accent = MaterialTheme.colorScheme.primary.copy(alpha = 0.35f)
    val needle = Color(0xFFD42E2E)
    Canvas(modifier) {
        val r = size.minDimension / 2
        val c = Offset(r, r)
        drawCircle(color = accent, radius = r - 1.dp.toPx(), center = c, style = Stroke(2.dp.toPx()))
        // The four cardinal ticks.
        for (i in 0 until 4) {
            rotate(degrees = i * 90f, pivot = c) {
                drawLine(
                    color = accent,
                    start = Offset(r, r * 0.14f),
                    end = Offset(r, r * 0.42f),
                    strokeWidth = 1.5f.dp.toPx(),
                )
            }
        }
        // The north needle. A chart compass rose uses the same red.
        val p = Path().apply {
            moveTo(r, r * 0.28f)
            lineTo(r * 0.7f, r * 1.32f)
            lineTo(r * 1.3f, r * 1.32f)
            close()
        }
        drawPath(p, needle)
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
