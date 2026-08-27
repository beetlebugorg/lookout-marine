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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.DirectionsBoat
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.SettingsInputAntenna
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.Waves
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
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
    initialSection: String? = null,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val registry = controller.pluginRegistry
    val sections = registry.sections
    // Wide enough for two panes: a tablet gets the list and the detail at once,
    // which lands where the Mac's sidebar-and-detail does without being a copy
    // of it. A phone pushes, because 280 pt of list beside a form is most of a
    // phone's width spent on navigation.
    val twoPane = LocalConfiguration.current.screenWidthDp >= 600

    var open by remember {
        mutableStateOf(initialSection ?: if (twoPane) "display" else null)
    }
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
        // What the plugins report has to move on its own while this is open: a
        // connection that says "Reconnecting" and never says "Connected" is how
        // the mariner learns the address is wrong. Stopped on close, because
        // nothing off screen needs a 1 Hz sample.
        DisposableEffect(controller) {
            controller.startPluginPolling()
            onDispose { controller.stopPluginPolling() }
        }
        // The connection editor puts a keyboard on screen; without this it
        // covers the field being typed into.
        Box(
            Modifier
                .fillMaxHeight(0.92f)
                .imePadding(),
        ) {
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
                            SectionPane(it, m, charts, controller, registry, onRequestAccess, null, onDismiss)
                        }
                    }
                }
            } else if (current == null) {
                SectionList(sections = sections, selected = null, onOpen = { open = it })
            } else {
                SectionPane(current, m, charts, controller, registry, onRequestAccess, { open = null }, onDismiss)
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
/**
 * The sections the app draws its OWN settings into, before any plugin adds to
 * them. The rest are a plugin's alone, and stand empty until one loads.
 */
private val CORE_CONTENT = setOf("display", "depths", "text", "charts", "plugins", "advanced")

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
    onCloseSheet: () -> Unit,
) {
    // The licenses push over the PANE, not over the sheet, so a tablet keeps
    // its section list beside them. Two steps deep: the list, then one entry.
    // Keyed on the section, so leaving Advanced puts the pane back where the
    // mariner would expect to find it.
    var licenses by remember(id) { mutableStateOf(false) }
    var entry by remember(id) { mutableStateOf<LicenseSelection?>(null) }
    val manifest = LicenseManifest.current

    // The system back gesture unwinds the same one step at a time. Registered
    // here rather than beside the sheet's, for the sheet's own reason: the
    // dispatcher gives the most deeply composed enabled callback priority.
    BackHandler(enabled = licenses) {
        if (entry != null) entry = null else licenses = false
    }

    Column(Modifier.fillMaxHeight()) {
        val label = when {
            entry != null -> licenseTitle(manifest, entry)
            licenses -> "Licenses"
            else -> SettingsSection.all.firstOrNull { it.id == id }?.label ?: id
        }
        val back: (() -> Unit)? = when {
            entry != null -> ({ entry = null })
            licenses -> ({ licenses = false })
            else -> onBack
        }
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 4.dp, end = 20.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (back != null) {
                IconButton(onClick = back) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            } else {
                Spacer(Modifier.width(16.dp))
            }
            Text(label, style = MaterialTheme.typography.titleMedium)
        }
        HorizontalDivider()
        if (licenses) {
            LicensesScreen(manifest, entry) { entry = it }
            return@Column
        }
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 32.dp),
        ) {
            // Whether the app's own settings filled the top of the pane. When
            // they did not — Vessels, Alarms and Connections are entirely a
            // plugin's — the first plugin heading is the one that must not draw
            // a rule under the title bar.
            val core = id in CORE_CONTENT
            when (id) {
                "display" -> DisplaySection(m)
                "depths" -> DepthsSection(m)
                "text" -> SymbolsSection(m)
                "charts" -> ChartsSection(charts, controller, onRequestAccess)
                "plugins" -> PluginsManageSection(registry, controller)
                "advanced" -> AdvancedSection(m, onOpenLicenses = { licenses = true })
            }
            // The declared tables that belong to this section — the reference
            // shell's Vessels menu, as rows. Opening one closes the sheet: the
            // table sits over the chart, and a row's reveal needs it visible.
            val tables = controller.tableSpecs.filter { it.menu.equals(id, ignoreCase = true) }
            val hasTables = tables.isNotEmpty()
            if (hasTables) {
                SectionHeader("Tables", first = !core)
                for (spec in tables) {
                    TextButton(
                        onClick = {
                            onCloseSheet()
                            controller.showTable(spec)
                        },
                        modifier = Modifier.padding(horizontal = 12.dp),
                    ) { Text("${spec.title}…") }
                }
                Footer("Live while it is open. Tap a row to find it on the chart.")
            }
            val groups = registry.groups(id)
            PluginGroups(groups, controller, first = !core && !hasTables)
            PluginLists(registry, id, controller, first = !core && !hasTables && groups.isEmpty())
        }
    }
}

