package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.R

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp

/**
 * What this is, and the ways to get a chart.
 *
 * The hero is a real ENC, the app's own day screenshot, so the promise is
 * visible before anything downloads. The rows below answer what to do next.
 */
@Composable
fun WelcomeStep() {
    Column(Modifier.fillMaxWidth()) {
        // Edge to edge, and cropped to the band rather than letterboxed: the
        // picture is a chart, not a diagram, so which part shows matters less
        // than that it fills.
        Image(
            painterResource(R.drawable.welcome_chart),
            contentDescription = "A Lookout chart of Annapolis",
            modifier = Modifier.fillMaxWidth().height(190.dp),
            contentScale = ContentScale.Crop,
        )
        Column(
            Modifier.padding(stepInset).padding(top = 22.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            StepHeading(
                title = "Welcome to Lookout Marine",
                blurb = "Official charts, rendered live on your Android.",
            )
            StepFact(
                icon = Icons.Outlined.Map,
                title = "Official ENC charts, drawn live",
                blurb = "Lookout renders S-57 and S-101 cells itself. NOAA publishes every United States chart at no cost; most other offices sell theirs.",
            )
            StepFact(
                icon = Icons.Outlined.Public,
                title = "Or start with an online chart",
                blurb = "A published chart style renders straight away, worldwide, with nothing to download and nothing stored.",
            )
            StepFact(
                icon = Icons.Outlined.FolderOpen,
                title = "Bring charts you already have",
                blurb = "A prepared .pmtiles chart, or a folder of S-57 cells, from this device.",
            )
            Text(
                "Lookout is a prototype and is not a certified navigation system. It does not meet chart carriage regulations. Always carry official charts aboard.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
