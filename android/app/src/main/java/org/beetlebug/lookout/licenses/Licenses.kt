package org.beetlebug.lookout.licenses

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.ui.SectionHeader

import org.beetlebug.lookout.ui.Footer
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.material3.OutlinedTextField
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import android.os.Build
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * The licenses screen: this app's terms, and every component the build is made
 * from.
 *
 * The core bakes vendor/licenses/licenses.json into the binary and hands it
 * over whole ([Lookout.licenses]), so this needs no connection, no file and
 * no chart open. The entries whose `shells` array names "android" are the ones
 * this build carries; the rest belong to other shells and are dropped.
 *
 * A license text is shown WHOLE. Nothing here truncates one, reflows one or
 * summarises one: only the width of the view breaks a line.
 *
 * What is SHARED with the other shells is the product: which entries appear,
 * the app's own entry heading the list and staying out of the component count,
 * the name-and-summary against license-and-pin row, the short license column,
 * an unresolved entry saying so rather than showing an empty pane, and the
 * NOTICE sitting above the license. What is native is the chrome: Material
 * type, colours, ripple and the back gesture.
 */

/** One component this build carries. A field upstream states nothing for is an
 *  empty string, never null. */
data class LicenseComponent(
    val id: String,
    val name: String,
    val group: String,
    val summary: String,
    /** Empty when the build could not determine the terms. */
    val license: String,
    /** The same terms for a narrow column, empty when no shorter. */
    val licenseShort: String,
    /** Why, when [license] is empty. */
    val licenseNote: String,
    val version: String,
    val commit: String,
    val pinnedIn: String,
    val copyright: String,
    val url: String,
    val text: String,
    /** The component's NOTICE, empty when it ships none. */
    val notice: String,
) {
    /** What the detail's License row reads. */
    val licenseLabel: String get() = license.ifEmpty { "Not resolved" }

    /** The short form for the list column, falling back to the full label. */
    val licenseColumnLabel: String
        get() = if (license.isEmpty()) "Not resolved" else licenseShort.ifEmpty { license }

    /** The version, or the commit when a component is pinned to one. */
    val pinLabel: String get() = version.ifEmpty { commit.take(7) }
}

/** This app's own terms. Not a component, and never in the component count. */
data class LicenseApp(
    val name: String,
    val summary: String,
    val license: String,
    val copyright: String,
    val url: String,
    val text: String,
)

data class LicenseManifest(val app: LicenseApp, val components: List<LicenseComponent>) {
    /** The groups in the order the manifest lists them, each with its rows. */
    val groups: List<Pair<String, List<LicenseComponent>>>
        get() {
            // LinkedHashMap keeps first-seen order, which IS manifest order.
            val byGroup = LinkedHashMap<String, MutableList<LicenseComponent>>()
            for (c in components) byGroup.getOrPut(c.group) { ArrayList() }.add(c)
            return byGroup.map { (name, items) -> name to items.toList() }
        }

    companion object {
        /** The baked list. Read once: it is static in the core and cannot
         *  change while the process runs. */
        val current: LicenseManifest? by lazy { decode(Lookout.licenses()) }

        /**
         * The flat read: fourteen strings each, this app's terms first, then
         * the components. `internal` so the suite drives the same walk.
         */
        internal fun decode(flat: Array<String>?): LicenseManifest? {
            if (flat == null || flat.size < FIELDS) return null
            val app = LicenseApp(
                name = flat[1],
                summary = flat[3],
                license = flat[4],
                copyright = flat[10],
                url = flat[11],
                text = flat[12],
            )
            val out = ArrayList<LicenseComponent>((flat.size - FIELDS) / FIELDS)
            var k = FIELDS
            while (k + FIELDS <= flat.size) {
                out.add(
                    LicenseComponent(
                        id = flat[k],
                        name = flat[k + 1],
                        group = flat[k + 2],
                        summary = flat[k + 3],
                        license = flat[k + 4],
                        licenseShort = flat[k + 5],
                        licenseNote = flat[k + 6],
                        version = flat[k + 7],
                        commit = flat[k + 8],
                        pinnedIn = flat[k + 9],
                        copyright = flat[k + 10],
                        url = flat[k + 11],
                        text = flat[k + 12],
                        notice = flat[k + 13],
                    ),
                )
                k += FIELDS
            }
            return LicenseManifest(app, out)
        }

        /** LOOKOUT_LICENSES_GROUP_ABOVE. Above this many components a screen
         *  groups the rows under their headings and offers a search. */
        const val GROUP_ABOVE = 12

        private const val FIELDS = 14
    }
}

