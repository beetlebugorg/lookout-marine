package org.beetlebug.lookout.charts


import org.beetlebug.lookout.ui.Footer
import org.beetlebug.lookout.ui.SectionHeader

import androidx.compose.foundation.clickable
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.CloudDownload
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Sd
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

/**
 * The Charts tab: point the app at a baked library anywhere on the device.
 *
 * A plain directory browser rather than the system folder picker, because the
 * engine opens cells BY PATH (mmap, plus a parent walk to find the bake's
 * partition.tpart) and a SAF tree gives neither — the alternative was copying
 * the library into app storage, which for a real ENC bake means duplicating
 * gigabytes. So: broad read access, browse the real filesystem, open in place.
 */
@Composable
fun ChartsSection(
    charts: ChartsModel,
    links: ChartLinkController,
    raster: RasterController,
    noaa: NoaaController,
    onRequestAccess: () -> Unit,
) {
    // Which chart DRAWS is the pane's headline decision, so the gallery leads.
    // The library plumbing follows it, and the ways to add charts come last:
    // the order the other shells use, because it is the order the questions
    // are asked in.
    ChartLinksSection(links, charts.chartPaths.size)

    var pickingNoaa by remember { mutableStateOf(false) }
    var browsing by remember { mutableStateOf(false) }

    // The installed sets. A switch off keeps the set and takes it out of the
    // chart, so an entry is never lost by turning it off.
    SetsHeader(charts)
    val pictures = raster.charts
    if (charts.sets.isEmpty() && pictures.paths.isEmpty()) {
        Footer(if (charts.scanning) "Finding charts…" else "No chart sets")
    } else {
        for (set in charts.sets) ChartSetRow(set, charts)
        // The pictures, in the same list. A picture and a survey are different
        // kinds of chart, and the row says which, but they arrive in the same
        // folders and switch on the same way. Two lists made the mariner
        // remember which panel a file had gone into.
        //
        // Where they differ is what a switch MEANS. Surveys compose, so a set
        // is on or off. Only one picture can cover a piece of water, so the
        // pictures get a switch each, by whoever made them.
        PictureRows(raster)
    }
    // What is drawing, unless that is what the empty line above just said. A
    // library with nothing in it does not need telling twice.
    if (charts.chartPaths.isNotEmpty()) Footer(charts.activeLabel)

    charts.lastEmptyPick?.let {
        Footer(
            "No baked cells (*.pmtiles) under $it — that looks like an ENC " +
                "source tree, not a tile57 bake. Pick the bake's output folder: " +
                "the one holding partition.tpart next to tiles/.",
        )
    }

    // An import keeps running when the dialog closes; its progress must not
    // vanish with it.
    if (!browsing) {
        charts.importer.state?.let { st ->
            if (st.running) {
                LinearProgressIndicator(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 4.dp),
                )
                Footer("Importing ${st.name}. What has landed already draws; a stop keeps it.")
            }
        }
    }

    // A transfer, where the mariner started it. This pane stands over the
    // chart, so a download begun here otherwise runs behind it.
    if (noaa.phase == NoaaController.Phase.DOWNLOADING) {
        SectionHeader("Downloading from NOAA")
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (noaa.total > 0) {
                LinearProgressIndicator(
                    progress = { noaa.done.toFloat() / noaa.total },
                    modifier = Modifier.weight(1f),
                )
            } else {
                LinearProgressIndicator(Modifier.weight(1f))
            }
            Text(
                "${noaa.done} of ${noaa.total}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            TextButton(onClick = { noaa.cancel() }) { Text("Stop") }
        }
    }

    SectionHeader("Add charts")
    // NOAA first, and it stands whether or not files have been granted: the
    // download goes to the app's own folder, so a mariner with no file access
    // can still fill an empty library from here.
    AddChartRow(
        icon = Icons.Outlined.CloudDownload,
        title = "Get charts from NOAA…",
        detail = "Pick the waters you sail. Lookout downloads the cells and prepares them. Free.",
        enabled = charts.importer.state?.running != true &&
            noaa.phase != NoaaController.Phase.DOWNLOADING,
        tag = "get-charts-noaa",
        onClick = { pickingNoaa = true },
    )

    if (charts.storageAccess) {
        AddChartRow(
            icon = Icons.Outlined.FolderOpen,
            title = "Add from Files…",
            detail = "A folder of cells, or a chart already prepared.",
            enabled = charts.importer.state?.running != true,
            tag = "add-charts-files",
            onClick = { browsing = true },
        )
        Footer(
            "S-57 and S-101 cells (.000 with their updates) · charts Lookout has " +
                "already prepared (.pmtiles) · imagery and vendor charts (.mbtiles) · " +
                "BSB/KAP raster sheets (.kap, .bsb). Cells and raster sheets are " +
                "converted once on the way in. Encrypted S-63 cells are not supported.",
        )
    } else {
        // The grant stands where the browser would. Charts are read where they
        // lie and never copied, which is why the app wants to read outside its
        // own folder at all.
        Footer(
            "Charts are read where they lie — nothing is copied — so the app " +
                "needs permission to read files outside its own folder. " +
                "Grant “All files access”, then come back.",
        )
        Button(
            onClick = onRequestAccess,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
        ) { Text("Grant file access") }
        Footer(
            "Without it, only charts pushed into the app's own folder are " +
                "visible (adb push …/Android/data/org.beetlebug.lookout/files/charts).",
        )
    }

    if (pickingNoaa) {
        NoaaPickerDialog(charts, noaa) { pickingNoaa = false }
    }

    if (browsing) {
        AlertDialog(
            onDismissRequest = { browsing = false },
            confirmButton = {
                TextButton(onClick = { browsing = false }) { Text("Done") }
            },
            title = { Text("Chart library") },
            text = {
                Column(
                    Modifier
                        .heightIn(max = 440.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    FolderBrowser(charts, onOpened = { browsing = false })
                }
            },
        )
    }

}

