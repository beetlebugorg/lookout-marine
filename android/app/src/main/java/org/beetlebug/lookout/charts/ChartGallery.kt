package org.beetlebug.lookout.charts

import org.beetlebug.lookout.R

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * The charts to draw, as tiles.
 *
 * One chart draws at a time. Lookout's own chart is built from the installed
 * sets; a link is a publisher's style drawn instead of it. A row of tiles
 * rather than a list, so two styles with similar names are told apart by
 * looking.
 *
 * A shipped style carries its picture in the app. One the mariner pasted shows
 * its kind and its url: rendering a style needs it resolved and its tiles
 * fetched, and this shell has no second engine to draw it with.
 */
@Composable
fun ChartGallery(
    links: ChartLinkController,
    /** How many cells the mariner's own chart is built from. */
    cells: Int,
    onAdd: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        ChartTile(
            name = "Lookout chart",
            detail = if (cells > 0) "From your chart sets · $cells cells"
                     else "From your chart sets",
            active = links.activeChartLink == null,
            art = R.drawable.welcome_chart,
            onSelect = { links.selectChartLink(null) },
        )
        for (link in links.chartLinks) {
            ChartTile(
                name = link.name,
                detail = link.url,
                active = links.activeChartLink == link.url,
                art = ChartCatalog.art(link.url),
                onSelect = { links.selectChartLink(link.url) },
                onRefresh = { links.refreshChartLink(link.url) },
                onRemove = { links.removeChartLink(link.url) },
            )
        }
        AddChartTile(onAdd)
    }
}

private val TILE = 196.dp
private val ART = 112.dp
private val ADD = 150.dp

@Composable
private fun ChartTile(
    name: String,
    detail: String,
    active: Boolean,
    art: Int?,
    onSelect: () -> Unit,
    onRefresh: (() -> Unit)? = null,
    onRemove: (() -> Unit)? = null,
) {
    Surface(
        modifier = Modifier
            .width(TILE)
            .selectable(selected = active, role = Role.RadioButton, onClick = onSelect)
            .semantics { contentDescription = "chart-tile-$name" },
        shape = RoundedCornerShape(11.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(
            if (active) 2.dp else 1.dp,
            if (active) MaterialTheme.colorScheme.primary
            else MaterialTheme.colorScheme.outlineVariant,
        ),
    ) {
        Column {
            Box(
                Modifier
                    .width(TILE)
                    .height(ART)
                    .clip(RoundedCornerShape(topStart = 10.dp, topEnd = 10.dp)),
            ) {
                if (art != null) {
                    Image(
                        painterResource(art),
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop,
                    )
                } else {
                    // A style with no picture shows its kind. It says the tile
                    // is a chart from somewhere else without claiming to be a
                    // portrayal of it.
                    Box(
                        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Outlined.Public,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f),
                            modifier = Modifier.size(26.dp),
                        )
                    }
                }
                if (active) {
                    Text(
                        "ACTIVE",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                        modifier = Modifier
                            .padding(6.dp)
                            .background(
                                MaterialTheme.colorScheme.primary,
                                RoundedCornerShape(4.dp),
                            )
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
                if (onRemove != null) {
                    tileMenu(
                        onRefresh = onRefresh,
                        onRemove = onRemove,
                        modifier = Modifier.align(Alignment.TopEnd),
                        name = name,
                    )
                }
            }
            Column(Modifier.padding(horizontal = 11.dp).padding(top = 9.dp, bottom = 11.dp)) {
                Text(
                    name,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    detail,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** What can be done to a linked chart, where the tile is. */
@Composable
private fun tileMenu(
    onRefresh: (() -> Unit)?,
    onRemove: () -> Unit,
    modifier: Modifier,
    name: String,
) {
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        IconButton(onClick = { open = true }, modifier = Modifier.size(32.dp)) {
            Icon(
                Icons.Filled.MoreVert,
                contentDescription = "More for $name",
                tint = MaterialTheme.colorScheme.onSurface,
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (onRefresh != null) {
                DropdownMenuItem(
                    text = { Text("Read the style again") },
                    onClick = { open = false; onRefresh() },
                )
            }
            DropdownMenuItem(
                text = { Text("Remove") },
                onClick = { open = false; onRemove() },
            )
        }
    }
}

@Composable
private fun AddChartTile(onAdd: () -> Unit) {
    Surface(
        modifier = Modifier
            .width(ADD)
            .heightIn(min = ART + 60.dp)
            .clickable(onClick = onAdd)
            .semantics { contentDescription = "add-chart-tile" },
        shape = RoundedCornerShape(11.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(
            Modifier.fillMaxSize().padding(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(
                Icons.Filled.Add,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(24.dp),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Add a chart",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Medium,
            )
            Text(
                "Style link or TileJSON",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
