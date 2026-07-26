package org.beetlebug.lookout

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material3.MaterialTheme
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
fun ChartsSection(charts: ChartsModel, onRequestAccess: () -> Unit) {
    SectionHeader("Open charts")
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
        if (charts.scanning) CircularProgressIndicator(Modifier.size(20.dp))
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
        return "ENC source charts (*.000) — bake these with tile57 first."
    }
    return null
}