/**
 * Charts by link: an online map AS the chart. Picking one renders that
 * publisher's MapLibre style instead of the built-in portrayal — Lookout's own
 * chart is just the default entry in the same list (the reference shell's
 * Chart list, row for row).
 */
@Composable
private fun ChartLinksSection(controller: ChartLinkController, cells: Int) {
    SectionHeader("Active chart", first = true)
    // A row of tiles rather than a list of names: two styles with similar
    // names are told apart by looking. One draws at a time, because two whole
    // charts cannot share the water.
    var adding by remember { mutableStateOf(false) }
    ChartGallery(controller, cells) { adding = true }

    // Only while a link draws, because that is when the rest of this pane
    // stops shaping the chart and the mariner is owed a reason. That a tile
    // draws when it is picked needs no saying.
    if (controller.activeChartLink != null) {
        Footer(
            "While a linked chart draws, the display, depth and symbol settings " +
                "do not shape it. You are seeing its publisher's own portrayal.",
        )
    }
    if (controller.chartLinkBusy) {
        LinearProgressIndicator(Modifier.padding(horizontal = 20.dp))
    }
    controller.chartLinkError?.let { Footer(it) }

    if (adding) AddChartDialog(controller) { adding = false }
}

/** Adding a chart by link, from the tile that offers it. */
@Composable
private fun AddChartDialog(controller: ChartLinkController, onDismiss: () -> Unit) {
    var link by remember { mutableStateOf("") }
    val submit = {
        if (link.isNotBlank()) {
            controller.addChartLink(link)
            onDismiss()
        }
    }
    // A style the mariner already holds. The picker hands back a content uri
    // rather than a path, and the controller copies the bytes somewhere the
    // core can open.
    val pick = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) {
            controller.addStyleFile(uri)
            onDismiss()
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add a chart") },
        text = {
            Column {
                OutlinedTextField(
                    value = link,
                    onValueChange = { link = it },
                    label = { Text("https://…/style.json") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { submit() }),
                )
                Spacer(Modifier.height(4.dp))
                TextButton(
                    onClick = { pick.launch(arrayOf("application/json", "*/*")) },
                    contentPadding = PaddingValues(0.dp),
                ) {
                    Icon(
                        Icons.Outlined.FolderOpen,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("Add a style file from this device")
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    "A style draws exactly what its publisher styled; bare tiles " +
                        "get a plain generated look. Either way the content comes " +
                        "from whoever made it, depths, symbols and warnings included.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = submit, enabled = link.isNotBlank()) { Text("Add") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** The sets, and what they hold together, on one line with the heading. */
@Composable
private fun SetsHeader(charts: ChartsModel) {
    // The rule and the spacing above the label are SectionHeader's, laid out
    // here rather than nested inside it: a Row that centres its children
    // against the summary swallowed the label's own top padding, and this
    // heading sat tighter under its rule than every other one.
    HorizontalDivider(Modifier.padding(top = 12.dp))
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "YOUR CHART SETS",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.primary,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.weight(1f),
        )
        val total = setsSummary(charts)
        if (total != null) {
            Text(
                total,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Every set together: how many charts, and what they weigh. */
private fun setsSummary(charts: ChartsModel): String? {
    if (charts.sets.isEmpty()) return null
    val n = charts.sets.sumOf { it.charts + it.pictures }
    if (n == 0) return null
    val bytes = charts.sets.sumOf { it.bytes }
    return "$n charts · ${bytes(bytes)}"
}

/**
 * One way to add charts: what it is, what it gets you, and where it leads.
 *
 * The detail line is not decoration. A mariner choosing between NOAA and their
 * own files is choosing between free official cover and a folder they already
 * have, and the row is where that choice is made.
 */
@Composable
private fun AddChartRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    detail: String,
    enabled: Boolean,
    tag: String,
    onClick: () -> Unit,
) {
    val ink = if (enabled) MaterialTheme.colorScheme.onSurface
              else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = tag }
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (enabled) MaterialTheme.colorScheme.primary
                   else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = ink)
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * The pictures installed, under the sets they came in with.
 *
 * Charts made of pictures: MBTiles of satellite imagery or another vendor's
 * charts. The ENC draws over them and drops its depth and land shading only
 * where they cover. Switch one off to keep it installed without drawing it.
 */
@Composable
private fun PictureRows(controller: RasterController) {
    val installed = controller.charts
    if (installed.paths.isEmpty()) return
    installed.groups.forEach { (provider, paths) ->
        // The provider switch: these files draw as one picture, so they go on
        // and off together.
        val groupOn = paths.any { installed.isEnabled(it) }
        SwitchRow(
            label = provider,
            checked = groupOn,
            onCheckedChange = { controller.setRasterGroupEnabled(paths, it) },
        )
        paths.forEach { p ->
            SwitchRow(
                label = File(p).name,
                checked = installed.isEnabled(p),
                indent = true,
                onCheckedChange = { controller.setRasterEnabled(p, it) },
                onRemove = { controller.removeRasterChart(p) },
            )
        }
    }
}

@Composable
private fun ChartSetRow(set: ChartSets.Set, charts: ChartsModel) {
    var confirming by remember(set.path) { mutableStateOf(false) }

    SwitchRow(
        label = set.title,
        checked = set.on,
        onCheckedChange = { charts.setOn(set.path, it) },
        onRemove = { confirming = true },
    )
    Text(
        text = summary(set),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 40.dp, end = 20.dp, bottom = 4.dp),
    )
    // What scales the set holds. A set that stops at Coastal does not draw the
    // harbour a passage ends in, and one line says so at a glance.
    val bands = remember(set.path, set.scanned, set.charts) { bandCounts(set) }
    if (bands.isNotEmpty()) {
        BandRamp(
            counts = bands,
            dimmed = !set.on,
            modifier = Modifier.padding(start = 40.dp, end = 20.dp, bottom = 10.dp),
        )
    }

    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Remove ${set.title}?") },
            text = {
                Text(
                    "The charts Lookout prepared from this folder are deleted. " +
                        "Your own files are not touched, and you can add the " +
                        "folder again.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    charts.remove(set.path)
                }) { Text("Remove") }
            },
            dismissButton = {
                TextButton(onClick = { confirming = false }) { Text("Cancel") }
            },
        )
    }
}

/**
 * What a set holds, in one line: the folder it came from, the counts, and the
 * bands. Until the core's background scan has read the folder there are no
 * counts to state, and saying "0 charts" of a set that has thousands is worse
 * than saying nothing yet.
 */
private fun summary(set: ChartSets.Set): String {
    val parts = mutableListOf<String>()
    // The folder it came from, unless that is what the title already says.
    if (set.name != set.title) parts.add(set.name)
    if (!set.scanned) {
        parts.add("reading…")
        return parts.joinToString(" · ")
    }
    val counts = mutableListOf<String>()
    if (set.charts > 0) counts.add(plural(set.charts, "chart"))
    if (set.pictures > 0) counts.add(plural(set.pictures, "picture"))
    if (set.unprepared > 0) counts.add("${set.unprepared} to prepare")
    if (counts.isEmpty()) counts.add("no charts")
    if (set.bytes > 0) counts.add(bytes(set.bytes))
    parts.add(counts.joinToString(", "))
    if (set.bandLo > 0) parts.add(bandRange(set.bandLo, set.bandHi))
    return parts.joinToString(" · ")
}

private fun plural(n: Int, one: String): String = if (n == 1) "$n $one" else "$n ${one}s"

/**
 * How many charts sit in each band. Read off the set's own file list, which
 * the index already holds, so nothing new crosses the boundary for it.
 */
private fun bandCounts(set: ChartSets.Set): List<Pair<Int, Int>> {
    if (!set.scanned || set.bandLo == 0) return emptyList()
    val byBand = HashMap<Int, Int>()
    for (f in ChartSets.files(set.path)) {
        if (f.band in 1..6) byBand[f.band] = (byBand[f.band] ?: 0) + 1
    }
    return byBand.entries.sortedBy { it.key }.map { it.key to it.value }
}

/** The bands present, in the words the readouts use. */
private fun bandRange(lo: Int, hi: Int): String =
    if (lo == hi) bandName(lo) else "${bandName(lo)} to ${bandName(hi)}"

private fun bandName(band: Int): String = when (band) {
    1 -> "Overview"
    2 -> "General"
    3 -> "Coastal"
    4 -> "Approach"
    5 -> "Harbor"
    6 -> "Berthing"
    else -> "—"
}

private fun bytes(n: Long): String = when {
    n >= 1_000_000_000 -> String.format(Locale.US, "%.1f GB", n / 1e9)
    n >= 1_000_000 -> String.format(Locale.US, "%.0f MB", n / 1e6)
    else -> String.format(Locale.US, "%.0f kB", n / 1e3)
}

/** One switch row, with an optional Remove. */
@Composable
private fun SwitchRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    indent: Boolean = false,
    onRemove: (() -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = if (indent) 40.dp else 20.dp, end = 20.dp, top = 2.dp, bottom = 2.dp),
    ) {
        Text(
            text = label,
            style = if (indent) MaterialTheme.typography.bodySmall
                    else MaterialTheme.typography.bodyMedium,
            color = if (checked) MaterialTheme.colorScheme.onSurface
                    else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (onRemove != null) {
            TextButton(onClick = onRemove) { Text("Remove") }
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/**
 * Browse to a folder and open it. Starts at the storage volumes; navigation is
 * one directory per tap, with the parent as the first row.
 */
@Composable
private fun FolderBrowser(charts: ChartsModel, onOpened: () -> Unit = {}) {
    val roots = charts.roots
    var cur by remember { mutableStateOf(roots.firstOrNull()) }
    var kids by remember { mutableStateOf<List<File>>(emptyList()) }
    var hint by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    // Listing and the library sniff both touch the filesystem: off the main
    // thread, and re-run whenever the directory changes.
    LaunchedEffect(cur) {
        val dir = cur
        if (dir == null) {
            kids = emptyList(); hint = null
            return@LaunchedEffect
        }
        val listed = withContext(Dispatchers.IO) {
            dir.listFiles()?.filter { it.isDirectory && it.canRead() }?.sortedBy { it.name.lowercase() }
                ?: emptyList()
        }
        val sniff = withContext(Dispatchers.IO) { libraryHint(dir) }
        kids = listed
        hint = sniff
    }

    Text(
        text = cur?.absolutePath ?: "Storage",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
    )

    // The parent row, or the volume list when at (or above) a root.
    val parent = cur?.parentFile
    if (cur != null && parent != null && parent.canRead() && roots.none { it.path == cur?.path }) {
        BrowseRow(Icons.Default.ArrowUpward, parent.name.ifEmpty { "/" }) { cur = parent }
    } else if (roots.size > 1) {
        roots.forEach { r ->
            BrowseRow(Icons.Default.Sd, r.name.ifEmpty { r.path }) { cur = r }
        }
    }

    kids.forEach { d ->
        BrowseRow(Icons.Default.Folder, d.name) { cur = d }
    }
    if (cur != null && kids.isEmpty()) {
        Footer("No readable subfolders here.")
    }

    hint?.let { Footer(it) }

    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Button(
            enabled = cur != null && !charts.scanning,
            onClick = {
                val dir = cur ?: return@Button
                // select() walks the tree off the main thread and only then
                // swaps the library, so a mis-pick never blanks the chart.
                // The dialog closes once the library is open — the pick was
                // the errand it opened for.
                scope.launch {
                    charts.add(dir)
                    onOpened()
                }
            },
        ) { Text(if (charts.scanning) "Scanning…" else "Add this folder") }
        // The import: bake what stands here — raw ENC cells, BSB/KAP sheets,
        // an agency archive — into the app's own library, and open THAT.
        OutlinedButton(
            enabled = cur != null && charts.importer.state?.running != true,
            onClick = {
                val dir = cur ?: return@OutlinedButton
                charts.importer.start(dir) { out ->
                    if (out != null) scope.launch { charts.add(out) }
                }
            },
        ) { Text("Import") }
        if (charts.scanning) CircularProgressIndicator(Modifier.size(20.dp))
    }

    charts.importer.state?.let { st ->
        if (st.running) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (st.total > 0) {
                    LinearProgressIndicator(
                        progress = { st.done.toFloat() / st.total },
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    LinearProgressIndicator(Modifier.weight(1f))
                }
                Text(
                    if (st.total > 0) "${st.done} of ${st.total}" else "Finding charts…",
                    style = MaterialTheme.typography.bodySmall,
                )
                TextButton(onClick = { charts.importer.cancel() }) { Text("Stop") }
            }
            Footer("Importing ${st.name}. What has landed already draws; a stop keeps it.")
        } else if (st.failed) {
            Footer("Nothing could be prepared from ${st.name}.")
        }
    }
}

@Composable
private fun BrowseRow(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

/**
 * A cheap "is this a library?" sniff for the folder you're standing in: the
 * bake's sidecar, or cells at the top or one level down. Deliberately shallow —
 * the full walk happens only when a folder is actually opened.
 */
private fun libraryHint(dir: File): String? {
    val top = dir.listFiles() ?: return null
    if (top.any { it.isFile && it.name == "partition.tpart" }) {
        return "This folder holds partition.tpart — a tile57 bake. Open it."
    }
    if (top.any { it.isFile && it.extension == "pmtiles" }) return "Baked cells here."
    val nested = top.firstOrNull { it.isDirectory && it.name == "tiles" }
        ?: top.firstOrNull { d -> d.isDirectory && d.listFiles()?.any { it.extension == "pmtiles" } == true }
    if (nested != null) return "Baked cells under ${nested.name}/."
    if (top.any { it.isFile && it.name.endsWith(".000") }) {
        return "ENC source charts (*.000) — Import bakes them into the library."
    }
    return null
}
