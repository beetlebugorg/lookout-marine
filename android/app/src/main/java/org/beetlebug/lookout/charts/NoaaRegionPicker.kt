package org.beetlebug.lookout.charts

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.foundation.layout.padding

/**
 * Picking NOAA's waters: the catalog line, the map, and the regions as rows.
 *
 * Setup asks this on its coverage step, and the Charts pane asks it again
 * afterwards. One picker, so the two places name the same regions and price
 * them the same way.
 *
 * Region sizes are per selection rather than per region. The core includes
 * every cell covering a region's water, including the ones NOAA files under
 * the district next door, so per-region totals overlap and do not add up to
 * the total. One accurate total beats nine numbers that do not sum.
 */
@Composable
fun NoaaRegionPicker(noaa: NoaaController) {
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
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
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
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

/**
 * What the pick costs, and what of it is already here. Water wholly installed
 * prices as that rather than reading as an empty pick.
 */
fun costLine(noaa: NoaaController): String {
    val charts = if (noaa.cells == 1) "1 chart" else "${noaa.cells} charts"
    return when {
        noaa.cells == 0 -> "${noaa.held} charts, all installed"
        noaa.held > 0 -> "$charts, ${NoaaController.sizeText(noaa.bytes)} · ${noaa.held} already installed"
        else -> "$charts, ${NoaaController.sizeText(noaa.bytes)}"
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
