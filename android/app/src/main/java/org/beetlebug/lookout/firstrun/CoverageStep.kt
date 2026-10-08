package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.charts.NoaaController
import org.beetlebug.lookout.charts.NoaaRegionPicker

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Which waters to download.
 *
 * A region is a Coast Guard district, the unit NOAA files a cell under. The
 * core turns a pick into the cells that cover that water, including the ones
 * NOAA files next door, so a region downloads without a gap along its border.
 *
 * The picker itself is shared with the Charts pane, which asks the same
 * question after setup has run.
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
        NoaaRegionPicker(noaa)
    }
}
