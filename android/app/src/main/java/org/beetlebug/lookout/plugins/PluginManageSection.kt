package org.beetlebug.lookout.plugins

// The section that talks ABOUT plugins: what the mariner installed, what it may
// reach, and removing it. Never the bundled set, whose ids belong to the
// application and which cannot be removed.

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.plugins.PluginInfo
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.settings.Footer
import org.beetlebug.lookout.settings.SectionHeader

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
internal fun statusCaption(p: PluginInfo): String? {
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
internal fun PluginsManageSection(registry: PluginRegistry, controller: PluginSettingsController) {
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
