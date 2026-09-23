package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/**
 * Picking NOAA's waters from the Charts pane, after setup has run.
 *
 * Over the whole screen rather than in the settings list. The picker is a map
 * of the country, and in a list it came up as a strip between two rows with
 * the map squeezed into it. It is the same reason the Mac gives it a window of
 * its own.
 */
@Composable
fun NoaaPickerDialog(
    charts: ChartsModel,
    noaa: NoaaController,
    onDismiss: () -> Unit,
) {
    // The catalog, and what this device already holds, so a pick prices what
    // is missing from the water rather than all of it.
    LaunchedEffect(Unit) {
        noaa.reprice()
        if (!noaa.haveCatalog) noaa.refresh()
    }
    // The regions held whole when this opened, ticked. Unticking one of these
    // gives it back. Unticking one that was never here is a change of mind
    // before Apply. The catalog prices a region, so this waits for it.
    var held by remember { mutableStateOf<Set<String>?>(null) }
    var confirmRemoval by remember { mutableStateOf(false) }
    LaunchedEffect(noaa.haveCatalog) {
        if (noaa.haveCatalog && held == null) noaa.pickRecorded { held = it }
    }
    val removing = noaa.regions.filter { held.orEmpty().contains(it.id) && it.id !in noaa.picked }
    val adding = noaa.cells > 0
    // Both halves in one core call. The removal runs first, so swapping one
    // region for another does not hold both on the disk at once.
    val apply = {
        charts.noaaDir.mkdirs()
        noaa.apply(charts.noaaDir.absolutePath) { moved -> if (moved > 0) charts.pullSets() }
        onDismiss()
    }
    if (confirmRemoval) {
        val whole = noaa.picked.isEmpty()
        val n = charts.sets.firstOrNull { it.managed }?.charts ?: 0
        AlertDialog(
            onDismissRequest = { confirmRemoval = false },
            title = {
                Text(when {
                    whole -> "Remove all NOAA charts?"
                    removing.size == 1 -> "Remove ${removing[0].name} charts?"
                    else -> "Remove charts for ${removing.size} regions?"
                })
            },
            text = {
                Text(
                    (if (whole) "Lookout deletes all $n charts it downloaded, and the folder they are in."
                     else "Lookout deletes the charts it downloaded for this water.") +
                        " Charts you added yourself stay where they are, and you can download this water again.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmRemoval = false
                    apply()
                }) { Text("Remove") }
            },
            dismissButton = { TextButton(onClick = { confirmRemoval = false }) { Text("Cancel") } },
        )
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize()) {
                Spacer(
                    Modifier.height(
                        WindowInsets.statusBars.asPaddingValues().calculateTopPadding(),
                    ),
                )
                Text(
                    "NOAA charts",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth().padding(16.dp),
                )
                HorizontalDivider()
                Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                        Column(
                            Modifier.widthIn(max = 620.dp).padding(20.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text(
                                "NOAA publishes an ENC for every United States waterway at no cost. Tick the water you sail. Unticking water you hold removes those charts.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            NoaaRegionPicker(noaa)
                        }
                    }
                }
                HorizontalDivider()
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (noaa.haveCatalog && (noaa.cells > 0 || noaa.held > 0 || removing.isNotEmpty())) {
                        // What Apply is about to do.
                        val plan = listOfNotNull(
                            if (adding) "Add ${Lookout.fmtCount(noaa.cells.toLong())} charts, ${Lookout.fmtBytes(noaa.bytes)}" else null,
                            if (removing.isNotEmpty()) "remove ${removing.joinToString(", ") { it.name }}" else null,
                        )
                        Text(
                            if (plan.isEmpty()) costLine(noaa) else plan.joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                    // Water already held is fetched again rather than left with
                    // a dead button. It is how a mariner repairs a set, or gets
                    // the current edition of one NOAA has reissued.
                    if (noaa.allInstalled && removing.isEmpty()) {
                        TextButton(
                            onClick = {
                                charts.noaaDir.mkdirs()
                                noaa.download(charts.noaaDir.absolutePath, true)
                                onDismiss()
                            },
                            modifier = Modifier.semantics { contentDescription = "noaa-download-again" },
                        ) { Text("Download Again") }
                    }
                    // Removing charts needs one question. Adding them does not:
                    // the line beside this states the cost.
                    Button(
                        enabled = noaa.haveCatalog && (adding || removing.isNotEmpty()),
                        onClick = { if (removing.isEmpty()) apply() else { confirmRemoval = true } },
                        modifier = Modifier.semantics { contentDescription = "noaa-apply" },
                    ) { Text("Apply") }
                }
                Spacer(
                    Modifier.height(
                        WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding(),
                    ),
                )
            }
        }
    }
}
