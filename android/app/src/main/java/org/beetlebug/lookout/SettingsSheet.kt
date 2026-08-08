package org.beetlebug.lookout

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.outlined.DirectionsBoat
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.SettingsInputAntenna
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.Waves
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.RadioButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
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
 * The mariner's settings: the app's own S-52 display controls and whatever the
 * plugins declare, in the section order every shell shares.
 *
 * SECTIONED, not one long scroll: the sections match how the settings are
 * actually thought about, and burying them in a single form makes them
 * unfindable. A phone shows the list and PUSHES to a section, which is the
 * platform's own settings shape and what a thumb expects from the back gesture;
 * a tablet shows list and section side by side, which is where the Mac's
 * sidebar-and-detail lands anyway. The sheet takes a proportion of the screen
 * rather than a fixed size, so moving between sections doesn't resize it.
 *
 * What is SHARED with the other shells is the product: the section list and its
 * order, the names, which setting lives where, the wording, the described-row
 * pattern, and drawn content like the scheme swatches. What is native is the
 * chrome: Material switches, sliders, radio rows and bottom sheet, the system
 * back gesture, and the OS's colours and type.
 *
 * The section LIST is not hard-coded here. It comes from the plugin registry
 * ([PluginRegistry.sections]), which keeps the app's own sections always and
 * adds a plugin-filled one only while something fills it — so a build whose AIS
 * plugin never came up shows no empty Vessels section. Each section renders the
 * app's own settings for it and then whatever a plugin contributed to the same
 * section, which is how a plugin's controls end up beside the core's instead of
 * in a pen of their own.
 *
 * The selection is a section ID, never an index: sections come and go as
 * plugins load, and an index would silently point at a different section.
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
    val registry = controller.pluginRegistry
    val sections = registry.sections
    // Wide enough for two panes: a tablet gets the list and the detail at once,
    // which lands where the Mac's sidebar-and-detail does without being a copy
    // of it. A phone pushes, because 280 pt of list beside a form is most of a
    // phone's width spent on navigation.
    val twoPane = LocalConfiguration.current.screenWidthDp >= 600

    var open by remember { mutableStateOf<String?>(if (twoPane) "display" else null) }
    // A section can go away — a plugin that stopped takes its section with it —
    // so a stale selection falls back rather than showing a blank pane.
    val current = open?.takeIf { id -> sections.any { it.id == id } }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        // INSIDE the sheet's content, not beside it: ModalBottomSheet registers
        // its own back callback to dismiss itself, and the dispatcher gives the
        // most deeply composed enabled callback priority. Registered outside,
        // back closed the whole sheet from a pushed section instead of
        // returning to the list.
        BackHandler(enabled = current != null && !twoPane) { open = null }
        Box(Modifier.fillMaxHeight(0.92f)) {
            if (twoPane) {
                Row(Modifier.fillMaxWidth()) {
                    SectionList(
                        sections = sections,
                        selected = current,
                        onOpen = { open = it },
                        modifier = Modifier.width(260.dp),
                    )
                    VerticalDivider()
                    Box(Modifier.weight(1f)) {
                        current?.let {
                            SectionPane(it, m, charts, controller, registry, onRequestAccess, null)
                        }
                    }
                }
            } else if (current == null) {
                SectionList(sections = sections, selected = null, onOpen = { open = it })
            } else {
                SectionPane(current, m, charts, controller, registry, onRequestAccess) { open = null }
            }
        }
    }
}

/**
 * The sections, as the list Android settings push from. Each row is the section
 * name and a chevron; the order and the names are the product's, shared with
 * every other shell.
 */
