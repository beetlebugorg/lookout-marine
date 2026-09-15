package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.settings.DepthUnit
import org.beetlebug.lookout.settings.MarinerState

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * The depth settings, asked as two questions about the boat.
 *
 * The step asks for a draft and a clearance under the keel. It derives the two
 * S-52 numbers the engine draws with, the safety depth and the safety contour,
 * and states what each one does to the chart.
 *
 * The engine is always given metres, so feet convert on the way out.
 */
@Composable
fun DepthStep(m: MarinerState) {
    val feet = m.depthUnit == DepthUnit.FEET
    val unit = if (feet) "ft" else "m"

    // The boat, in the unit on screen. MarinerState keeps the numbers the
    // chart draws with; these two are the question behind them.
    //
    // Held in the unit on screen so every number displays round. A metric list
    // converted into feet gives a 4.9 ft clearance and a 16.4 ft contour.
    var draft by remember { mutableStateOf(if (feet) 5.5 else 1.7) }
    var clearance by remember { mutableStateOf(if (feet) 2.0 else 0.6) }

    val clearances = if (feet) listOf(1.0, 2.0, 3.0, 5.0) else listOf(0.3, 0.6, 1.0, 1.5)
    // The contours an S-57 survey draws. The safety contour is the first of
    // these at or past the safety depth, because the chart shades on a contour
    // the survey has.
    val ladder = if (feet) listOf(6.0, 12.0, 18.0, 30.0, 60.0, 90.0, 120.0, 180.0, 240.0, 300.0)
                 else listOf(2.0, 5.0, 10.0, 20.0, 30.0, 50.0, 75.0, 100.0)

    // Draft plus clearance, rounded up to a whole foot or metre. A chart names
    // its depths in whole numbers, and the fraction belongs to the keel rather
    // than to the water.
    val safetyDepth = ceil(draft + clearance)
    val safetyContour = ladder.firstOrNull { it >= safetyDepth } ?: ladder.last()
    // The step does not ask for the deep contour, so it comes off the same
    // ladder and displays round.
    val deepContour = ladder.firstOrNull { it >= safetyContour * 2 } ?: ladder.last()

    fun metres(v: Double) = if (feet) v / 3.28084 else v

    // Every change goes to the engine, so the chart behind the page is already
    // drawn the mariner's way when the page closes.
    LaunchedEffect(safetyDepth, safetyContour, deepContour, feet) {
        m.safetyDepth = metres(safetyDepth)
        m.safetyContour = metres(safetyContour)
        m.deepContour = metres(deepContour)
        m.shallowContour = metres(min(safetyContour, max(ladder.first(), safetyDepth)))
    }

    Column(
        Modifier.fillMaxWidth().padding(stepInset).padding(top = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        StepHeading(
            title = "How deep does your boat sit?",
            blurb = "Lookout shades water your boat cannot cross. It needs one number to do that, and everything else follows from it.",
        )

        numberRow("Draft", draft, unit, step = if (feet) 0.5 else 0.1) { draft = it }
        Text(
            "Deepest point of the hull below the waterline, keel included.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Units", style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.width(12.dp))
            SingleChoiceSegmentedButtonRow {
                listOf(DepthUnit.METERS, DepthUnit.FEET).forEachIndexed { i, u ->
                    SegmentedButton(
                        selected = m.depthUnit == u,
                        onClick = {
                            if (m.depthUnit == u) return@SegmentedButton
                            // The boat does not change when the unit does.
                            val toFeet = u == DepthUnit.FEET
                            val k = if (toFeet) 3.28084 else 1 / 3.28084
                            draft = round1(draft * k)
                            val want = clearance * k
                            val list = if (toFeet) listOf(1.0, 2.0, 3.0, 5.0)
                                       else listOf(0.3, 0.6, 1.0, 1.5)
                            clearance = list.minByOrNull { kotlin.math.abs(it - want) } ?: list[1]
                            m.depthUnit = u
                        },
                        shape = SegmentedButtonDefaults.itemShape(i, 2),
                    ) { Text(if (u == DepthUnit.FEET) "Feet" else "Meters") }
                }
            }
        }

        Text(
            "Clearance under the keel",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (c in clearances) {
                FilterChip(
                    selected = clearance == c,
                    onClick = { clearance = c },
                    label = { Text("${trim(c)} $unit") },
                )
            }
        }
        Text(
            "How much water you want left under the keel at the shallowest point of a passage.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        HorizontalDivider()
        derived("Safety depth", "${trim(safetyDepth)} $unit",
                "Soundings at or shallower than this print bold. It does not shade water.")
        derived("Safety contour", "${trim(safetyContour)} $unit",
                "Water shallower than this shades as unsafe. Rounded up to a contour the survey draws, so ${trim(safetyDepth)} $unit reads as ${trim(safetyContour)} $unit.")
        derived("Deep contour", "${trim(deepContour)} $unit",
                "Water deeper than this draws in the lightest shade. Twice the safety contour, up the same ladder the safety contour came off.")

        seabed(safetyDepth, safetyContour, deepContour, unit)
        StepWarning(
            lead = "Shading is not a depth sounder.",
            body = "Soundings are not corrected for tide, surge or squat, and a survey can be decades old. Keep your own margin.",
        )
    }
}

/** A number with a step either side of it. */
@Composable
private fun numberRow(
    label: String,
    value: Double,
    unit: String,
    step: Double,
    onChange: (Double) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.weight(1f))
        Surface(
            shape = RoundedCornerShape(10.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary),
            color = MaterialTheme.colorScheme.surface,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                stepper("−") { onChange(max(step, round1(value - step))) }
                Text(
                    "${trim(value)} $unit",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.width(86.dp).semantics {
                        contentDescription = "depth-draft"
                    },
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
                stepper("+") { onChange(round1(value + step)) }
            }
        }
    }
}

