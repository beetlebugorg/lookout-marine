package org.beetlebug.lookout.settings

// The Text section: what is written on the chart, and how the symbols are drawn.

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

@Composable
internal fun SymbolsSection(m: MarinerState) {
    SectionHeader("Text", first = true)
    SwitchRow("Feature names", m, MI.TEXT_NAMES)
    SwitchRow("Light descriptions", m, MI.SHOW_LIGHT_DESCRIPTIONS)
    SwitchRow("Other text", m, MI.TEXT_OTHER)

    SectionHeader("Symbols")
    SwitchRow("Simplified point symbols", m, MI.SIMPLIFIED_POINTS)
    LabeledRow("Boundaries")
    SegmentedRow(
        options = BoundaryStyle.entries.map { it.label },
        selectedIndex = m.boundaryStyle.ordinal,
        onSelect = { m.boundaryStyle = BoundaryStyle.entries[it] },
    )
    SwitchRow("Full light-sector lines", m, MI.SHOW_FULL_SECTOR_LINES)
}

// ---- Advanced ---------------------------------------------------------------