/** The screen's selection: this app, or one of the components by id. */
sealed interface LicenseSelection {
    data object App : LicenseSelection
    data class Component(val id: String) : LicenseSelection
}

/**
 * The list, or a line saying why there is none. An entry point that did nothing
 * would hide a build whose list will not decode.
 *
 * The detail is PUSHED, the way a section of the settings is: the license text
 * wants the whole width, and a phone has none to spare beside a list.
 */
@Composable
fun LicensesScreen(
    manifest: LicenseManifest?,
    selection: LicenseSelection?,
    onOpen: (LicenseSelection) -> Unit,
) {
    if (manifest == null) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            Text(
                "License list unavailable",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                "This build's list could not be read.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        return
    }
    when (selection) {
        null -> LicenseList(manifest, onOpen)
        is LicenseSelection.App -> AppLicenseDetail(manifest.app)
        is LicenseSelection.Component -> {
            val c = manifest.components.firstOrNull { it.id == selection.id }
            if (c != null) ComponentLicenseDetail(c) else LicenseList(manifest, onOpen)
        }
    }
}

/**
 * The list. Group headings appear above twelve entries and not below: under
 * that the headings outnumber the rows.
 */
@Composable
private fun LicenseList(manifest: LicenseManifest, onOpen: (LicenseSelection) -> Unit) {
    // Search and the group headings earn their place above twelve entries and
    // not below: under that the headings outnumber the rows and the field is a
    // control for a list that fits on one screen.
    val long = manifest.components.size > LicenseManifest.GROUP_ABOVE
    var search by remember { mutableStateOf("") }
    val term = search.trim().lowercase()
    val matching = if (term.isEmpty()) manifest.components else manifest.components.filter {
        it.name.lowercase().contains(term) ||
            it.summary.lowercase().contains(term) ||
            it.licenseColumnLabel.lowercase().contains(term)
    }
    val grouped = long && term.isEmpty()
    Column(
        Modifier
            .fillMaxHeight()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 32.dp)
            .testTag("licenses-list"),
    ) {
        if (long) {
            OutlinedTextField(
                value = search,
                onValueChange = { search = it },
                singleLine = true,
                label = { Text("Search ${manifest.components.size} components") },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 8.dp)
                    .testTag("licenses-search"),
            )
        }
        SectionHeader("This app", first = true)
        LicenseRow(
            name = manifest.app.name,
            summary = manifest.app.copyright,
            trailing = manifest.app.license,
            pin = appVersion(),
            strong = true,
        ) { onOpen(LicenseSelection.App) }

        if (grouped) {
            for ((group, items) in manifest.groups) {
                SectionHeader(group)
                for (c in items) ComponentRow(c, onOpen)
            }
        } else {
            SectionHeader("Components")
            for (c in matching) ComponentRow(c, onOpen)
            // A search that finds nothing says so. An empty list under a
            // filled-in field reads as a list that failed to load.
            if (matching.isEmpty()) Footer("Nothing matches \u201C$search\u201D.")
        }
    }
}

@Composable
private fun ComponentRow(c: LicenseComponent, onOpen: (LicenseSelection) -> Unit) {
    LicenseRow(
        name = c.name,
        summary = c.summary,
        trailing = c.licenseColumnLabel,
        pin = c.pinLabel,
        unresolved = c.license.isEmpty(),
    ) { onOpen(LicenseSelection.Component(c.id)) }
}

