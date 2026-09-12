package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.charts.CoverageMap
import org.beetlebug.lookout.charts.NoaaController

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * Which waters to download.
 *
 * A region is a Coast Guard district, the unit NOAA files a cell under. The
 * core turns a pick into the cells that cover that water, including the ones
 * NOAA files next door, so a region downloads without a gap along its border.
 *
 * Region sizes are per selection rather than per region: the cells overlap, so
 * per-region totals do not add up to the total. One accurate figure beats nine
 * that do not sum.
 */
@Composable
fun CoverageStep(noaa: NoaaController) {
    Column(
        Modifier.fillMaxWidth().padding(stepInset).padding(top = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        StepHeading(
            title = "Which waters do you sail?",
            blurb = "Pick the water you use. Lookout downloads those charts and prepares them. You can add the rest later.",
        )
        catalogLine(noaa)
        CoverageMap(
            regions = noaa.regions,
            picked = noaa.picked,
            enabled = noaa.haveCatalog,
            coverage = noaa.coverage,
            onToggle = { noaa.toggle(it) },
        )
        // Rows rather than a row of pills. Nine pills wrap to three ragged
        // lines on a phone; a row is the width of the screen, says which water
        // the region covers, and is a target a thumb cannot miss.
        Surface(
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surface,
            border = androidx.compose.foundation.BorderStroke(
                1.dp, MaterialTheme.colorScheme.outlineVariant,
            ),
        ) {
            Column {
                noaa.regions.forEachIndexed { i, r ->
                    if (i > 0) HorizontalDivider(Modifier.padding(start = 14.dp))
                    regionRow(r, noaa.picked.contains(r.id), noaa.haveCatalog) { noaa.toggle(r.id) }
                }
            }
        }
    }
}

/** Where NOAA's catalog stands, and a way to read it again after a failure. */
@Composable
private fun catalogLine(noaa: NoaaController) {
    when {
        noaa.phase == NoaaController.Phase.READING_CATALOG -> Row(
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
            Text(
                "Reading NOAA's chart catalog…",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        noaa.error != null -> Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                noaa.error ?: "",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.weight(1f, fill = false),
            )
            TextButton(onClick = { noaa.refresh() }) { Text("Try Again") }
        }
        noaa.haveCatalog -> Text(
            buildString {
                append("${noaa.catalogCells} charts published")
                if (noaa.date.isNotEmpty()) append(", catalog dated ${noaa.date}")
                append('.')
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun regionRow(
    r: NoaaController.Region,
    picked: Boolean,
    enabled: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .selectable(
                selected = picked,
                enabled = enabled,
                role = androidx.compose.ui.semantics.Role.Checkbox,
                onClick = onToggle,
            )
            .semantics { contentDescription = "region-${r.id}" }
            .padding(horizontal = 14.dp, vertical = 11.dp)
            .height(androidx.compose.ui.unit.Dp.Unspecified),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                r.name,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (picked) FontWeight.SemiBold else FontWeight.Normal,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                r.blurb,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.width(8.dp))
        RadioButton(selected = picked, onClick = null, enabled = enabled)
    }
}
