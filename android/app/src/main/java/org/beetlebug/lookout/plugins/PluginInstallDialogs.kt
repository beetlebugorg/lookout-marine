package org.beetlebug.lookout.plugins

// Installing a plugin, and the consent that comes first.
//
// NOTHING IS INSTALLED BEFORE ITS PERMISSIONS ARE SHOWN. The sentences come
// from the core, so every shell shows the same words. Composed at SCREEN level
// rather than inside the Plugins pane: a .lkplug can arrive from another app
// with no settings sheet anywhere, and consent has to come up over the chart
// just the same.

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlin.math.max
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.beetlebug.lookout.hud.Chrome

/**
 * The consent and install-error dialogs. Composed at SCREEN level, not inside
 * the Plugins pane: a .lkplug can arrive from another app with no settings
 * sheet anywhere, and consent has to come up over the chart just the same.
 */
@Composable
fun PluginInstallDialogs(controller: PluginSettingsController) {
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
internal fun PluginConsentDialog(
    pkg: PluginSettingsController.PluginPackage,
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
internal fun LkplugPickerDialog(onPick: (String) -> Unit, onDismiss: () -> Unit) {
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