/** One row: what it is on the left, its license and pin on the right. */
@Composable
private fun LicenseRow(
    name: String,
    summary: String,
    trailing: String,
    pin: String,
    strong: Boolean = false,
    unresolved: Boolean = false,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            // clickable, not a Button: the whole row is the target, and it
            // carries Material's ripple for free.
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                name,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (strong) FontWeight.SemiBold else FontWeight.Normal,
            )
            if (summary.isNotEmpty()) {
                Text(
                    summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(horizontalAlignment = Alignment.End) {
            Text(
                trailing,
                style = MaterialTheme.typography.bodySmall,
                color = if (unresolved) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (pin.isNotEmpty()) {
                Text(
                    pin,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.width(4.dp))
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null, // the row's own text says where it goes
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// ---- the detail panes -------------------------------------------------------

@Composable
private fun AppLicenseDetail(app: LicenseApp) {
    LicenseScroll {
        LicenseHeading(app.name, app.summary)
        LicenseFacts(
            listOf(
                Triple("License", app.license, false),
                Triple("Version", appVersion(), true),
                Triple("Copyright", app.copyright, false),
            )
        )
        UpstreamBlock(app.url)
        LicenseBody(app.license, "", app.text)
    }
}

@Composable
private fun ComponentLicenseDetail(c: LicenseComponent) {
    LicenseScroll {
        LicenseHeading(c.name, c.summary)

        if (c.license.isEmpty()) {
            UnresolvedBlock(c.licenseNote)
        }

        val facts = ArrayList<Triple<String, String, Boolean>>()
        facts.add(Triple("License", c.licenseLabel, false))
        if (c.version.isNotEmpty()) facts.add(Triple("Version", c.version, true))
        if (c.commit.isNotEmpty()) facts.add(Triple("Commit", c.commit, true))
        facts.add(Triple("Pinned in", c.pinnedIn, true))
        facts.add(Triple("Copyright", c.copyright, false))
        LicenseFacts(facts)

        UpstreamBlock(c.url)
        // A NOTICE is a separate obligation from the license, so it sits above it.
        if (c.notice.isNotEmpty()) NoticeBlock(c.notice)
        LicenseBody(c.licenseLabel, if (c.license.isEmpty()) "" else c.licenseNote, c.text)
    }
}

@Composable
private fun LicenseScroll(content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxHeight()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(top = 8.dp, bottom = 32.dp)
            .testTag("license-detail"),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) { content() }
}

@Composable
private fun LicenseHeading(name: String, summary: String) {
    Column {
        Text(name, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        if (summary.isNotEmpty()) {
            Text(
                summary,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** A component whose terms the build could not determine says so. An empty
 *  pane would read as "no obligation". */
@Composable
private fun UnresolvedBlock(note: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(
                MaterialTheme.colorScheme.surfaceVariant,
                RoundedCornerShape(8.dp),
            )
            .padding(12.dp),
    ) {
        Icon(
            Icons.Outlined.WarningAmber,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.error,
        )
        Spacer(Modifier.width(12.dp))
        Column {
            Text(
                "License not resolved",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
            )
            if (note.isNotEmpty()) {
                Text(
                    note,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** The label-and-value rows. A commit, a path or a version is monospaced. */
@Composable
private fun LicenseFacts(rows: List<Triple<String, String, Boolean>>) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp),
    ) {
        rows.forEachIndexed { i, r ->
            if (i > 0) HorizontalDivider(color = Color.Transparent)
            Row(Modifier.fillMaxWidth().padding(vertical = 7.dp)) {
                Text(
                    r.first,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(96.dp),
                )
                Text(
                    r.second,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = if (r.third) FontFamily.Monospace else FontFamily.Default,
                )
            }
        }
    }
}

/** The upstream address, with its own copy button. Opening it needs a
 *  connection; copying it does not. */
@Composable
private fun UpstreamBlock(url: String) {
    val clipboard = LocalClipboardManager.current
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
            .padding(12.dp),
    ) {
        Text(
            "Upstream",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                url,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = { clipboard.setText(AnnotatedString(url)) }) {
                Icon(
                    Icons.Outlined.ContentCopy,
                    contentDescription = "Copy address",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun NoticeBlock(text: String) {
    Column(Modifier.fillMaxWidth()) {
        Text(
            "NOTICE",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
                .padding(12.dp),
        )
    }
}

/** The license itself, whole. */
@Composable
private fun LicenseBody(title: String, note: String, text: String) {
    Column(Modifier.fillMaxWidth()) {
        if (text.isEmpty()) {
            Text(
                "No license text.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            return@Column
        }
        Text(
            title.uppercase(java.util.Locale.US),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (note.isNotEmpty()) {
            Text(
                note,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
                .padding(12.dp)
                .testTag("license-text"),
        )
    }
}

/**
 * The version this build reports, as the About and Licenses screens say it.
 *
 * Read from the installed package rather than BuildConfig: that is what the
 * device actually has, and it needs no extra build feature turned on.
 */
@Composable
internal fun appVersion(): String {
    val ctx = LocalContext.current
    return try {
        val info = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        val code =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
            else @Suppress("DEPRECATION") info.versionCode.toLong()
        "${info.versionName} ($code)"
    } catch (e: Exception) {
        ""
    }
}