// ---- Display ----------------------------------------------------------------

@Composable
private fun DisplaySection(m: MarinerState) {
    SectionHeader("Colour scheme", first = true)
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

    SectionHeader("Depth unit", first = true)
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

@Composable
private fun AdvancedSection(m: MarinerState, onOpenLicenses: () -> Unit) {
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

/** A label with its value opposite, for a fact that is read and not changed. */
@Composable
private fun ValueRow(title: String, value: String, mono: Boolean = false) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** The title bar over one license entry: what the entry is called. */
private fun licenseTitle(manifest: LicenseManifest?, sel: LicenseSelection?): String = when (sel) {
    null -> "Licenses"
    is LicenseSelection.App -> manifest?.app?.name ?: "Licenses"
    is LicenseSelection.Component ->
        manifest?.components?.firstOrNull { it.id == sel.id }?.name ?: "Licenses"
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
private fun PluginGroups(groups: List<PluginGroup>, controller: ChartController, first: Boolean) {
    for ((i, group) in groups.withIndex()) {
        SectionHeader(group.title, first = first && i == 0)
        for (field in group.fields) {
            when (field.kind) {
                PluginField.Kind.TOGGLE -> PluginToggleRow(field) { on ->
                    controller.setPluginScalar(group.pluginId, field, if (on) 1.0 else 0.0)
                }
                PluginField.Kind.NUMBER -> PluginNumberRow(field) { v ->
                    controller.setPluginScalar(group.pluginId, field, v)
                }
                // A text field only ever lives in a list row, where the row
                // editor draws it. One declared loose is a manifest mistake,
                // and showing the key is how its author finds that out.
                PluginField.Kind.TEXT -> Footer("${field.label}: text fields belong in a list")
            }
        }
    }
}

// ---- the connection editor ---------------------------------------------------
//
// The repeating groups on a section — the NMEA gateways, the Signal K servers.
// This is where the mariner names their own boat's gateway, so it has to work
// with a thumb, at a slant, in the wet.
//
// Every WORD here comes from the manifest: the heading, the sentence under the
// rows, what an empty list says and what the add button is called ("Add
// Connection" for NMEA, "Add Server" for Signal K). Nothing is an Android
// string resource, because nothing here is Android's to name — a plugin that
// collects something other than gateways says so in its own words and this pane
// reads correctly with no change.
//
// So are the COLUMNS. Four are standard (a name, an address, a port and an
// on/off switch) but a plugin may declare more — Signal K adds a WebSocket flag
// — so the editor renders whatever the schema lists, by kind.
//
// A row EXPANDS IN PLACE rather than opening a second sheet. The settings are
// already a bottom sheet, and stacking another over it puts the mariner two
// dismissals deep in a modal on a moving boat; expanding also keeps the live
// status line visible while the address is being typed, which is the whole
// feedback loop — type it, watch it go green.

/**
 * Every repeating list on this section, as rows that can be added to, edited
 * and removed.
 */
@Composable
private fun PluginLists(
    registry: PluginRegistry,
    tab: String,
    controller: ChartController,
    first: Boolean,
) {
    // Which row is open for editing, across every list on the pane: opening one
    // closes the last, so the pane never has two keyboards' worth of form on it.
    var editing by remember { mutableStateOf<String?>(null) }

    // What is answering on the boat's network, for as long as this pane is on
    // screen. A browse nobody is watching is a radio left on.
    val context = LocalContext.current
    val discovery = remember { Discovery(context) }
    val services = registry.lists(tab).flatMap { it.discover }.map { it.service }
    DisposableEffect(services) {
        discovery.browse(services)
        onDispose { discovery.stop() }
    }

    for ((i, schema) in registry.lists(tab).withIndex()) {
        SectionHeader(schema.group.ifEmpty { "Connections" }, first = first && i == 0)
        val rows = registry.rows(schema)
        if (rows.isEmpty()) {
            Footer(schema.empty.ifEmpty { "Nothing yet." })
        }
        for (row in rows) {
            ConnectionRow(
                schema = schema,
                row = row,
                status = registry.status(schema, row.id),
                expanded = editing == row.id,
                onToggleExpanded = { editing = if (editing == row.id) null else row.id },
                onSetSwitch = { on ->
                    val key = schema.switchField?.key ?: return@ConnectionRow
                    controller.setPluginList(schema, rows.replacing(row.id, key, on.toString()))
                },
            )
            if (editing == row.id) {
                ConnectionEditor(
                    schema = schema,
                    row = row,
                    onCommit = { cells ->
                        controller.setPluginList(schema, rows.map {
                            if (it.id == row.id) it.copy(cells = cells) else it
                        })
                        editing = null
                    },
                    onRemove = {
                        controller.setPluginList(schema, rows.filterNot { it.id == row.id })
                        editing = null
                    },
                )
            }
        }
        for (service in discovery.nearby(schema, rows)) {
            NearbyRow(service) {
                controller.setPluginList(schema, rows + schema.rowFrom(service))
            }
        }
        AddRowButton(schema, rows.size) {
            val fresh = schema.newRow()
            controller.setPluginList(schema, rows + fresh)
            // Straight into the editor: a row added on the schema's defaults has
            // no address yet, so the next thing the mariner needs is the field.
            editing = fresh.id
        }
        if (schema.footer.isNotEmpty()) Footer(schema.footer)
    }
}

/**
 * What this list could be filled in from: the services answering for one of its
 * types, less the ones it already holds.
 *
 * A host the list already points at is not offered again, whatever port the row
 * uses. One machine announces the port it wants to be reached on and is often
 * reachable on another, and a second row to a source already connected sends
 * the same boat twice.
 */
private fun Discovery.nearby(
    schema: PluginListSchema,
    rows: List<PluginRow>,
): List<DiscoveredService> {
    if (schema.discover.isEmpty() || rows.size >= schema.maxRows) return emptyList()
    val types = schema.discover.map { it.service }.toSet()
    val address = schema.addressField ?: return emptyList()
    val held = rows.map { it.text(address.key).lowercase() }.toSet()
    return found
        .filter { it.service in types && it.host.lowercase() !in held }
        .sortedBy { it.name.lowercase() }
}

/**
 * One source answering on the network, offered ready to add. Nothing found
 * shows nothing: at a desk that is the ordinary case, and an empty heading is a
 * question nobody asked.
 */
@Composable
private fun NearbyRow(service: DiscoveredService, onAdd: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onAdd)
            .padding(start = 20.dp, end = 12.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(service.name, style = MaterialTheme.typography.bodyMedium)
            Text(
                "${service.host}:${service.port}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            Icons.Default.Add,
            contentDescription = "Add ${service.name}",
            tint = MaterialTheme.colorScheme.primary,
        )
    }
}

/** One cell replaced in one row, the rest untouched. */
private fun List<PluginRow>.replacing(id: String, key: String, value: String): List<PluginRow> =
    map { if (it.id == id) it.copy(cells = it.cells + (key to value)) else it }

/**
 * One connection at rest: what it is, what it is doing now, and its own switch.
 *
 * The whole line opens the editor, so the target is the row and not a pencil;
 * the switch keeps its own hit area, because pausing a source is a thing done
 * without wanting to edit it.
 */
@Composable
private fun ConnectionRow(
    schema: PluginListSchema,
    row: PluginRow,
    status: PluginStatusItem?,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    onSetSwitch: (Boolean) -> Unit,
) {
    val address = schema.addressField?.let { row.text(it.key) }.orEmpty()
    val port = schema.portField?.let { row.text(it.key) }.orEmpty()
    val name = schema.nameField?.let { row.text(it.key) }.orEmpty()
    val where = when {
        address.isEmpty() -> ""
        port.isEmpty() -> address
        else -> "$address:$port"
    }
    // The name is optional and the address stands in for it, which is what the
    // schema's own footer promises. A row with neither is one just added.
    val title = name.ifEmpty { where.ifEmpty { "New" } }
    val switch = schema.switchField

    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggleExpanded)
            .padding(start = 20.dp, end = 12.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StatusDot(status)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.bodyMedium)
                // Any extra column the plugin declared and the mariner switched
                // on, named by the schema — Signal K's WebSocket is the first.
                for (f in schema.extraFields) {
                    if (f.kind != PluginField.Kind.TOGGLE || !row.on(f.key)) continue
                    Spacer(Modifier.width(6.dp))
                    Text(
                        f.label,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }
            // Under the name, the address it stands for; then the plugin's own
            // line for this row. A row that has not been reported on yet says
            // so rather than showing nothing, so a silent plugin is visible.
            if (name.isNotEmpty() && where.isNotEmpty()) {
                Text(
                    where,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(
                status?.line ?: "Not started",
                style = MaterialTheme.typography.bodySmall,
                color = statusColour(status),
            )
        }
        if (switch != null) {
            Switch(checked = row.on(switch.key), onCheckedChange = onSetSwitch)
        }
        Icon(
            if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
            contentDescription = if (expanded) "Close editor" else "Edit ${title}",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Green while it works, amber while it tries, red when it has given up. */
@Composable
private fun statusColour(status: PluginStatusItem?): Color = when (status?.tone) {
    PluginStatusItem.Tone.GOOD -> CONNECTED_GREEN
    PluginStatusItem.Tone.TRYING -> CONNECTING_AMBER
    PluginStatusItem.Tone.BAD -> MaterialTheme.colorScheme.error
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

/**
 * The state at a glance, before any word is read. Deliberately not Material's
 * primary: these are the connection colours the other shells use, and a mariner
 * who learned green-is-feeding on the Mac reads the same dot here.
 */
private val CONNECTED_GREEN = Color(0xFF2E9E4F)
private val CONNECTING_AMBER = Color(0xFFC77A11)

@Composable
private fun StatusDot(status: PluginStatusItem?) {
    Box(
        Modifier
            .size(10.dp)
            .clip(RoundedCornerShape(5.dp))
            .background(statusColour(status)),
    )
}

/**
 * One connection, open for editing: every column the schema declares, in the
 * order it declared them, rendered from its kind.
 *
 * The draft is local and committed on Done, not on every keystroke. Writing
 * through per character would tear the socket down and build it again for each
 * letter of a hostname, and the mariner would watch their own typing report
 * itself unreachable.
 *
 * It is re-seeded whenever the row is opened, so what the editor shows is what
 * the CORE holds after its own clamping — a port typed past 65535 comes back
 * clamped, and re-opening the row shows the clamped number.
 */
@Composable
private fun ConnectionEditor(
    schema: PluginListSchema,
    row: PluginRow,
    onCommit: (Map<String, String>) -> Unit,
    onRemove: () -> Unit,
) {
    var draft by remember(row.id) { mutableStateOf(row.cells) }
    val focus = LocalFocusManager.current

    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .padding(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 12.dp),
    ) {
        for (f in schema.itemFields) {
            // The on/off switch lives on the row itself, where it can be reached
            // without opening anything.
            if (f.key == schema.switchField?.key) continue
            when (f.kind) {
                PluginField.Kind.TOGGLE -> Row(
                    Modifier
                        .fillMaxWidth()
                        .toggleable(
                            value = draft[f.key] == "true",
                            role = Role.Switch,
                            onValueChange = { draft = draft + (f.key to it.toString()) },
                        )
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(f.label, style = MaterialTheme.typography.bodyMedium)
                        if (f.desc.isNotEmpty()) {
                            Text(
                                f.desc,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    Switch(checked = draft[f.key] == "true", onCheckedChange = null)
                }
                else -> OutlinedTextField(
                    value = draft[f.key].orEmpty(),
                    onValueChange = { draft = draft + (f.key to it) },
                    label = { Text(f.label) },
                    supportingText = describing(f.desc),
                    singleLine = true,
                    keyboardOptions = keyboardFor(f),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp),
                )
            }
        }
        Row(
            Modifier
                .fillMaxWidth()
                .padding(top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(
                onClick = { focus.clearFocus(); onRemove() },
                colors = ButtonDefaults.textButtonColors(
                    contentColor = MaterialTheme.colorScheme.error,
                ),
            ) {
                Icon(Icons.Outlined.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Remove")
            }
            Spacer(Modifier.weight(1f))
            Button(onClick = { focus.clearFocus(); onCommit(draft) }) { Text("Done") }
        }
    }
}

/**
 * A field's sentence, as a text control's supporting line — or nothing at all
 * when the manifest declared none, so an undescribed column takes no space it
 * has no use for.
 */
private fun describing(desc: String): (@Composable () -> Unit)? {
    if (desc.isEmpty()) return null
    return { Text(desc, style = MaterialTheme.typography.bodySmall) }
}

/**
 * The keyboard a column wants.
 *
 * A number column is a number, which is the easy half. For TEXT the schema
 * carries no keyboard hint, so the one hint it does carry is used: the column's
 * key. An address field gets the URI keyboard — a dot and a slash on the front
 * row, no autocorrect and no capital first letter, all three of which a
 * hostname needs and a name field does not. Anything unrecognised falls back to
 * the ordinary text keyboard, so a plugin naming its columns something else
 * still gets a usable editor.
 */
private fun keyboardFor(f: PluginField): KeyboardOptions = when {
    f.kind == PluginField.Kind.NUMBER -> KeyboardOptions(keyboardType = KeyboardType.Number)
    f.key in ADDRESS_KEYS -> KeyboardOptions(
        keyboardType = KeyboardType.Uri,
        autoCorrectEnabled = false,
        capitalization = KeyboardCapitalization.None,
    )
    else -> KeyboardOptions(capitalization = KeyboardCapitalization.Words)
}

private val ADDRESS_KEYS = setOf("host", "address", "url", "server", "hostname")

/**
 * Add a row, in the plugin's own words. It goes quiet at the host's row cap
 * rather than letting the mariner type a gateway the core will drop on the way
 * in — a connection that silently never connects is worse than a button that
 * says why it cannot.
 */
@Composable
private fun AddRowButton(schema: PluginListSchema, count: Int, onAdd: () -> Unit) {
    val full = count >= schema.maxRows
    TextButton(
        onClick = onAdd,
        enabled = !full,
        modifier = Modifier.padding(start = 12.dp, top = 4.dp),
    ) {
        Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(schema.addLabel.ifEmpty { "Add" })
    }
    if (full) Footer("${schema.maxRows} is all this plugin holds.")
}

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
/**
 * The status line as a sentence, never as the JSON a managed plugin writes it
 * in: word + " · " + detail (the reference's word map). Null when the plugin
 * says nothing.
 */
private fun statusCaption(p: PluginInfo): String? {
    val raw = p.status.trim()
    if (raw.isEmpty()) return null
    if (!raw.startsWith("{")) return raw
    return try {
        val o = org.json.JSONObject(raw)
        val word = when (o.optString("state")) {
            "running", "" -> "Running"
            "starting" -> "Starting"
            "degraded" -> "Degraded"
            "disabled" -> "Disabled"
            "stopped" -> "Stopped"
            else -> o.optString("state")
        }
        val detail = o.optString("detail")
        if (detail.isEmpty()) word else "$word · $detail"
    } catch (e: Exception) {
        raw
    }
}

@Composable
private fun PluginsManageSection(registry: PluginRegistry, controller: ChartController) {
    SectionHeader("Installed plugins", first = true)
    val managed = registry.managed
    if (managed.isEmpty()) {
        Footer(
            "No plugins installed. Own ship, AIS targets, laylines and the " +
                "NMEA 0183 and Signal K sources come with Lookout and are always on."
        )
    }
    var uninstalling by remember { mutableStateOf<PluginInfo?>(null) }
    for (p in managed) {
        var open by remember(p.id) { mutableStateOf(false) }
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { open = !open }
                .padding(horizontal = 20.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(p.name, style = MaterialTheme.typography.bodyMedium)
                Text(
                    (statusCaption(p) ?: p.id) +
                        if (p.origin == "developer") " · developer copy" else "",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(
                if (open) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (open) {
            // The grants, in the core's own consent wording, flipped LIVE:
            // the plugin keeps running and a revoked call answers -1.
            for (cap in p.capabilities) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(start = 35.dp, end = 20.dp, top = 2.dp, bottom = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        cap.sentence.ifEmpty { cap.cap },
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = cap.granted,
                        onCheckedChange = { controller.setPluginGrant(p.id, cap.cap, it) },
                    )
                }
            }
            if (p.capabilities.isEmpty()) {
                Footer("This plugin only draws its own settings pages.")
            }
            if (p.origin == "installed") {
                TextButton(
                    onClick = { uninstalling = p },
                    modifier = Modifier.padding(start = 23.dp),
                ) { Text("Uninstall", color = MaterialTheme.colorScheme.error) }
            }
        }
    }

    // The way a plugin file arrives on a tablet with no Finder: browse for it.
    var picking by remember { mutableStateOf(false) }
    TextButton(
        onClick = { picking = true },
        modifier = Modifier.padding(horizontal = 12.dp),
    ) { Text("Install plugin…") }
    Footer("Nothing is installed before its permissions are shown.")

    if (picking) {
        LkplugPickerDialog(
            onPick = { path ->
                picking = false
                controller.beginPluginInstall(path)
            },
            onDismiss = { picking = false },
        )
    }
    uninstalling?.let { p ->
        AlertDialog(
            onDismissRequest = { uninstalling = null },
            title = { Text("Uninstall ${p.name}?") },
            text = { Text("Removes the plugin and everything it drew.") },
            confirmButton = {
                TextButton(onClick = {
                    controller.uninstallPlugin(p.id)
                    uninstalling = null
                }) { Text("Uninstall", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { uninstalling = null }) { Text("Cancel") } },
        )
    }
}

/**
 * The consent and install-error dialogs. Composed at SCREEN level, not inside
 * the Plugins pane: a .lkplug can arrive from another app with no settings
 * sheet anywhere, and consent has to come up over the chart just the same.
 */
@Composable
fun PluginInstallDialogs(controller: ChartController) {
    controller.pluginConsent?.let { pkg ->
        PluginConsentDialog(
            pkg = pkg,
            onInstall = { controller.confirmPluginInstall() },
            onCancel = { controller.cancelPluginInstall() },
        )
    }
    controller.installError?.let { msg ->
        AlertDialog(
            onDismissRequest = { controller.dismissInstallError() },
            title = { Text("Couldn't install plugin") },
            text = { Text(msg) },
            confirmButton = {
                TextButton(onClick = { controller.dismissInstallError() }) { Text("OK") }
            },
        )
    }
}

/**
 * The consent sheet: what the package can do, called out against the running
 * copy on a reinstall. Cancel is the default; nothing touches disk before
 * Install.
 */
@Composable
private fun PluginConsentDialog(
    pkg: ChartController.PluginPackage,
    onInstall: () -> Unit,
    onCancel: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("Install ${pkg.name}?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    if (pkg.version.isEmpty()) pkg.id else "${pkg.id} · Version ${pkg.version}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                pkg.installedVersion?.let { v ->
                    Text(
                        "Replaces the installed version $v." +
                            (if (pkg.downgrade) " This is a downgrade." else "") +
                            if (pkg.installedOrigin == "developer")
                                " The developer copy keeps running until its override is dropped."
                            else "",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (pkg.downgrade) Chrome.amber
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    if (pkg.installedVersion == null) "This plugin can:" else "After this install it can:",
                    style = MaterialTheme.typography.labelMedium,
                )
                if (pkg.sentences.isEmpty()) {
                    Text(
                        "This plugin only draws its own settings pages.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                for (s in pkg.sentences) Text("· $s", style = MaterialTheme.typography.bodySmall)
                if (pkg.adds.isNotEmpty()) {
                    Text("New since the installed version:", style = MaterialTheme.typography.labelMedium)
                    for (s in pkg.adds) Text("+ $s", style = MaterialTheme.typography.bodySmall, color = Chrome.amber)
                }
                if (pkg.drops.isNotEmpty()) {
                    Text("No longer asks to:", style = MaterialTheme.typography.labelMedium)
                    for (s in pkg.drops) Text("− $s", style = MaterialTheme.typography.bodySmall)
                }
            }
        },
        confirmButton = { TextButton(onClick = onInstall) { Text("Install") } },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

/** Browse for a .lkplug: directories descend, plugin files pick. */
@Composable
private fun LkplugPickerDialog(onPick: (String) -> Unit, onDismiss: () -> Unit) {
    var cur by remember {
        mutableStateOf(android.os.Environment.getExternalStorageDirectory())
    }
    var entries by remember { mutableStateOf<List<java.io.File>>(emptyList()) }
    LaunchedEffect(cur) {
        entries = withContext(Dispatchers.IO) {
            (cur.listFiles() ?: emptyArray())
                .filter { (it.isDirectory && it.canRead()) || it.name.endsWith(".lkplug", true) }
                .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Choose a plugin file") },
        text = {
            Column(Modifier.heightIn(max = 380.dp).verticalScroll(rememberScrollState())) {
                Text(
                    cur.absolutePath,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                cur.parentFile?.let { parent ->
                    if (parent.canRead()) {
                        Text(
                            "⬑ ${parent.name.ifEmpty { "/" }}",
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { cur = parent }
                                .padding(vertical = 8.dp),
                        )
                    }
                }
                for (f in entries) {
                    Text(
                        if (f.isDirectory) "${f.name}/" else f.name,
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (f.isDirectory) Color.Unspecified else MaterialTheme.colorScheme.primary,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                if (f.isDirectory) cur = f else onPick(f.absolutePath)
                            }
                            .padding(vertical = 8.dp),
                    )
                }
                if (entries.isEmpty()) {
                    Text(
                        "Nothing to read here.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// ---- rows -------------------------------------------------------------------

/**
 * A group heading inside a section, with the rule that separates it from the
 * group before it.
 *
 * `first` is the heading at the TOP of a pane, which draws no rule: the pane's
 * title bar already has one, and the two together read as a double line with a
 * sliver of background trapped between them.
 */
@Composable
internal fun SectionHeader(text: String, first: Boolean = false) {
    if (!first) HorizontalDivider(Modifier.padding(top = 12.dp))
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
