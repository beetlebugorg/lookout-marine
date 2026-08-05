package org.beetlebug.lookout

import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val FEET_PER_METRE = 3.28084

/**
 * The mariner's S-52 display settings, mirroring SettingsView.swift.
 *
 * TABBED, not one long scroll: the groups match how the settings are actually
 * thought about, and burying them in a single form makes them unfindable. The
 * sheet takes a proportion of the screen rather than a fixed size, so switching
 * tabs doesn't resize it and no content gets clipped on a small phone.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(
    m: MarinerState,
    charts: ChartsModel,
    controller: ChartController,
    onRequestAccess: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var tab by remember { mutableIntStateOf(0) }
    val tabs = listOf("Display", "Depths", "Text", "Advanced", "Charts")

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(Modifier.fillMaxHeight(0.92f)) {
            // Scrollable, not fixed: five labels don't fit a phone's width, and
            // "Advanced" ellipsising to "Advan…" is worse than a row that scrolls.
            ScrollableTabRow(selectedTabIndex = tab, edgePadding = 0.dp) {
                tabs.forEachIndexed { i, title ->
                    Tab(
                        selected = tab == i,
                        onClick = { tab = i },
                        text = { Text(title, style = MaterialTheme.typography.labelLarge) },
                    )
                }
            }
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(bottom = 32.dp),
            ) {
                when (tab) {
                    0 -> DisplaySection(m)
                    1 -> DepthsSection(m)
                    2 -> SymbolsSection(m)
                    3 -> AdvancedSection(m)
                    else -> ChartsSection(charts, controller, onRequestAccess)
                }
            }
        }
    }
}

// ---- Display ----------------------------------------------------------------

@Composable
private fun DisplaySection(m: MarinerState) {
    SectionHeader("Colour scheme")
    SegmentedRow(
        options = Scheme.entries.map { it.label },
        selectedIndex = m.scheme.ordinal,
        onSelect = { m.scheme = Scheme.entries[it] },
    )
    Footer("Day, dusk and night palettes switch instantly.")

    SectionHeader("Detail")
    LabeledRow("Display category")
    SegmentedRow(
        options = DisplayCategory.entries.map { it.label },
        selectedIndex = m.displayCategory.ordinal,
        onSelect = { m.displayCategory = DisplayCategory.entries[it] },
    )
    LabeledRow("Soundings")
    SegmentedRow(
        options = listOf("Category", "Always on", "Always off"),
        selectedIndex = m.soundings.ordinal,
        onSelect = { m.soundings = SoundingsMode.entries[it] },
    )
    Footer(
        "Base ⊂ Standard ⊂ Other. Spot soundings switch independently of the " +
            "category, so Standard + soundings is the everyday setting."
    )
}

// ---- Depths -----------------------------------------------------------------

@Composable
private fun DepthsSection(m: MarinerState) {
    val feet = m.depthUnit == DepthUnit.FEET
    val unit = if (feet) "ft" else "m"

    SectionHeader("Depth unit")
    SegmentedRow(
        options = DepthUnit.entries.map { it.label },
        selectedIndex = m.depthUnit.ordinal,
        onSelect = { m.depthUnit = DepthUnit.entries[it] },
    )

    LabeledRow("Water shading")
    SegmentedRow(
        options = listOf("Two shades", "Four shades"),
        selectedIndex = if (m.flag(MI.FOUR_SHADE_WATER)) 1 else 0,
        onSelect = { m.setFlag(MI.FOUR_SHADE_WATER, it == 1) },
    )
    Footer(
        if (m.flag(MI.FOUR_SHADE_WATER))
            "Four shades: white (safe) water starts at the DEEP contour; the " +
                "safety contour separates the two middle blues."
        else
            "Two shades: water deeper than the safety contour is white (safe), " +
                "everything shallower is blue."
    )

    BandPreview(m, feet)
    Footer(
        "Shading follows the depth areas in the chart: the effective safety " +
            "contour is the next DEEPER contour available in the data, drawn bold."
    )

    SectionHeader("Contours ($unit)")
    if (m.flag(MI.FOUR_SHADE_WATER)) {
        DepthRow("Shallow contour", m.shallowContour, unit, feet) { m.shallowContour = it }
    }
    DepthRow("Safety contour", m.safetyContour, unit, feet) { m.safetyContour = it }
    if (m.flag(MI.FOUR_SHADE_WATER)) {
        DepthRow("Deep contour", m.deepContour, unit, feet) { m.deepContour = it }
    }
    DepthRow("Safety depth", m.safetyDepth, unit, feet) { m.safetyDepth = it }
    Footer("Safety depth bolds soundings at or shallower than it; it does not shade water.")
}

/**
 * Schematic of the S-52 depth bands for the CURRENT settings: which shades
 * exist, and which contour separates each pair. Colours approximate the day
 * palette — this is a legend, not the palette itself.
 */
