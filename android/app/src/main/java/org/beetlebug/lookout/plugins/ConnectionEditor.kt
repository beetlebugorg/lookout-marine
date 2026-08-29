package org.beetlebug.lookout.plugins

// The connection editor: the repeating lists a plugin declares, and the rows
// the mariner fills in.
//
// This is where the mariner names their own boat's gateway, so it has to work
// with a thumb, at a slant, in the wet.
//
// EVERY WORD HERE COMES FROM THE MANIFEST: the heading, the sentence under the
// rows, what an empty list says and what the add button is called ("Add
// Connection" for NMEA, "Add Server" for Signal K). Nothing is an Android
// string resource, because nothing here is Android's to name. So are the
// COLUMNS: four are standard (a name, an address, a port and an on/off switch)
// but a plugin may declare more, and the editor renders whatever the schema
// lists, by kind.
//
// A row EXPANDS IN PLACE rather than opening a second sheet. The settings are
// already a bottom sheet, and stacking another over it puts the mariner two
// dismissals deep in a modal on a moving boat; expanding also keeps the live
// status line visible while the address is being typed, which is the whole
// feedback loop — type it, watch it go green.

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import org.beetlebug.lookout.plugins.DiscoveredService
import org.beetlebug.lookout.plugins.Discovery
import org.beetlebug.lookout.plugins.PluginField
import org.beetlebug.lookout.plugins.PluginListSchema
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.plugins.PluginRow
import org.beetlebug.lookout.plugins.PluginStatusItem
import org.beetlebug.lookout.plugins.newRow
import org.beetlebug.lookout.plugins.rowFrom
import org.beetlebug.lookout.settings.Footer
import org.beetlebug.lookout.settings.SectionHeader

/**
 * Every repeating list on this section, as rows that can be added to, edited
 * and removed.
 */
@Composable
internal fun PluginLists(
    registry: PluginRegistry,
    tab: String,
    controller: PluginSettingsController,
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
internal fun NearbyRow(service: DiscoveredService, onAdd: () -> Unit) {
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
internal fun statusColour(status: PluginStatusItem?): Color = when (status?.tone) {
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
internal fun StatusDot(status: PluginStatusItem?) {
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
internal fun ConnectionEditor(
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
internal fun AddRowButton(schema: PluginListSchema, count: Int, onAdd: () -> Unit) {
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
