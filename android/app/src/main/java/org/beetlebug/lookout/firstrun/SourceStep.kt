package org.beetlebug.lookout.firstrun

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.Public
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/**
 * Where the charts come from.
 *
 * Three sources, and the mariner picks one to get started. The other two are
 * still there afterwards, in the Charts pane, which is what the line under the
 * question says.
 */
@Composable
fun SourceStep(flow: FirstRunModel) {
    Column(
        Modifier.fillMaxWidth().padding(stepInset).padding(top = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        StepHeading(
            title = "How would you like to add charts?",
            blurb = "You can add the other sources any time, from Charts in Mariner settings.",
        )
        SourceCard(
            icon = Icons.Outlined.Map,
            title = "NOAA charts",
            blurb = "Official ENC for every U.S. waterway, free. Downloaded to this device and prepared here.",
            recommended = true,
            picked = flow.source == FirstRunModel.Source.NOAA,
            onPick = { flow.source = FirstRunModel.Source.NOAA },
            modifier = Modifier.semantics { contentDescription = "source-NOAA charts" },
        )
        SourceCard(
            icon = Icons.Outlined.Public,
            title = "Online chart",
            blurb = "A published chart style. Renders straight away, worldwide, and stores nothing.",
            picked = flow.source == FirstRunModel.Source.ONLINE,
            onPick = { flow.source = FirstRunModel.Source.ONLINE },
            modifier = Modifier.semantics { contentDescription = "source-Online chart" },
        )
        SourceCard(
            icon = Icons.Outlined.FolderOpen,
            title = "Files on this device",
            blurb = "A prepared .pmtiles chart, or a folder of S-57 cells.",
            picked = flow.source == FirstRunModel.Source.FILES,
            onPick = { flow.source = FirstRunModel.Source.FILES },
            modifier = Modifier.semantics { contentDescription = "source-Files on this device" },
        )
    }
}
