package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.charts.ChartImport
import org.beetlebug.lookout.charts.NoaaController

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * The charts arriving, and turning into charts.
 *
 * A cell holds survey data, not a drawn chart, so every one is converted on
 * the way in. Three phases in order: the transfer, the scan that finds what
 * came, and the bake. Beside them the usage bands, because the bake runs
 * coarse band first and stopping partway still leaves charts that cover the
 * whole passage.
 */
@Composable
fun ImportingStep(
    flow: FirstRunModel,
    noaa: NoaaController,
    work: ChartImport.State?,
    onStop: () -> Unit,
) {
    val order = flow.order
    val downloading = noaa.phase == NoaaController.Phase.DOWNLOADING
    val baking = work?.running == true
    val fetched = if (order != null && noaa.total > 0) noaa.done else 0
    val expected = if (order != null && noaa.total > 0) noaa.total else order?.charts ?: 0

    Column(
        Modifier.fillMaxWidth().padding(stepInset).padding(top = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        StepHeading(
            title = "Preparing your charts",
            blurb = "A cell holds survey data, not a drawn chart, so Lookout converts each one on the way in. This happens once per set.",
        )

        Text(
            order?.regions ?: (work?.name ?: "Your charts"),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
        )
        if (order != null) {
            Text(
                "NOAA · ${order.charts} charts · ${NoaaController.sizeText(order.bytes)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // One bar for the whole job. A bar per phase reads as three jobs.
        val fraction = when {
            downloading && expected > 0 -> fetched.toFloat() / expected * 0.35f
            baking && (work?.total ?: 0) > 0 -> 0.35f + work!!.done.toFloat() / work.total * 0.65f
            work?.running == false && flow.sawBake -> 1f
            else -> 0f
        }
        if (fraction > 0f) {
            LinearProgressIndicator({ fraction }, Modifier.fillMaxWidth())
            Text(
                "${(fraction * 100).toInt()}%",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }

        phase(
            "Downloading charts",
            if (expected > 0) "$fetched of $expected" else "",
            running = downloading,
            done = order != null && !downloading,
        )
        phase(
            "Finding charts",
            if ((work?.total ?: 0) > 0) "${work!!.total} found" else "",
            running = work != null && work.running && work.total == 0,
            done = (work?.total ?: 0) > 0,
        )
        phase(
            "Importing charts",
            if ((work?.total ?: 0) > 0) "${work!!.done} of ${work.total}" else "",
            running = baking,
            done = flow.sawBake && work?.running == false,
        )

        Text(
            "Lookout stores the prepared charts in its own folder and never writes to your download.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        bandPanel(work)

        if (downloading || baking) {
            TextButton(onClick = onStop) { Text("Stop") }
        }
    }
}

/** One phase of the job: what it is, how far it got, and whether it is over. */
@Composable
private fun phase(name: String, detail: String, running: Boolean, done: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        when {
            done -> Icon(
                Icons.Filled.Check,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(16.dp),
            )
            running -> CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            else -> Spacer(Modifier.size(16.dp))
        }
        Spacer(Modifier.width(10.dp))
        Text(
            name,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = if (running) FontWeight.SemiBold else FontWeight.Normal,
            color = if (running || done) MaterialTheme.colorScheme.onSurface
                    else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.weight(1f))
        Text(
            detail,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** The usage bands, coarse first, which is the order the bake runs in. */
@Composable
private fun bandPanel(work: ChartImport.State?) {
    Surface(
        Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("By band", style = MaterialTheme.typography.titleSmall,
                 fontWeight = FontWeight.SemiBold)
            Text(
                "Wide-area charts are prepared first, so stopping partway still leaves charts that cover the whole passage.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            val bands = work?.bandProgress.orEmpty()
            if (bands.isEmpty()) {
                HorizontalDivider()
                Text(
                    "Counted once the folder has been read.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                for (b in bands) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(b.name, style = MaterialTheme.typography.bodySmall,
                             modifier = Modifier.width(96.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(
                            if (b.done >= b.total) "${b.total} charts"
                            else "${b.done} of ${b.total}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.weight(1f))
                        if (b.done >= b.total) {
                            Icon(
                                Icons.Filled.Check,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(14.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}
