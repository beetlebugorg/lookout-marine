package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.charts.ChartCatalog
import org.beetlebug.lookout.charts.ChartLinkController

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * A published chart style, drawn as the chart.
 *
 * One online chart draws at a time, and while it draws it is the chart. The
 * Mariner settings do not reach inside it, because a linked chart renders the
 * way its publisher styled it.
 *
 * The shelf holds the charts in ChartCatalog, then whatever the mariner has
 * linked themselves, and the field below adds another. Lookout runs none of
 * these services, so a card names its publisher and the url its tiles come
 * from.
 */
@Composable
fun OnlineChartStep(links: ChartLinkController) {
    var entry by remember { mutableStateOf("") }

    // The shipped charts in their order, then the mariner's own. Holding the
    // order steady keeps the cards where they were when one is picked.
    val shipped = ChartCatalog.entries.map { it.url to it.name }
    val shippedUrls = shipped.map { it.first }.toSet()
    val added = links.chartLinks.filter { !shippedUrls.contains(it.url) }
    val shelf = shipped.map { (url, name) ->
        val own = links.chartLinks.firstOrNull { it.url == url }
        Triple(url, own?.name ?: name, own != null)
    } + added.map { Triple(it.url, it.name, true) }

    Column(
        Modifier.fillMaxWidth().padding(stepInset).padding(top = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        StepHeading(
            title = "Choose an online chart",
            blurb = "An online chart renders straight away, worldwide, and stores nothing. One shows at a time, and while it is on it is the chart.",
        )

        for ((url, name, mine) in shelf) {
            card(
                url = url,
                name = name,
                picked = links.activeChartLink == url,
                art = ChartCatalog.art(url),
                busy = links.chartLinkBusy && links.activeChartLink != url,
                onPick = {
                    // A shipped chart the mariner has not taken yet is added,
                    // which the core reads and then picks.
                    if (mine) links.selectChartLink(url) else links.addChartLink(url)
                },
                onRemove = if (mine) ({ links.removeChartLink(url) }) else null,
            )
        }

        Text("Another link", style = MaterialTheme.typography.titleSmall,
             fontWeight = FontWeight.SemiBold)
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = entry,
                onValueChange = { entry = it },
                singleLine = true,
                placeholder = { Text("https://…/style.json") },
                modifier = Modifier.weight(1f).semantics {
                    contentDescription = "first-run-chart-link"
                },
            )
            Spacer(Modifier.width(8.dp))
            TextButton(
                enabled = entry.isNotBlank(),
                onClick = {
                    val raw = entry
                    entry = ""
                    links.addChartLink(raw)
                },
            ) { Text("Add") }
        }
        Text(
            "MapLibre style or TileJSON link",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        links.chartLinkError?.let {
            Text(it, style = MaterialTheme.typography.bodySmall,
                 color = MaterialTheme.colorScheme.error)
        }

        StepWarning(
            lead = "Not for navigation.",
            body = "A published style is drawn exactly as its publisher styled it. Its depths and marks come from whoever made it, may be missing, outdated or wrong, and are not reduced to a chart datum by Lookout.",
        )
    }
}

/** One chart on the shelf: its picture, its name, and where its tiles come
 *  from. */
@Composable
private fun card(
    url: String,
    name: String,
    picked: Boolean,
    art: Int?,
    busy: Boolean,
    onPick: () -> Unit,
    onRemove: (() -> Unit)?,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .selectable(
                selected = picked,
                role = androidx.compose.ui.semantics.Role.RadioButton,
                onClick = onPick,
            )
            .semantics { contentDescription = "chart-link-$url" },
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(
            if (picked) 2.dp else 1.dp,
            if (picked) MaterialTheme.colorScheme.primary
            else MaterialTheme.colorScheme.outlineVariant,
        ),
    ) {
        Column {
            Box(
                Modifier
                    .fillMaxWidth()
                    .aspectRatio(1.9f)
                    .clip(RoundedCornerShape(topStart = 13.dp, topEnd = 13.dp)),
                contentAlignment = Alignment.Center,
            ) {
                if (art != null) {
                    Image(
                        painterResource(art),
                        contentDescription = null,
                        modifier = Modifier.fillMaxWidth(),
                        contentScale = ContentScale.Crop,
                    )
                } else {
                    PicturePlaceholder(Modifier.fillMaxWidth().height(120.dp))
                }
                if (busy) CircularProgressIndicator(Modifier.size(22.dp))
            }
            Row(
                Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = picked, onClick = null)
                Spacer(Modifier.width(6.dp))
                Column(Modifier.weight(1f)) {
                    Text(name, style = MaterialTheme.typography.titleSmall,
                         fontWeight = FontWeight.SemiBold)
                    Text(
                        url,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (onRemove != null) {
                    IconButton(onClick = onRemove) {
                        Icon(
                            Icons.Outlined.RemoveCircleOutline,
                            contentDescription = "Remove $name",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}