@Composable
private fun stepper(glyph: String, onClick: () -> Unit) {
    androidx.compose.material3.TextButton(onClick = onClick) {
        Text(glyph, style = MaterialTheme.typography.titleMedium)
    }
}

/** One number the step worked out, and what it does to the chart. */
@Composable
private fun derived(name: String, value: String, blurb: String) {
    Column {
        Row {
            Text(name, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            Text(
                value,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Text(
            blurb,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * The four shades, over a slope that runs from the shore out to deep water.
 *
 * The soundings are the seabed and hold still; the shading is the mariner's
 * and moves over them. Measured in contours rather than metres because the
 * answers span a dinghy and a ship: a fixed 40 m slope puts a 5 ft contour in
 * the first pixel of the panel and a 30 ft one halfway up it.
 */
@Composable
private fun seabed(safetyDepth: Double, safetyContour: Double, deepContour: Double, unit: String) {
    val unsafe = s52("DEPVS", Color(0xFF9BD3FF))
    val shallow = s52("DEPMS", Color(0xFFBFE3FF))
    val medium = s52("DEPMD", Color(0xFFDDF0FF))
    val deep = s52("DEPDW", Color(0xFFF2F9FF))
    val land = s52("LANDA", Color(0xFFD9CFA8))

    // The soundings are the seabed and hold still; the shading is the
    // mariner's and moves over them. Their depths are multiples of the safety
    // contour, so a sounding keeps its place and its number while the mariner
    // works and moves only when the contour steps to the next one the survey
    // draws.
    val density = LocalDensity.current.density
    val paint = remember(density) {
        android.graphics.Paint().apply {
            isAntiAlias = true
            textSize = 10.5f * density
            textAlign = android.graphics.Paint.Align.CENTER
        }
    }

    val floor = deepContour * 1.5
    fun reach(d: Double): Float {
        if (floor <= 0) return SHORE_AT
        val f = (max(0.0, min(1.0, d / floor))).pow(1 / SLOPE_K)
        return SHORE_AT + (1 - SHORE_AT) * f.toFloat()
    }

    Column {
        Surface(
            Modifier.fillMaxWidth().aspectRatio(1.8f),
            shape = RoundedCornerShape(10.dp),
            color = deep,
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        ) {
            Canvas(Modifier.fillMaxSize()) {
                drawPath(shoal(reach(deepContour)), medium)
                drawPath(shoal(reach(safetyContour)), shallow)
                drawPath(shoal(reach(safetyDepth)), unsafe)
                // The safety contour, drawn bold the way S-52 draws the
                // contour the boat is measured against.
                drawPath(shoal(reach(safetyContour)), Color.Black.copy(alpha = 0.45f),
                         style = Stroke(width = 2f))
                drawPath(shoal(reach(deepContour)), Color.Black.copy(alpha = 0.18f),
                         style = Stroke(width = 1f))
                drawPath(shoal(SHORE_AT), land)
                drawPath(shoal(SHORE_AT), Color.Black.copy(alpha = 0.45f),
                         style = Stroke(width = 1f))
                for (spot in SPOTS) {
                    val depth = safetyContour * spot.first
                    val at = point(reach(depth), spot.second)
                    val bold = depth <= safetyDepth
                    paint.color = android.graphics.Color.argb(
                        if (bold) 204 else 140, 0, 0, 0,
                    )
                    paint.isFakeBoldText = bold
                    drawContext.canvas.nativeCanvas.drawText(
                        kotlin.math.ceil(depth).toInt().toString(),
                        at.x, at.y + paint.textSize * 0.35f, paint,
                    )
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            key(unsafe, "Unsafe", "0 – ${trim(safetyContour)} $unit", Modifier.weight(1f))
            key(shallow, "Shallow", "${trim(safetyContour)} – ${trim(deepContour)} $unit", Modifier.weight(1f))
            key(medium, "Medium", "${trim(deepContour)} $unit +", Modifier.weight(1f))
            key(deep, "Deep", "open water", Modifier.weight(1f))
        }
    }
}

@Composable
private fun key(color: Color, name: String, range: String, modifier: Modifier = Modifier) {
    Column(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(11.dp).background(color, RoundedCornerShape(3.dp)),
            )
            Spacer(Modifier.width(6.dp))
            Text(name, style = MaterialTheme.typography.labelMedium, maxLines = 1)
        }
        Text(
            range,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
        )
    }
}

/**
 * One depth line across the panel, closed to the bottom.
 *
 * Every line is the same shape moved up by its depth, so each band keeps its
 * share of the panel from edge to edge. Scaling the curve by the depth instead
 * gathers them all into one corner.
 */
private fun DrawScope.shoal(t: Float): Path {
    val p = Path()
    p.moveTo(0f, size.height)
    for (i in 0..STEPS) {
        val u = i.toFloat() / STEPS
        val at = point(t, u)
        if (i == 0) p.lineTo(at.x, at.y) else p.lineTo(at.x, at.y)
    }
    p.lineTo(size.width, size.height)
    p.close()
    return p
}

/** A point on one depth line, `u` of the way across. The wave and the rise to
 *  the right are the same for every line, so the lines never cross and the
 *  bands never pinch. */
private fun DrawScope.point(t: Float, u: Float): Offset {
    val wave = 0.055f * sin(u * PI.toFloat() * 1.7f + 0.4f) + 0.045f * u
    return Offset(u * size.width, size.height - size.height * t + size.height * wave)
}

/** One colour the engine draws with, or a fallback when the table has no
 *  answer, so the page draws rather than blanking. */
private fun s52(token: String, fallback: Color): Color {
    val rgba = FloatArray(4)
    if (!Lookout.s52Color(token, 0, rgba)) return fallback
    return Color(rgba[0], rgba[1], rgba[2], rgba[3])
}

private fun round1(v: Double) = kotlin.math.round(v * 10.0) / 10.0

/** A depth as a mariner writes it: no trailing zero on a whole number. */
private fun trim(v: Double): String =
    if (v == kotlin.math.floor(v)) v.toInt().toString() else String.format("%.1f", v)

/** Each spot depth: how deep it is as a multiple of the safety contour, and
 *  how far along its line it stands. */
private val SPOTS = listOf(
    0.12 to 0.28f, 0.30 to 0.68f, 0.45 to 0.14f, 0.62 to 0.50f,
    0.80 to 0.84f, 1.00 to 0.32f, 1.22 to 0.62f, 1.48 to 0.20f,
    1.78 to 0.44f, 2.12 to 0.78f, 2.50 to 0.34f, 2.85 to 0.58f,
)

private const val SHORE_AT = 0.14f
/** How steeply the slope falls away. Shallow water gets most of the panel,
 *  because that is where both contours fall. */
private const val SLOPE_K = 2.07
private const val STEPS = 48