@Composable
private fun BandPreview(m: MarinerState, feet: Boolean) {
    // Whole depths read as whole numbers ("10 m", not "10.0 m"); the odd
    // half-metre contour still gets its decimal.
    fun label(metres: Double): String = when {
        feet -> "${(metres * FEET_PER_METRE).roundToInt()} ft"
        metres == metres.roundToInt().toDouble() -> "${metres.roundToInt()} m"
        else -> String.format(Locale.US, "%.1f m", metres)
    }

    val drying = Color(0xFF8CCC99)
    val bands: List<Pair<Color, String>> = if (m.flag(MI.FOUR_SHADE_WATER)) listOf(
        drying to "drying",
        Color(0xFF73BFED) to "0–${label(min(m.shallowContour, m.safetyContour))}",
        Color(0xFF8CD1F7) to "–${label(m.safetyContour)}",
        Color(0xFFBFE6FC) to "–${label(max(m.deepContour, m.safetyContour))}",
        Color.White to "deeper",
    ) else listOf(
        drying to "drying",
        Color(0xFF73BFED) to "0–${label(m.safetyContour)}",
        Color.White to "deeper",
    )

    Row(
        Modifier
            .padding(horizontal = 20.dp, vertical = 6.dp)
            .fillMaxWidth()
            .height(36.dp)
            .clip(RoundedCornerShape(6.dp))
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(6.dp)),
    ) {
        for ((color, text) in bands) {
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .background(color),
                contentAlignment = Alignment.BottomCenter,
            ) {
                Text(
                    text = text,
                    fontSize = 9.sp,
                    maxLines = 1,
                    color = Color.Black.copy(alpha = 0.75f),
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(bottom = 2.dp),
                )
            }
        }
    }
}

/**
 * A contour depth. The ENGINE always takes metres (S-57 depths are metres; the
 * unit only changes labels), so feet mode edits through a conversion here, in
 * WHOLE feet — a depth read to fractions of a foot is noise, and sending "ft"
 * numbers straight through as metres was a real bug once.
 */
@Composable
private fun DepthRow(
    title: String,
    metres: Double,
    unit: String,
    feet: Boolean,
    onChange: (Double) -> Unit,
) {
    val shown = if (feet) (metres * FEET_PER_METRE).roundToInt().toDouble() else metres
    fun commit(v: Double) {
        val clamped = v.coerceIn(0.0, 660.0)
        onChange(if (feet) clamped.roundToInt() / FEET_PER_METRE else clamped)
    }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.weight(1f))
        Text(
            text = if (feet) "${shown.roundToInt()}" else String.format(Locale.US, "%.1f", shown),
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium,
        )
        Text(
            " $unit",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        IconButton(onClick = { commit(shown - 1) }, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.Remove, contentDescription = "Decrease $title")
        }
        IconButton(onClick = { commit(shown + 1) }, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.Add, contentDescription = "Increase $title")
        }
    }
}

// ---- Text & Symbols ---------------------------------------------------------

@Composable
private fun SymbolsSection(m: MarinerState) {
    SectionHeader("Text")
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

@Composable
private fun AdvancedSection(m: MarinerState) {
    SectionHeader("Safety & quality")
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
}

// ---- rows -------------------------------------------------------------------

@Composable
internal fun SectionHeader(text: String) {
    HorizontalDivider(Modifier.padding(top = 12.dp))
    Text(
        text = text.uppercase(Locale.US),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.primary,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 4.dp),
    )
}

@Composable
internal fun Footer(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
    )
}

@Composable
private fun LabeledRow(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.padding(start = 20.dp, top = 8.dp, bottom = 2.dp),
    )
}

@Composable
private fun SwitchRow(title: String, m: MarinerState, index: Int) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Switch(checked = m.flag(index), onCheckedChange = { m.setFlag(index, it) })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SegmentedRow(options: List<String>, selectedIndex: Int, onSelect: (Int) -> Unit) {
    SingleChoiceSegmentedButtonRow(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 4.dp),
    ) {
        options.forEachIndexed { i, label ->
            SegmentedButton(
                selected = i == selectedIndex,
                onClick = { onSelect(i) },
                shape = SegmentedButtonDefaults.itemShape(index = i, count = options.size),
            ) {
                Text(label, maxLines = 1, style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Composable
private fun SizeRow(title: String, m: MarinerState, index: Int) {
    Column(Modifier.padding(horizontal = 20.dp, vertical = 2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            Text(
                String.format(Locale.US, "%.2f×", m.num(index)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Slider(
            value = m.num(index).toFloat(),
            onValueChange = { m.setNum(index, it.toDouble()) },
            valueRange = 0.5f..2.0f,
        )
    }
}
