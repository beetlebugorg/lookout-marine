package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.hud.Chrome

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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.toSize
import kotlin.math.max
import kotlin.math.min

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

/** The ground one panel covers. The core projects onto it, in Mercator. */
class MapWindow(val west: Double, val south: Double, val east: Double, val north: Double) {
    /** Width over height, so a panel keeps its shape at any size. */
    val aspect: Float get() = Lookout.mapAspect(west, east, south, north).toFloat()

    /** Longitude and latitude pairs as x and y pairs in a rectangle of [size]. */
    fun project(lonlat: DoubleArray, size: Size): FloatArray =
        Lookout.mapProject(west, east, south, north, size.width, size.height, lonlat)

    /** Each box's corners, north-west then south-east, projected. */
    fun corners(boxes: List<NoaaController.Box>, size: Size): FloatArray {
        val lonlat = DoubleArray(boxes.size * 4)
        boxes.forEachIndexed { i, b ->
            lonlat[i * 4] = b.west
            lonlat[i * 4 + 1] = b.north
            lonlat[i * 4 + 2] = b.east
            lonlat[i * 4 + 3] = b.south
        }
        return project(lonlat, size)
    }
}

private val MAIN = MapWindow(-132.0, 20.0, -64.0, 52.0)
private val ALASKA = MapWindow(-172.0, 50.5, -128.0, 72.0)
private val HAWAII = MapWindow(-161.0, 18.3, -154.0, 22.6)

/** S-52 very shallow water and land, so the picker sits in the chart's own
 *  palette rather than the system's. */
@Composable
private fun water() = Chrome.s52("DEPMD").copy(alpha = 0.55f)

@Composable
private fun land() = Chrome.s52("LANDA").copy(alpha = 0.55f)

@Composable
fun CoverageMap(
    regions: List<NoaaController.Region>,
    picked: Set<String>,
    enabled: Boolean,
    coverage: Map<String, List<NoaaController.Box>>,
    onToggle: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = MaterialTheme.colorScheme.primary
    val edge = MaterialTheme.colorScheme.outlineVariant

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        panel(MAIN, Lookout.PANEL_LOWER48, regions, picked, enabled, coverage, accent, edge, onToggle,
              Modifier.fillMaxWidth().aspectRatio(MAIN.aspect))
        // Alaska and Hawaii keep their own frames, under the map rather than
        // in a corner of it: on a narrow screen a frame in the corner covers
        // the west coast, and a region cannot be picked through another one.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            inset("Alaska", ALASKA, Lookout.PANEL_ALASKA, regions, picked, enabled, coverage,
                  accent, edge, onToggle, 104.dp)
            inset("Hawaii", HAWAII, Lookout.PANEL_HAWAII, regions, picked, enabled, coverage,
                  accent, edge, onToggle, 56.dp)
        }
    }
}

@Composable
private fun inset(
    label: String,
    window: MapWindow,
    which: Int,
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
        panel(window, which, regions, picked, enabled, coverage, accent, edge, onToggle,
              Modifier.width(width).height(width / window.aspect))
    }
}

@Composable
private fun panel(
    window: MapWindow,
    which: Int,
    regions: List<NoaaController.Region>,
    picked: Set<String>,
    enabled: Boolean,
    coverage: Map<String, List<NoaaController.Box>>,
    accent: Color,
    edge: Color,
    onToggle: (String) -> Unit,
    modifier: Modifier,
) {
    val mine = remember(regions, which) { regions.filter { it.panel == which } }
    val water = water()
    val land = land()
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(10.dp),
        color = water,
        border = BorderStroke(1.dp, edge),
    ) {
        Canvas(
            Modifier.fillMaxSize().clip(RoundedCornerShape(10.dp)).pointerInput(enabled, mine, coverage) {
                if (!enabled) return@pointerInput
                detectTapGestures { at ->
                    val hit = mine.firstOrNull { r ->
                        val c = window.corners(boxesOf(r, coverage), size.toSize())
                        (0 until c.size / 4).any { i ->
                            val x0 = c[i * 4]
                            val y0 = c[i * 4 + 1]
                            val x1 = c[i * 4 + 2]
                            val y1 = c[i * 4 + 3]
                            at.x in min(x0, x1)..max(x0, x1) && at.y in min(y0, y1)..max(y0, y1)
                        }
                    }
                    if (hit != null) onToggle(hit.id)
                }
            },
        ) {
            drawLand(window, land, water)
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
 * The coastline rings that reach into this window. Land and lakes are drawn in
 * level order, so a lake paints water back over the land it sits in.
 */
private fun DrawScope.drawLand(window: MapWindow, land: Color, water: Color) {
    for (level in intArrayOf(Lookout.COAST_LAND, Lookout.COAST_LAKE)) {
        val rings = Lookout.coastlineRings(level, window.west, window.east, window.south,
                                           window.north, size.width, size.height)
        val xy = rings[0] as FloatArray
        val ends = rings[1] as IntArray
        val path = Path()
        var start = 0
        for (end in ends) {
            path.moveTo(xy[start * 2], xy[start * 2 + 1])
            for (i in start + 1 until end) path.lineTo(xy[i * 2], xy[i * 2 + 1])
            path.close()
            start = end
        }
        drawPath(path, if (level == Lookout.COAST_LAND) land else water)
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
    val c = window.corners(boxes, size)
    for (i in 0 until c.size / 4) {
        val x0 = c[i * 4]
        val y0 = c[i * 4 + 1]
        val x1 = c[i * 4 + 2]
        val y1 = c[i * 4 + 3]
        path.addRect(
            androidx.compose.ui.geometry.Rect(
                Offset(min(x0, x1), min(y0, y1)),
                Size(max(max(x1 - x0, x0 - x1), 1.5f), max(max(y1 - y0, y0 - y1), 1.5f)),
            ),
        )
    }
    drawPath(path, color)
}
