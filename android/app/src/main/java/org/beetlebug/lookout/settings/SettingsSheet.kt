package org.beetlebug.lookout.settings

import org.beetlebug.lookout.ui.Footer
import org.beetlebug.lookout.ui.SectionHeader

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import org.beetlebug.lookout.chart.ChartController
import org.beetlebug.lookout.charts.ChartsModel
import org.beetlebug.lookout.charts.ChartsSection
import org.beetlebug.lookout.licenses.LicenseManifest
import org.beetlebug.lookout.licenses.LicenseSelection
import org.beetlebug.lookout.licenses.LicensesScreen
import org.beetlebug.lookout.plugins.PluginGroups
import org.beetlebug.lookout.plugins.PluginLists
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.plugins.PluginsManageSection
import org.beetlebug.lookout.plugins.SettingsSection

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
                "charts" -> ChartsSection(charts, controller.chartLinkController, controller.rasterController, onRequestAccess)
                "plugins" -> PluginsManageSection(registry, controller.plugins)
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
            PluginGroups(groups, controller.plugins, first = !core && !hasTables)
            PluginLists(registry, id, controller.plugins, first = !core && !hasTables && groups.isEmpty())
        }
    }
}

// ---- Display ----------------------------------------------------------------

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
