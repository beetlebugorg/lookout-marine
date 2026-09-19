package org.beetlebug.lookout.charts

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.toSize
import kotlin.math.PI
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.tan

/**
 * Where the regions are.
 *
 * The lower 48, with Alaska and Hawaii under it. One view cannot hold all
 * three: they span 128 degrees of longitude, and at that scale their latitude
 * span is taller than the screen. An atlas prints them separately for the same
 * reason.
 *
 * The map is a picture of the pick, not the control for it. Tapping a region
 * on it works, and the rows under it are how a thumb does the same thing.
 */

/** The ground one panel covers, and the projection onto it. */
class MapWindow(val west: Double, val south: Double, val east: Double, val north: Double) {
    private val lonSpan get() = east - west

    /** Width over height, so a panel keeps its shape at any size. */
    val aspect: Float
        get() {
            val h = mercator(north) - mercator(south)
            return if (h <= 0) 1f else (lonSpan * PI / 180 / h).toFloat()
        }

    fun x(lon: Double, size: Size): Float = ((lon - west) / lonSpan * size.width).toFloat()

    fun y(lat: Double, size: Size): Float {
        val top = mercator(north)
        val h = top - mercator(south)
        val dy = if (h == 0.0) 0.0 else (top - mercator(lat)) / h
        return (dy * size.height).toFloat()
    }

    fun intersects(w: Double, s: Double, e: Double, n: Double): Boolean =
        e >= west && w <= east && n >= south && s <= north

    companion object {
        /** Mercator y, clamped clear of the poles. */
        fun mercator(lat: Double): Double {
            val phi = max(-85.05, min(85.05, lat)) * PI / 180
            return ln(tan(PI / 4 + phi / 2))
        }
    }
}

private val MAIN = MapWindow(-132.0, 20.0, -64.0, 52.0)
private val MAIN_IDS = setOf("d1", "d5", "d7", "d8", "d9", "d11", "d13")
private val ALASKA = MapWindow(-172.0, 50.5, -128.0, 72.0)
private val HAWAII = MapWindow(-161.0, 18.3, -154.0, 22.6)

/** S-52 shallow blue and GSHHG land, so the picker sits in the chart's own
 *  palette rather than the system's. */
private val WATER = Color(0xFFADD6FF).copy(alpha = 0.55f)
private val LAND = Color(0xFFA39654).copy(alpha = 0.55f)

@Composable
fun CoverageMap(
    regions: List<NoaaController.Region>,
    picked: Set<String>,
    enabled: Boolean,
    coverage: Map<String, List<NoaaController.Box>>,
    onToggle: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val rings = remember { Coastline.rings(context) }
    val accent = MaterialTheme.colorScheme.primary
    val edge = MaterialTheme.colorScheme.outlineVariant

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        panel(MAIN, MAIN_IDS, rings, regions, picked, enabled, coverage, accent, edge, onToggle,
              Modifier.fillMaxWidth().aspectRatio(MAIN.aspect))
        // Alaska and Hawaii keep their own frames, under the map rather than
        // in a corner of it: on a narrow screen a frame in the corner covers
        // the west coast, and a region cannot be picked through another one.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            inset("Alaska", ALASKA, setOf("d17"), rings, regions, picked, enabled, coverage,
                  accent, edge, onToggle, 104.dp)
            inset("Hawaii", HAWAII, setOf("d14"), rings, regions, picked, enabled, coverage,
                  accent, edge, onToggle, 56.dp)
        }
    }
}

@Composable
private fun inset(
    label: String,
    window: MapWindow,
    ids: Set<String>,
    rings: List<Coastline.Ring>,
    regions: List<NoaaController.Region>,
    picked: Set<String>,
    enabled: Boolean,
    coverage: Map<String, List<NoaaController.Box>>,
    accent: Color,
    edge: Color,
    onToggle: (String) -> Unit,
    width: androidx.compose.ui.unit.Dp,
) {
    Column {
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(2.dp))
        panel(window, ids, rings, regions, picked, enabled, coverage, accent, edge, onToggle,
              Modifier.width(width).height(width / window.aspect))
    }
}

@Composable
private fun panel(
    window: MapWindow,
    ids: Set<String>,
    rings: List<Coastline.Ring>,
    regions: List<NoaaController.Region>,
    picked: Set<String>,
    enabled: Boolean,
    coverage: Map<String, List<NoaaController.Box>>,
    accent: Color,
    edge: Color,
    onToggle: (String) -> Unit,
    modifier: Modifier,
) {
    val mine = remember(regions, ids) { regions.filter { ids.contains(it.id) } }
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(10.dp),
        color = WATER,
        border = BorderStroke(1.dp, edge),
    ) {
        Canvas(
            Modifier.fillMaxSize().clip(RoundedCornerShape(10.dp)).pointerInput(enabled, mine, coverage) {
                if (!enabled) return@pointerInput
                detectTapGestures { at ->
                    val hit = mine.firstOrNull { r ->
                        boxesOf(r, coverage).any { b ->
                            val x0 = window.x(b.west, size.toSize())
                            val x1 = window.x(b.east, size.toSize())
                            val y0 = window.y(b.north, size.toSize())
                            val y1 = window.y(b.south, size.toSize())
                            at.x in min(x0, x1)..max(x0, x1) && at.y in min(y0, y1)..max(y0, y1)
                        }
                    }
                    if (hit != null) onToggle(hit.id)
                }
            },
        ) {
            drawLand(rings, window)
            for (r in mine) {
                val on = picked.contains(r.id)
                drawRegion(boxesOf(r, coverage), window, accent.copy(alpha = if (on) 0.5f else 0.16f))
            }
        }
    }
}

/** The catalog's boxes for a region, or its rough extent until the catalog is
 *  in. One rectangle claims water a district does not cover, so the boxes are
 *  used the moment they exist. */
private fun boxesOf(
    r: NoaaController.Region,
    coverage: Map<String, List<NoaaController.Box>>,
): List<NoaaController.Box> {
    val c = coverage[r.id]
    if (!c.isNullOrEmpty()) return c
    return listOf(NoaaController.Box(r.west, r.south, r.east, r.north))
}

/**
 * Every ring that reaches into this window. Land and lakes are drawn in level
 * order, so a lake paints water back over the land it sits in.
 */
private fun DrawScope.drawLand(rings: List<Coastline.Ring>, window: MapWindow) {
    for (level in intArrayOf(1, 2)) {
        val path = Path()
        for (ring in rings) {
            if (ring.level != level) continue
            if (!ring.touches(window.west, window.south, window.east, window.north)) continue
            for (i in ring.lon.indices) {
                val x = window.x(ring.lon[i].toDouble(), size)
                val y = window.y(ring.lat[i].toDouble(), size)
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            path.close()
        }
        drawPath(path, if (level == 1) LAND else WATER)
    }
}

/** One region's coverage, as a single path so overlapping cells do not stack
 *  their fill into a darker patch. */
private fun DrawScope.drawRegion(
    boxes: List<NoaaController.Box>,
    window: MapWindow,
    color: Color,
) {
    val path = Path()
    for (b in boxes) {
        val x0 = window.x(b.west, size)
        val x1 = window.x(b.east, size)
        val y0 = window.y(b.north, size)
        val y1 = window.y(b.south, size)
        path.addRect(
            androidx.compose.ui.geometry.Rect(
                Offset(min(x0, x1), min(y0, y1)),
                Size(max(max(x1 - x0, x0 - x1), 1.5f), max(max(y1 - y0, y0 - y1), 1.5f)),
            ),
        )
    }
    drawPath(path, color)
}
