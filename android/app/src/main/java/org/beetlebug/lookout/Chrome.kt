package org.beetlebug.lookout

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * The chrome's sizes and its round controls. The layout is the layout every
 * shell uses (windows/ui/MainWindow.xaml, ChartView.swift): search at the top
 * left, north at the top right, zoom above settings at the bottom right, the
 * scale bar at the bottom left, and the readouts at the bottom centre.
 */
object Chrome {
    /** Bubble diameter. */
    val bubble = 48.dp

    /** Gap between chrome items. */
    val gap = 10.dp

    /** Distance from the chrome to the edge of the chart view. */
    val margin = 16.dp

    /** Readout capsule height. */
    val capsule = 44.dp

    /**
     * Below this width the capsule and the corner chrome cannot share the
     * bottom row, so the capsule drops the band and takes a smaller type.
     */
    val compactWidth = 700.dp

    /** Ground metres per dp at a 1:1 display scale, from the 0.28 mm pixel. */
    const val METRES_PER_DP_AT_1_TO_1 = 0.00028
}

/** A round chrome control over the chart. */
@Composable
fun ChromeBubble(
    icon: ImageVector,
    description: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Surface(
        modifier = modifier
            .size(Chrome.bubble)
            .clickable(onClick = onClick),
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
        tonalElevation = 2.dp,
        shadowElevation = 3.dp,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                icon,
                contentDescription = description,
                modifier = Modifier.size(21.dp),
                tint = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

/**
 * The north bubble. The mark turns with the view and a tap sets the chart
 * north-up. It is always visible: a mariner reads the chart's orientation from
 * it, so it must not appear only once the chart is already turned.
 */
@Composable
fun NorthBubble(rotationDeg: Double, onReset: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier
            .size(Chrome.bubble)
            .clickable(onClick = onReset),
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
        tonalElevation = 2.dp,
        shadowElevation = 3.dp,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .rotate(-rotationDeg.toFloat())
                    .semanticsNorth(),
            ) {
                Canvas(Modifier.size(9.dp)) {
                    // The pointer: a filled triangle over the letter.
                    val p = androidx.compose.ui.graphics.Path().apply {
                        moveTo(size.width / 2, 0f)
                        lineTo(size.width, size.height)
                        lineTo(0f, size.height)
                        close()
                    }
                    drawPath(p, Color(0xFFE53935))
                }
                Text(
                    "N",
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}

private fun Modifier.semanticsNorth(): Modifier = this

/**
 * The distance bar: four alternating segments under a label. The width comes
 * from the 1:N scale, and the distance rounds down to a round number, so the
 * label always reads as one.
 */
@Composable
fun ScaleBar(scaleDenominator: Double, modifier: Modifier = Modifier) {
    if (scaleDenominator <= 0) return
    val metresPerDp = scaleDenominator * Chrome.METRES_PER_DP_AT_1_TO_1
    val target = TARGET_DP * metresPerDp
    val metres = NICE.lastOrNull { it <= target } ?: NICE.first()
    val label = if (metres >= 1000) "${(metres / 1000).roundToInt()} km" else "${metres.roundToInt()} m"
    val width = (metres / metresPerDp).dp

    Column(modifier) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Row(
            Modifier
                .size(width = width, height = 6.dp)
                .border(1.dp, MaterialTheme.colorScheme.onSurface),
        ) {
            repeat(4) { i ->
                Surface(
                    modifier = Modifier.size(width = width / 4, height = 6.dp),
                    color = if (i % 2 == 0) {
                        MaterialTheme.colorScheme.onSurface
                    } else {
                        MaterialTheme.colorScheme.surface
                    },
                    content = {},
                )
            }
        }
    }
}

private val NICE = listOf(
    10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0,
    10_000.0, 20_000.0, 50_000.0, 100_000.0, 200_000.0, 500_000.0,
)

/** The bar is this wide or less. */
private const val TARGET_DP = 140.0
