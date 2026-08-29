package org.beetlebug.lookout.settings

// The Advanced section: safety and quality, sizing, dates, and About.
//
// About sits at its foot, where the other shells put it: the version and the
// engine's pin are what a bug report needs, and the licences are a legal
// obligation that has to be reachable from somewhere a mariner can find.

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import org.beetlebug.lookout.licenses.LicenseManifest
import org.beetlebug.lookout.licenses.appVersion

@Composable
internal fun AdvancedSection(m: MarinerState, onOpenLicenses: () -> Unit) {
    SectionHeader("Safety & quality", first = true)
    SwitchRow("Data quality overlay", m, MI.DATA_QUALITY)
    SwitchRow("Isolated dangers in shallow water", m, MI.SHOW_ISOLATED_DANGERS_SHALLOW)
    SwitchRow("Information callouts", m, MI.SHOW_INFORM_CALLOUTS)
    SwitchRow("Meta boundaries", m, MI.SHOW_META_BOUNDS)
    SwitchRow("Overscale indication", m, MI.SHOW_OVERSCALE)

    SectionHeader("Sizing")
    SizeRow("Symbols & lines", m, MI.SIZE_SCALE)
    SizeRow("Text", m, MI.TEXT_SIZE_SCALE)
    SizeRow("Soundings", m, MI.SOUNDING_SIZE_SCALE)

    SectionHeader("Dates")
    SwitchRow("Date-dependent features", m, MI.DATE_DEPENDENT)
    SwitchRow("Highlight date-dependent", m, MI.HIGHLIGHT_DATE_DEPENDENT)
    Footer("Date-dependent features appear only when in season.")

    AboutSection(onOpenLicenses)
}

/**
 * What this build is, and the way to its terms. It sits at the foot of
 * Advanced, where the other shells put it: the version and the engine's pin
 * are what a bug report needs, and the licenses are a legal obligation that
 * has to be reachable from somewhere a mariner can find.
 */
@Composable
private fun AboutSection(onOpenLicenses: () -> Unit) {
    val manifest = LicenseManifest.current
    val engine = manifest?.components?.firstOrNull { it.id == "tile57" }
    val count = manifest?.components?.size ?: 0

    SectionHeader("About")
    ValueRow("Version", appVersion())
    if (engine != null && engine.pinLabel.isNotEmpty()) {
        ValueRow("Chart engine", "${engine.name} · ${engine.pinLabel}", mono = true)
    }
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpenLicenses)
            .padding(horizontal = 20.dp, vertical = 12.dp)
            .testTag("about-licenses"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Licenses", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        if (count > 0) {
            Text(
                "$count components",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null, // the row's own label says where it goes
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