@Composable
private fun SectionList(
    sections: List<SettingsSection>,
    selected: String?,
    onOpen: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxHeight()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 32.dp),
    ) {
        for (s in sections) {
            val chosen = s.id == selected
            Row(
                Modifier
                    .fillMaxWidth()
                    // clickable, not a Button: the whole row is the target, and
                    // it carries Material's ripple for free.
                    .clickable { onOpen(s.id) }
                    .background(
                        if (chosen) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent
                    )
                    .padding(horizontal = 20.dp, vertical = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    sectionIcon(s.id),
                    contentDescription = null, // the label beside it says it
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(24.dp), // Material leading-icon spec
                )
                Spacer(Modifier.width(20.dp))
                Text(
                    s.label,
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * The leading icon for a section. Same MEANING as the other shells, drawn from
 * Material's own set rather than copied art — the Mac names SF Symbols, which
 * do not exist here and would look foreign if they did. Outlined throughout, to
 * sit at the same weight as the rest of a Material list.
 *
 * Every section had a direct Material equivalent; the only one worth naming is
 * `connections`, where SettingsInputAntenna is the antenna the Mac's
 * antenna.radiowaves glyph means, rather than a Wi-Fi symbol — the boat's
 * gateway is often not Wi-Fi.
 */
private fun sectionIcon(id: String): ImageVector = when (id) {
    "display" -> Icons.Outlined.Palette
    "depths" -> Icons.Outlined.Waves
    "text" -> Icons.Outlined.TextFields
    "charts" -> Icons.Outlined.Map
    "vessels" -> Icons.Outlined.DirectionsBoat
    "alarms" -> Icons.Outlined.Notifications
    "connections" -> Icons.Outlined.SettingsInputAntenna
    "plugins" -> Icons.Outlined.Extension
    else -> Icons.Outlined.Tune // advanced, and anything a future core adds
}

/**
 * One section: the app's own settings for it, then whatever a plugin
 * contributed to the same section — so a plugin's controls sit beside the
 * core's instead of in a pen of their own.
 *
 * `onBack` is null in the two-pane layout, where there is nothing to go back to.
 */
@Composable
private fun SectionPane(
    id: String,
    m: MarinerState,
    charts: ChartsModel,
    controller: ChartController,
    registry: PluginRegistry,
    onRequestAccess: () -> Unit,
    onBack: (() -> Unit)?,
) {
    Column(Modifier.fillMaxHeight()) {
        val label = SettingsSection.all.firstOrNull { it.id == id }?.label ?: id
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 4.dp, end = 20.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (onBack != null) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            } else {
                Spacer(Modifier.width(16.dp))
            }
            Text(label, style = MaterialTheme.typography.titleMedium)
        }
        HorizontalDivider()
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 32.dp),
        ) {
            when (id) {
                "display" -> DisplaySection(m)
                "depths" -> DepthsSection(m)
                "text" -> SymbolsSection(m)
                "charts" -> ChartsSection(charts, controller, onRequestAccess)
                "plugins" -> PluginsManageSection(registry)
                "advanced" -> AdvancedSection(m)
            }
            PluginGroups(registry, id, controller)
            PluginLists(registry, id)
        }
    }
}

// ---- Display ----------------------------------------------------------------

@Composable
private fun DisplaySection(m: MarinerState) {
    SectionHeader("Colour scheme")
    SchemeSwatches(m)
    Footer("The palettes switch instantly. Night keeps your eyes dark-adapted.")

    SectionHeader("Display category")
    for (c in DisplayCategory.entries) {
        ChoiceRow(c.label, c.desc, m.displayCategory == c) { m.displayCategory = c }
    }
    Footer("Each category contains the one before it.")

    SectionHeader("Soundings")
    for (s in SoundingsMode.entries) {
        ChoiceRow(s.label, s.desc, m.soundings == s) { m.soundings = s }
    }
}

/**
 * The three schemes as pieces of chart rather than colour chips: four depth
 * shades out to deep water with land behind a curved coastline, which is what
 * the mariner will actually be looking at.
 *
 * The colours are the presentation library's own sRGB values (S-101 profile,
 * tokens DEPDW/DEPMD/DEPMS/DEPVS/LANDA/CSTLN), copied so a swatch can be drawn
 * without opening a chart, and shared verbatim with the other shells. They are
 * a legend of the palette, not the palette: the engine draws from the chart's
 * own tables.
 */
