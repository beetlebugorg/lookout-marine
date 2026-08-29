package org.beetlebug.lookout.pick

import org.beetlebug.lookout.chart.ChartController
import org.beetlebug.lookout.chart.OverlayInfo
import org.beetlebug.lookout.chart.PickFeature

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The cursor pick report.
 *
 * One object at a time, decoded for the mariner: the operative fact as the
 * title, the attributes in chart language, and the raw S-57 rows one fold
 * away. The copy control puts the raw text on the clipboard, which is how a
 * chart problem gets reported. The Android twin of PickReport.swift.
 */
@Composable
fun PickReportCard(
    results: List<PickFeature>,
    selected: Int,
    onSelect: (Int) -> Unit,
    onDismiss: () -> Unit,
    width: Dp,
    maxHeight: Dp,
    modifier: Modifier = Modifier,
    onAuxFile: (cell: String, name: String) -> Unit = { _, _ -> },
) {
    val feature = results.getOrNull(selected) ?: return
    val decoded = remember(feature) { PickDecoded(feature) }
    val context = LocalContext.current
    // The fold is per pick, not per object: an opened fold that survived the
    // selection would open on an object the mariner never asked to unfold.
    var foldOpen by remember(results) { mutableStateOf(false) }

    Surface(
        // The card keeps its taps. Without this a tap on the report reaches
        // the chart underneath, which picks again under the report.
        modifier = modifier
            .width(width)
            .pointerInput(Unit) { detectTapGestures { } },
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 3.dp,
        shadowElevation = 6.dp,
    ) {
        Row(Modifier.heightIn(max = maxHeight)) {
            // The pick's objects stay in sight beside the report. There is no
            // pager to walk blind and nothing to go back from.
            if (results.size > 1) {
                ObjectList(
                    results = results,
                    selected = selected,
                    onSelect = onSelect,
                    modifier = Modifier.width(LIST_WIDTH),
                )
                VerticalRule()
            }
            Column(Modifier.weight(1f)) {
                Header(decoded, onCopy = { copy(context, feature) }, onDismiss = onDismiss)
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Column(
                    Modifier
                        .weight(1f, fill = false)
                        .verticalScroll(rememberScrollState()),
                ) {
                    Body(decoded, onFile = { name -> onAuxFile(feature.chart, name) })
                    if (foldOpen) RawRows(decoded)
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Footnote(decoded.footnote)
                FoldButton(decoded.rawRows.size, foldOpen) { foldOpen = !foldOpen }
            }
        }
    }
}

/** The operative fact large, what the object is under it, and the controls. */
@Composable
private fun Header(decoded: PickDecoded, onCopy: () -> Unit, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier.padding(start = 16.dp, top = 12.dp, end = 4.dp, bottom = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                text = decoded.title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // The subtitle line is kept even when empty, so the header is the
            // same height for every object and the rows below cannot shift as
            // the selection moves.
            Text(
                text = decoded.subtitle ?: " ",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onCopy, modifier = Modifier.size(36.dp)) {
            Icon(
                Icons.Default.ContentCopy,
                contentDescription = "Copy this report",
                modifier = Modifier.size(17.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        IconButton(onClick = onDismiss, modifier = Modifier.size(36.dp)) {
            Icon(
                Icons.Default.Close,
                contentDescription = "Close the pick report",
                modifier = Modifier.size(18.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** The notes first, then the decoded rows. */
@Composable
private fun Body(decoded: PickDecoded, onFile: (String) -> Unit) {
    Column(Modifier.padding(vertical = 6.dp)) {
        for (note in decoded.notes) NoteCallout(note)
        // The engine's verdict. A body with nothing to read says why, because
        // a blank body reads as a defect.
        decoded.empty?.let {
            Text(
                text = if (it == PickDecoded.EmptyKind.NO_ATTRIBUTES) {
                    "The cell carries no attributes for this object."
                } else {
                    "The cell carries only source data for this object."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
            )
        }
        for (row in decoded.reportRows) DecodedRow(row, onFile)
    }
}

/** The label on the left, the value beside it. The engine decoded both. */
@Composable
private fun DecodedRow(row: PickDecoded.ReportRow, onFile: (String) -> Unit = {}) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp + (row.depth * 12).dp, end = 16.dp)
            .padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = row.label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            // The value owns the width, because a note or a name is the
            // reading matter. The label still gets enough for the common ones
            // ("Depth range minimum") to sit on one line.
            modifier = Modifier.width((132 - row.depth * 12).dp),
        )
        // A row naming a file the chart carries opens it: the accent and the
        // tap are the affordance, because a chart note or a bridge picture is
        // the whole reason the row exists.
        val opens = row.file || row.picture
        Text(
            text = row.value,
            style = MaterialTheme.typography.bodyMedium,
            color = if (opens) MaterialTheme.colorScheme.primary else Color.Unspecified,
            modifier = if (opens) {
                Modifier
                    .weight(1f)
                    .clickable { onFile(row.value) }
            } else {
                Modifier.weight(1f)
            },
        )
    }
}

/** A note the mariner reads before the attributes: INFORM, promoted. */
@Composable
private fun NoteCallout(text: String) {
    val amber = Color(0xFFFFA726)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 5.dp)
            .background(amber.copy(alpha = 0.12f), RoundedCornerShape(8.dp))
            .border(1.dp, amber.copy(alpha = 0.40f), RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            Icons.Default.Warning,
            contentDescription = null,
            modifier = Modifier.size(15.dp),
            tint = amber,
        )
        Text(text = text, style = MaterialTheme.typography.bodyMedium)
    }
}

/** The pick's objects as a column, the object on show held selected. */
@Composable
private fun ObjectList(
    results: List<PickFeature>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .verticalScroll(rememberScrollState()),
    ) {
        Text(
            text = "${results.size} OBJECTS",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 14.dp, top = 14.dp, end = 10.dp, bottom = 6.dp),
        )
        results.forEachIndexed { i, f ->
            val d = remember(f) { PickDecoded(f) }
            val isSelected = i == selected
            Column(
                Modifier
                    .fillMaxWidth()
                    .background(
                        if (isSelected) {
                            MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
                        } else {
                            Color.Transparent
                        },
                    )
                    .clickable { onSelect(i) }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            ) {
                Text(
                    text = d.title,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = if (isSelected) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                d.subtitle?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        Spacer(Modifier.size(8.dp))
    }
}

/** The provenance as one muted line, not a table. */
@Composable
private fun Footnote(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

/** The fold's control. It keeps its place, under the rows. */
@Composable
private fun FoldButton(count: Int, open: Boolean, onToggle: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(
            if (open) Icons.Default.KeyboardArrowDown else Icons.Default.KeyboardArrowRight,
            contentDescription = if (open) {
                "Hide the S-57 source attributes"
            } else {
                "Show the S-57 source attributes"
            },
            modifier = Modifier.size(16.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = "S-57 source attributes ($count)",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** The payload as the cell states it. Nothing the decode did is applied here. */
@Composable
private fun RawRows(decoded: PickDecoded) {
    Column(Modifier.padding(bottom = 6.dp)) {
        for (row in decoded.rawRows) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 16.dp + (row.depth * 12).dp, end = 16.dp)
                    .padding(vertical = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = if (row.value.isEmpty()) row.name else "${row.name}:",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width((88 - row.depth * 12).dp),
                )
                Text(
                    text = row.value,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun VerticalRule() {
    Box(
        Modifier
            .width(1.dp)
            .fillMaxHeight()
            .background(MaterialTheme.colorScheme.outlineVariant),
    )
}

private fun copy(context: Context, feature: PickFeature) {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
    cm.setPrimaryClip(ClipData.newPlainText("Pick report", S57.plainText(feature)))
}

/** The object column's width. The detail column takes the rest. */
private val LIST_WIDTH = 200.dp

/** The detail column's width. A report needs the room to read a note. */
private val DETAIL_WIDTH = 430.dp

/** The report's width for a pick: the detail column, with the object list
 *  beside it when the pick found several objects. */
fun pickReportWidth(count: Int, viewWidth: Dp): Dp {
    val want = if (count > 1) LIST_WIDTH + DETAIL_WIDTH else DETAIL_WIDTH
    val room = viewWidth - PICK_MARGIN * 2
    return minOf(want, maxOf(280.dp, room))
}

/** Which edge of the report is held against the pick mark. */
enum class CalloutEdge { ABOVE, BELOW }

/**
 * Where the report stands, and the height it may use.
 *
 * `y` is the edge that `edge` names. The layout places the opposite edge, so
 * nothing measures the card to position it. `room` is a hard limit, so a long
 * report scrolls instead of growing over the mark.
 */
data class CalloutPlace(val x: Dp, val y: Dp, val edge: CalloutEdge, val room: Dp)

/**
 * Put the report over the pick. The card is centred on the mark and its floor
 * stops clear of it.
 *
 * The card gets the room between the mark and the margin. The card goes under
 * the mark only when the room above is too small to read a report in. The
 * Android twin of OverlayLayer.calloutLayout.
 */
fun calloutPlacement(
    pointX: Dp,
    pointY: Dp,
    width: Dp,
    viewWidth: Dp,
    viewHeight: Dp,
    hudBand: Dp,
    topInset: Dp = 0.dp,
): CalloutPlace {
    val clear = PICK_MARKER_SIZE / 2 + 6.dp
    val minX = PICK_MARGIN
    val maxX = maxOf(minX, viewWidth - PICK_MARGIN - width)
    // The free area's floor. The card stops here; the HUD owns the rest.
    val floor = maxOf(PICK_MARGIN, viewHeight - hudBand)
    val x = minOf(maxOf(pointX - width / 2, minX), maxX)

    // The ceiling is the safe area, not the view: a card that runs under the
    // status bar is read through the clock.
    val ceiling = topInset + PICK_MARGIN
    val over = (pointY - clear) - ceiling
    val under = floor - (pointY + clear)
    // Use the space above unless it is too small and the space below is larger.
    return if (over >= 200.dp || over >= under) {
        CalloutPlace(x, pointY - clear, CalloutEdge.ABOVE, maxOf(0.dp, over))
    } else {
        CalloutPlace(x, pointY + clear, CalloutEdge.BELOW, maxOf(0.dp, under))
    }
}

/**
 * The bubble pinned to a tapped overlay object — an AIS target's name, MMSI,
 * speed and closest approach.
 *
 * It is deliberately not the pick report: a plugin's payload is a title and a
 * list of key/value rows it chose itself, with no S-57 object behind it to
 * decode, no source cell to name and nothing to copy as attributes. So this is
 * the small end of the same callout family — the placement helper, the corner
 * radius and the surface are shared, the content is not.
 *
 * The caller positions it against the target and re-positions it every frame;
 * see ChartController.followPin.
 */
@Composable
fun OverlayBubble(
    info: OverlayInfo,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        // The bubble keeps its taps. Without this a tap on it reaches the chart
        // underneath, which would treat it as a tap on open water and close the
        // very bubble being read.
        modifier = modifier
            .widthIn(min = 150.dp, max = OVERLAY_BUBBLE_MAX_WIDTH)
            .pointerInput(Unit) { detectTapGestures { } },
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 3.dp,
        shadowElevation = 6.dp,
    ) {
        Column(Modifier.padding(start = 12.dp, top = 8.dp, end = 4.dp, bottom = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    info.title,
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                // A tap elsewhere on the chart closes the bubble and so does a
                // second tap on the target, but neither is discoverable and the
                // target may be under the finger with no clear water beside it.
                IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "Close",
                        modifier = Modifier.size(18.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            for ((k, v) in info.rows) {
                Row(Modifier.padding(top = 3.dp, end = 8.dp)) {
                    Text(
                        k,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.width(OVERLAY_KEY_WIDTH),
                    )
                    Text(
                        v,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }
    }
}

/** Wide enough for "Closest approach" and a value, narrow enough to sit on a target. */
val OVERLAY_BUBBLE_MAX_WIDTH = 260.dp
private val OVERLAY_KEY_WIDTH = 116.dp

/** The mark on the object of the pick. */
@Composable
fun PickMarker(modifier: Modifier = Modifier) {
    val magenta = Color(0xFFE0218A)
    Canvas(modifier.size(PICK_MARKER_SIZE)) {
        val r = size.minDimension / 2 - 2.dp.toPx()
        drawCircle(Color.White.copy(alpha = 0.85f), r, style = Stroke(4.dp.toPx()))
        drawCircle(magenta, r, style = Stroke(2.dp.toPx()))
    }
}

/** The mark's diameter. */
val PICK_MARKER_SIZE = 34.dp

/** The margin the report keeps from the edges of the chart view. */
val PICK_MARGIN = 12.dp
