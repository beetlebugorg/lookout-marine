package org.beetlebug.lookout

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Sd
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

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
    controller: ChartController,
    onRequestAccess: () -> Unit,
) {
    SectionHeader("Open charts", first = true)
    Footer(charts.activeLabel)

    if (!charts.storageAccess) {
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
        return
    }

    FolderBrowser(charts)

    charts.lastEmptyPick?.let {
        Footer(
            "No baked cells (*.pmtiles) under $it — that looks like an ENC " +
                "source tree, not a tile57 bake. Pick the bake's output folder: " +
                "the one holding partition.tpart next to tiles/.",
        )
    }

    if (charts.selected != null) {
        SectionHeader("Fall back")
        TextButton(
            onClick = charts::clearSelection,
            modifier = Modifier.padding(horizontal = 12.dp),
        ) { Text("Use pushed / bundled charts instead") }
    }

    RasterChartsSection(controller)
    ChartLinksSection(controller)
}

/**
 * Charts by link: an online map AS the chart. Picking one renders that
 * publisher's MapLibre style instead of the built-in portrayal — Lookout's own
 * chart is just the default entry in the same list (the reference shell's
 * Chart list, row for row).
 */
@Composable
private fun ChartLinksSection(controller: ChartController) {
    SectionHeader("Chart")
    Footer(
        "A chart added by link draws INSTEAD of Lookout's own: the publisher " +
            "styles it and their tiles are fetched as you sail. While one is " +
            "picked, the display settings above shape only Lookout's chart.",
    )
    LinkChoiceRow(
        title = "Lookout chart",
        desc = "The built-in portrayal of your opened cells.",
        selected = controller.activeChartLink == null,
    ) { controller.selectChartLink(null) }
    for (link in controller.chartLinks) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                LinkChoiceRow(
                    title = link.name.ifEmpty { link.url },
                    desc = link.url,
                    selected = controller.activeChartLink == link.url,
                ) { controller.selectChartLink(link.url) }
            }
            TextButton(onClick = { controller.refreshChartLink(link.url) }) { Text("Refresh") }
            TextButton(onClick = { controller.removeChartLink(link.url) }) {
                Text("Remove", color = MaterialTheme.colorScheme.error)
            }
        }
    }
    var newLink by remember { mutableStateOf("") }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val submit = {
            if (newLink.isNotBlank()) {
                controller.addChartLink(newLink)
                newLink = ""
            }
        }
        OutlinedTextField(
            value = newLink,
            onValueChange = { newLink = it },
            label = { Text("https://…/style.json") },
            singleLine = true,
            modifier = Modifier.weight(1f),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { submit() }),
        )
        TextButton(onClick = submit, enabled = newLink.isNotBlank()) { Text("Add") }
    }
    if (controller.chartLinkBusy) {
        LinearProgressIndicator(Modifier.padding(horizontal = 20.dp))
    }
    controller.chartLinkError?.let { Footer(it) }
    Footer("A style link or a TileJSON tile source; also a style.json on the device by path.")
}

/** The radio row of the Chart list; the whole row is the touch target. */
@Composable
private fun LinkChoiceRow(title: String, desc: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect)
            .padding(start = 16.dp, end = 20.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                desc,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * The mariner's own picture charts. A different KIND of chart from the ENC, so
 * it gets its own section rather than a row in the library browser.
 */
@Composable
private fun RasterChartsSection(controller: ChartController) {
    val installed = controller.rasterCharts
    var browsing by remember { mutableStateOf(false) }

    SectionHeader("Raster charts")
    Footer(
        "Charts made of pictures: MBTiles of satellite imagery or another " +
            "vendor's charts. The ENC draws over them and drops its depth and " +
            "land shading only where they cover. Switch one off to keep it " +
            "installed without drawing it.",
    )

    if (installed.paths.isEmpty()) {
        Footer("No raster charts.")
    } else {
        installed.groups.forEach { (provider, paths) ->
            // The provider switch: these files draw as one picture, so they go
            // on and off together.
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

    TextButton(
        onClick = { browsing = !browsing },
        modifier = Modifier.padding(horizontal = 12.dp),
    ) { Text(if (browsing) "Done adding" else "Add raster charts…") }

    if (browsing) {
        RasterBrowser(controller)
    }
}

/**
 * Browse to a folder of raster charts and add every one under it. The same
 * approach the library browser takes, and for the same reason: the engine opens
 * these BY PATH and mmaps them, and a copy of a half-gigabyte download into app
 * storage would spend the space twice.
 */
@Composable
private fun RasterBrowser(controller: ChartController) {
    val roots = controller.rasterCharts.let { _ -> storageRootsRemembered() }
    var cur by remember { mutableStateOf(roots.firstOrNull()) }
    var kids by remember { mutableStateOf<List<File>>(emptyList()) }
    var found by remember { mutableStateOf<List<String>>(emptyList()) }

    LaunchedEffect(cur) {
        val dir = cur
        if (dir == null) {
            kids = emptyList(); found = emptyList()
            return@LaunchedEffect
        }
        val listed = withContext(Dispatchers.IO) {
            dir.listFiles()?.filter { it.isDirectory && it.canRead() }
                ?.sortedBy { it.name.lowercase() } ?: emptyList()
        }
        // Only this directory's own charts, not the whole subtree: the walk is
        // what the Add button does, and a browser that scans everything below
        // every folder it lists would crawl a storage volume on each tap.
        val here = withContext(Dispatchers.IO) {
            dir.listFiles()?.filter {
                it.isFile && it.extension.equals("mbtiles", ignoreCase = true)
            }?.map { it.absolutePath }?.sorted() ?: emptyList()
        }
        kids = listed
        found = here
    }

    Text(
        text = cur?.absolutePath ?: "Storage",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
    )

    val parent = cur?.parentFile
    if (cur != null && parent != null && parent.canRead() && roots.none { it.path == cur?.path }) {
        BrowseRow(Icons.Default.ArrowUpward, parent.name.ifEmpty { "/" }) { cur = parent }
    }
    kids.forEach { d ->
        BrowseRow(Icons.Default.Folder, d.name) { cur = d }
    }

    if (found.isNotEmpty()) {
        Button(
            onClick = { controller.addRasterCharts(found) },
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
        ) { Text("Add ${found.size} here") }
    } else {
        Footer("No .mbtiles in this folder.")
    }
}

@Composable
private fun storageRootsRemembered(): List<File> {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    return remember { storageRoots(ctx) }
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
private fun FolderBrowser(charts: ChartsModel) {
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

    SectionHeader("Choose a folder")
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
                scope.launch { charts.select(dir) }
            },
        ) { Text(if (charts.scanning) "Scanning…" else "Open this folder") }
        // The import: bake what stands here — raw ENC cells, BSB/KAP sheets,
        // an agency archive — into the app's own library, and open THAT.
        OutlinedButton(
            enabled = cur != null && charts.importer.state?.running != true,
            onClick = {
                val dir = cur ?: return@OutlinedButton
                charts.importer.start(dir) { out ->
                    if (out != null) scope.launch { charts.select(out) }
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