@Composable
private fun SchemeSwatches(m: MarinerState) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        for (s in Scheme.entries) {
            val chosen = s == m.scheme
            Column(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { m.scheme = s },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val p = schemePalette(s)
                Canvas(
                    Modifier
                        .fillMaxWidth()
                        .height(78.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .border(
                            width = if (chosen) 3.dp else 1.dp,
                            color = if (chosen) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.outlineVariant,
                            shape = RoundedCornerShape(8.dp),
                        ),
                ) {
                    val w = size.width
                    val h = size.height
                    // Deepest at the top, shoaling down to the shore.
                    drawRect(p[0], size = androidx.compose.ui.geometry.Size(w, h * 0.36f))
                    drawRect(
                        p[1],
                        topLeft = Offset(0f, h * 0.36f),
                        size = androidx.compose.ui.geometry.Size(w, h * 0.18f),
                    )
                    drawRect(
                        p[2],
                        topLeft = Offset(0f, h * 0.54f),
                        size = androidx.compose.ui.geometry.Size(w, h * 0.16f),
                    )
                    drawRect(
                        p[3],
                        topLeft = Offset(0f, h * 0.70f),
                        size = androidx.compose.ui.geometry.Size(w, h * 0.30f),
                    )
                    // The shore: a bay open to the top-left, land in the corner.
                    val shore = Path().apply {
                        moveTo(0f, h)
                        lineTo(0f, h * 0.80f)
                        cubicTo(w * 0.35f, h * 0.74f, w * 0.60f, h * 0.44f, w, h * 0.52f)
                        lineTo(w, h)
                        close()
                    }
                    drawPath(shore, p[4])
                    drawPath(shore, p[5], style = Stroke(width = 1.5.dp.toPx()))
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    s.label,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = if (chosen) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (chosen) MaterialTheme.colorScheme.onSurface
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(4.dp))
            }
        }
    }
}

/** deep, medium, shallow, very shallow, land, coastline. */
private fun schemePalette(s: Scheme): List<Color> = when (s) {
    Scheme.DAY -> listOf(
        Color(0xFFC9EDFF), Color(0xFFA7D9FB), Color(0xFF82CAFF),
        Color(0xFF61B7FF), Color(0xFFBFBE8F), Color(0xFF4C5B63),
    )
    Scheme.DUSK -> listOf(
        Color(0xFF000000), Color(0xFF0F1B21), Color(0xFF1D3246),
        Color(0xFF1E4165), Color(0xFF40402E), Color(0xFF6B7F89),
    )
    Scheme.NIGHT -> listOf(
        Color(0xFF000000), Color(0xFF03070A), Color(0xFF050E16),
        Color(0xFF071727), Color(0xFF17160E), Color(0xFF252D31),
    )
}

/**
 * One choice in a set, with the line that says what picking it does — the
 * described-row pattern every shell uses for a mutually exclusive choice.
 *
 * A radio button rather than segmented buttons: three options each needing a
 * sentence do not fit a segmented control, and the sentence is the point.
 */
