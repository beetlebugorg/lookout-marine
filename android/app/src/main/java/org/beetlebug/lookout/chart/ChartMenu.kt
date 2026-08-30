// The long-press chart menu: the place's coordinates, the pick, and the
// marker verbs — the touch shell's stand-in for the reference's right-click
// panel, drawn as app chrome for the same reason the Mac draws its own (a
// system menu would put a bright panel on a night passage).
package org.beetlebug.lookout.chart

import org.beetlebug.lookout.hud.coordString

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup

/** The mark's name in the header, the S-52 magenta of the mark itself. */
private val MARK_MAGENTA = Color(0xFFE0218A)

@Composable
fun ChartMenuPanel(
    menu: ChartController.ChartMenu,
    onPick: () -> Unit,
    onDropMarker: () -> Unit,
    onRenameMarker: () -> Unit,
    onRemoveMarker: () -> Unit,
    onDismiss: () -> Unit,
) {
    val density = LocalDensity.current
    val clipboard = LocalClipboardManager.current
    // The menu's point is in logical points, which ARE dp on this shell.
    val at = with(density) { IntOffset(menu.at.x.dp.roundToPx(), menu.at.y.dp.roundToPx()) }
    Popup(offset = at, onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(12.dp),
            tonalElevation = 3.dp,
            shadowElevation = 6.dp,
            modifier = Modifier.width(236.dp),
        ) {
            Column(Modifier.padding(vertical = 6.dp)) {
                // The header says WHERE, so a position can be read or copied
                // without opening anything.
                Text(
                    coordString(menu.lat, menu.lon),
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
                )
                if (menu.markerId != 0L) {
                    Text(
                        menu.markerName,
                        style = MaterialTheme.typography.labelMedium,
                        color = MARK_MAGENTA,
                        modifier = Modifier.padding(horizontal = 14.dp),
                    )
                }
                HorizontalDivider(Modifier.padding(vertical = 4.dp))
                MenuItem("Pick report", onPick)
                if (menu.markerId == 0L) {
                    MenuItem("Drop marker", onDropMarker)
                } else {
                    MenuItem("Rename marker", onRenameMarker)
                    MenuItem("Remove marker", onRemoveMarker)
                }
                MenuItem("Copy position") {
                    clipboard.setText(AnnotatedString(coordString(menu.lat, menu.lon)))
                    onDismiss()
                }
            }
        }
    }
}

@Composable
private fun MenuItem(label: String, onTap: () -> Unit) {
    Text(
        label,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onTap)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    )
}

/** Rename, clipped to 32 characters in the field as well as in the core. */
@Composable
fun MarkerRenameDialog(current: String, onCommit: (String) -> Unit, onCancel: () -> Unit) {
    var text by remember { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("Rename marker") },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { if (it.length <= 32) text = it },
                singleLine = true,
            )
        },
        confirmButton = { TextButton(onClick = { onCommit(text) }) { Text("Rename") } },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}
