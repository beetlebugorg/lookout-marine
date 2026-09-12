package org.beetlebug.lookout.charts

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
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
        noaa.noteInstalled(installedCellNames(charts))
        if (!noaa.haveCatalog) noaa.refresh()
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
                                "NOAA publishes an ENC for every United States waterway at no cost. Pick the water you sail.",
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
                    if (noaa.haveCatalog && (noaa.cells > 0 || noaa.held > 0)) {
                        Text(
                            costLine(noaa),
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
                    Button(
                        enabled = noaa.haveCatalog && noaa.picked.isNotEmpty(),
                        onClick = {
                            charts.noaaDir.mkdirs()
                            noaa.download(charts.noaaDir.absolutePath, noaa.allInstalled)
                            onDismiss()
                        },
                        modifier = Modifier.semantics { contentDescription = "noaa-download" },
                    ) { Text(if (noaa.allInstalled) "Download Again" else "Download") }
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

/**
 * The NOAA cells already installed, as dataset names without an extension.
 *
 * By name, which is all the core wants: a pick then prices what is missing
 * from the water rather than all of it.
 */
fun installedCellNames(charts: ChartsModel): List<String> =
    charts.sets.flatMap { set -> ChartSets.files(set.path).map { it.name } }
        .map { it.substringBefore('.') }
        .filter { it.startsWith("US") }
        .distinct()