@Composable
private fun ChoiceRow(title: String, desc: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            // The whole row selects, so the touch target is the row and not the
            // 20 dp dot.
            .selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
            .padding(start = 16.dp, end = 20.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(
                desc,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
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

// ---- plugin-declared settings -----------------------------------------------
//
// Rendered entirely from the manifest schema: the shell knows a number, a
// toggle and a text field, and nothing about what any of them mean. A plugin
// that adds a setting gets it on screen with no shell change, in the section
// its manifest names.

/**
 * Every plugin group that belongs on this section, under its own heading.
 *
 * A change goes straight to the core and the registry is re-read, because the
 * core clamps a number to the range the schema published — so the value that
 * comes back is the value in force, which is not always the one asked for.
 */
@Composable
private fun PluginGroups(registry: PluginRegistry, tab: String, controller: ChartController) {
    for (group in registry.groups(tab)) {
        SectionHeader(group.title)
        for (field in group.fields) {
            when (field.kind) {
                PluginField.Kind.TOGGLE -> PluginToggleRow(field) { on ->
                    controller.setPluginConfig(group.pluginId, jsonOf(field.key, on))
                }
                PluginField.Kind.NUMBER -> PluginNumberRow(field) { v ->
                    controller.setPluginConfig(group.pluginId, jsonOf(field.key, v))
                }
                // A text field only ever lives in a list row, where the row
                // editor draws it. One declared loose is a manifest mistake,
                // and showing the key is how its author finds that out.
                PluginField.Kind.TEXT -> Footer("${field.label}: text fields belong in a list")
            }
        }
    }
}

/**
 * The repeating groups on this section — the NMEA gateways, the Signal K
 * servers — as they stand.
 *
 * READ-ONLY for now: this shows what is configured and what each row is doing,
 * so the section is never an empty pane, but adding, removing and editing a row
 * is the connection editor still to come. Until then the launch intent is the
 * only way to name a gateway.
 */
@Composable
private fun PluginLists(registry: PluginRegistry, tab: String) {
    for (schema in registry.lists(tab)) {
        SectionHeader(schema.group.ifEmpty { "Connections" })
        val rows = registry.plugins
            .firstOrNull { it.id == schema.pluginId }
            ?.rows?.get(schema.key)
            .orEmpty()
        if (rows.isEmpty()) {
            Footer(schema.empty.ifEmpty { "Nothing yet." })
        } else {
            for (row in rows) {
                val host = row.cells["host"].orEmpty()
                val port = row.cells["port"].orEmpty()
                val name = row.cells["name"].orEmpty()
                val on = row.cells[schema.switchKey].orEmpty()
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        // The name is optional; the address stands in for it,
                        // which is what the schema's own footer promises.
                        Text(
                            name.ifEmpty { "$host:$port" },
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        if (name.isNotEmpty()) {
                            Text(
                                "$host:$port",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    Text(
                        if (on == "true" || on == "1") "on" else "off",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        if (schema.footer.isNotEmpty()) Footer(schema.footer)
    }
}

/** One key set on one plugin, as the object lookout_plugin_config_set takes. */
private fun jsonOf(key: String, value: Any): String =
    org.json.JSONObject().put(key, value).toString()

/** The described-row pattern: the switch's title, and under it what it does. */
@Composable
private fun PluginToggleRow(field: PluginField, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .toggleable(value = field.on, role = Role.Switch, onValueChange = onChange)
            .padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(field.label, style = MaterialTheme.typography.bodyMedium)
            if (field.desc.isNotEmpty()) {
                Text(
                    field.desc,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        // null: the row owns the click, so the switch must not take it too.
        Switch(checked = field.on, onCheckedChange = null)
    }
}

/**
 * A number the plugin published a range for, as a slider with its value and
 * unit above it.
 *
 * The slider tracks the finger locally and commits ONCE on release: a drag
 * across a 93–9260 m range would otherwise call into the plugin host on every
 * frame of the gesture. The local value is keyed on what the core last said, so
 * a clamp or a change from elsewhere replaces it instead of being overwritten
 * by a stale drag position.
 */
@Composable
private fun PluginNumberRow(field: PluginField, onCommit: (Double) -> Unit) {
    var live by remember(field.value, field.key) { mutableFloatStateOf(field.value.toFloat()) }
    // Whole numbers where the range is coarse enough that a decimal is noise.
    val whole = (field.max - field.min) >= 20.0
    val shown = if (whole) {
        live.roundToInt().toString()
    } else {
        String.format(Locale.US, "%.1f", live)
    }
    Column(Modifier.padding(horizontal = 20.dp, vertical = 2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(field.label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            Text(
                shown,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
            )
            if (field.unit.isNotEmpty()) {
                Text(
                    " ${field.unit}",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Slider(
            value = live.coerceIn(field.min.toFloat(), field.max.toFloat()),
            onValueChange = { live = it },
            onValueChangeFinished = {
                onCommit(if (whole) live.roundToInt().toDouble() else live.toDouble())
            },
            valueRange = field.min.toFloat()..field.max.toFloat(),
        )
    }
    if (field.desc.isNotEmpty()) Footer(field.desc)
}

/**
 * The section that talks ABOUT plugins. It lists what the mariner installed and
 * anything a developer override is supplying — never the bundled set, whose ids
 * belong to the application and which cannot be removed.
 *
 * Stage A shows the standing state; the collapsible rows with their capability
 * grants are Stage B.
 */
@Composable
private fun PluginsManageSection(registry: PluginRegistry) {
    SectionHeader("Installed plugins")
    val managed = registry.managed
    if (managed.isEmpty()) {
        Footer(
            "No plugins installed. Own ship, AIS targets, laylines and the " +
                "NMEA 0183 and Signal K sources come with Lookout and are always on."
        )
        return
    }
    for (p in managed) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(p.name, style = MaterialTheme.typography.bodyMedium)
                Text(
                    if (p.status.isNotEmpty()) p.status else p.id,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (p.origin == "developer") {
                Text(
                    "developer",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
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
