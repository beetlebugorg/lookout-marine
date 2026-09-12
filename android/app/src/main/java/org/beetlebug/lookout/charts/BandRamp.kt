package org.beetlebug.lookout.charts

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.dp

/**
 * What scales a chart set holds.
 *
 * One bar in the S-52 depth ramp, split by usage band, finest first. A set
 * that stops at Coastal does not draw the harbour a passage ends in, and the
 * width of each band says how much of the set is at that scale.
 */
@Composable
fun BandRamp(counts: List<Pair<Int, Int>>, dimmed: Boolean = false, modifier: Modifier = Modifier) {
    if (counts.isEmpty()) return
    // Finest first, matching the ramp from deep colour to pale.
    val ordered = counts.sortedByDescending { it.first }
    val total = ordered.sumOf { it.second }.coerceAtLeast(1)
    val alpha = if (dimmed) 0.5f else 1f

    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        // A hairline between the segments. Four of the six bands are the pale
        // end of the ramp, and side by side in a 9dp bar they read as one
        // stripe.
        Row(
            Modifier
                .fillMaxWidth()
                .height(9.dp)
                .clip(RoundedCornerShape(50))
                .background(MaterialTheme.colorScheme.outlineVariant),
            horizontalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            for ((band, n) in ordered) {
                Box(
                    Modifier
                        // A library of 7,000 cells holds two dozen overviews,
                        // and a band the legend counts has to be on the bar.
                        .weight(n.toFloat() / total)
                        .widthIn(min = 4.dp)
                        .fillMaxHeight()
                        .background(bandColor(band).copy(alpha = alpha)),
                )
            }
        }
        FlowLegend(ordered, alpha)
    }
}

/** The bands under the bar. Wraps rather than scrolls: six fit two lines at
 *  any width the pane comes up at. */
@Composable
private fun FlowLegend(ordered: List<Pair<Int, Int>>, alpha: Float) {
    Layout(
        content = {
            for ((band, n) in ordered) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(7.dp).clip(CircleShape).background(bandColor(band).copy(alpha = alpha)))
                    Spacer(Modifier.width(5.dp))
                    Text(
                        "${bandLabel(band)} $n",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(12.dp))
                }
            }
        },
        modifier = Modifier.fillMaxWidth(),
    ) { measurables, constraints ->
        val placeables = measurables.map { it.measure(constraints.copy(minWidth = 0)) }
        var x = 0
        var y = 0
        var rowHeight = 0
        val spots = ArrayList<Pair<Int, Int>>(placeables.size)
        for (p in placeables) {
            if (x + p.width > constraints.maxWidth && x > 0) {
                x = 0
                y += rowHeight + 4
                rowHeight = 0
            }
            spots.add(x to y)
            x += p.width
            rowHeight = maxOf(rowHeight, p.height)
        }
        layout(constraints.maxWidth, y + rowHeight) {
            placeables.forEachIndexed { i, p -> p.place(spots[i].first, spots[i].second) }
        }
    }
}

/**
 * The S-52 depth ramp, coarse to fine: the wide-area bands take the pale end
 * and a berthing chart the deep one, so a set's shape reads the way a chart's
 * water does.
 */
private fun bandColor(band: Int): Color = when (band) {
    1 -> Color(0xFFEAF4FC)
    2 -> Color(0xFFD6EAF8)
    3 -> Color(0xFFB9DCF2)
    4 -> Color(0xFF8FC5E8)
    5 -> Color(0xFF5AA4D6)
    else -> Color(0xFF2E7DB5)
}

private fun bandLabel(band: Int): String = when (band) {
    1 -> "Overview"
    2 -> "General"
    3 -> "Coastal"
    4 -> "Approach"
    5 -> "Harbor"
    6 -> "Berthing"
    else -> "Other"
}
