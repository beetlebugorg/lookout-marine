package org.beetlebug.lookout.plugins

// A plugin's own settings controls, rendered from the manifest schema.
//
// The shell knows a number, a toggle and a text field, and nothing about what
// any of them mean. A plugin that adds a setting gets it on screen with no
// shell change, in the section its manifest names.

import androidx.compose.material3.TextButton
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import org.beetlebug.lookout.ui.Footer
import org.beetlebug.lookout.ui.SectionHeader

/**
 * Every plugin group that belongs on this section, under its own heading.
 *
 * A change goes straight to the core and the registry is re-read, because the
 * core clamps a number to the range the schema published — so the value that
 * comes back is the value in force, which is not always the one asked for.
 */
@Composable
internal fun PluginGroups(groups: List<PluginGroup>, controller: PluginSettingsController, first: Boolean) {
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
        ResetGroupButton(group, controller)
    }
}

/**
 * Put one group back to what its manifest asks for.
 *
 * A plugin's settings are the only ones in the sheet a mariner cannot reason
 * back to a default: the core's own controls have S-52 behind them, and a
 * plugin's have whatever its author chose. Offered per group rather than for
 * the whole plugin, because a group is what is read and changed together.
 *
 * Shown only where something has moved off its default. A control that does
 * nothing is a question nobody asked.
 */
@Composable
private fun ResetGroupButton(group: PluginGroup, controller: PluginSettingsController) {
    val moved = group.fields.any { it.kind != PluginField.Kind.TEXT && it.value != it.defaultValue }
    if (!moved) return
    TextButton(
        onClick = {
            for (f in group.fields) {
                if (f.kind == PluginField.Kind.TEXT) continue
                controller.setPluginScalar(group.pluginId, f, f.defaultValue)
            }
        },
        modifier = Modifier.padding(start = 12.dp),
    ) { Text("Reset to defaults") }
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

/** The described-row pattern: the switch's title, and under it what it does. */
@Composable
internal fun PluginToggleRow(field: PluginField, onChange: (Boolean) -> Unit) {
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
internal fun PluginNumberRow(field: PluginField, onCommit: (Double) -> Unit) {
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
