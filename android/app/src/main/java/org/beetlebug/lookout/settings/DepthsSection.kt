package org.beetlebug.lookout.settings

import org.beetlebug.lookout.ui.Footer
import org.beetlebug.lookout.ui.LabeledRow
import org.beetlebug.lookout.ui.SectionHeader
import org.beetlebug.lookout.ui.SegmentedRow

// The Depths section: the unit, the water shading, and the four contours that
// decide what counts as safe water.
//
// THE ENGINE ALWAYS TAKES METRES. S-57 depths are metres and the unit only
// changes labels, so feet mode edits through a conversion here. Sending "ft"
// numbers straight through as metres was a real bug once.

import androidx.compose.ui.platform.testTag
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.foundation.layout.width
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val FEET_PER_METRE = 3.28084

@Composable
internal fun DepthsSection(m: MarinerState) {
    val feet = m.depthUnit == DepthUnit.FEET
    val unit = if (feet) "ft" else "m"

    SectionHeader("Depth unit", first = true)
    SegmentedRow(
        options = DepthUnit.entries.map { it.label },
        selectedIndex = m.depthUnit.ordinal,
        onSelect = { m.depthUnit = DepthUnit.entries[it] },
    )

    LabeledRow("Water shading")
    SegmentedRow(
        options = listOf("Two shades", "Four shades"),
        selectedIndex = if (m.flag(MI.FOUR_SHADE_WATER)) 1 else 0,
        onSelect = { m.setFlag(MI.FOUR_SHADE_WATER, it == 1) },
    )
    Footer(
        if (m.flag(MI.FOUR_SHADE_WATER))
            "Four shades: white (safe) water starts at the DEEP contour; the " +
                "safety contour separates the two middle blues."
        else
            "Two shades: water deeper than the safety contour is white (safe), " +
                "everything shallower is blue."
    )

    BandPreview(m, feet)
    Footer(
        "Shading follows the depth areas in the chart: the effective safety " +
            "contour is the next DEEPER contour available in the data, drawn bold."
    )

    SectionHeader("Contours ($unit)")
    if (m.flag(MI.FOUR_SHADE_WATER)) {
        DepthRow("Shallow contour", m.shallowContour, unit, feet) { m.shallowContour = it }
    }
    DepthRow("Safety contour", m.safetyContour, unit, feet) { m.safetyContour = it }
    if (m.flag(MI.FOUR_SHADE_WATER)) {
        DepthRow("Deep contour", m.deepContour, unit, feet) { m.deepContour = it }
    }
    DepthRow("Safety depth", m.safetyDepth, unit, feet) { m.safetyDepth = it }
    Footer("Safety depth bolds soundings at or shallower than it; it does not shade water.")
}

/**
 * Schematic of the S-52 depth bands for the CURRENT settings: which shades
 * exist, and which contour separates each pair. Colours approximate the day
 * palette — this is a legend, not the palette itself.
 */
@Composable
private fun BandPreview(m: MarinerState, feet: Boolean) {
    // Whole depths read as whole numbers ("10 m", not "10.0 m"); the odd
    // half-metre contour still gets its decimal.
    fun label(metres: Double): String = when {
        feet -> "${(metres * FEET_PER_METRE).roundToInt()} ft"
        metres == metres.roundToInt().toDouble() -> "${metres.roundToInt()} m"
        else -> String.format(Locale.US, "%.1f m", metres)
    }

    val drying = Color(0xFF8CCC99)
    val bands: List<Pair<Color, String>> = if (m.flag(MI.FOUR_SHADE_WATER)) listOf(
        drying to "drying",
        Color(0xFF73BFED) to "0–${label(min(m.shallowContour, m.safetyContour))}",
        Color(0xFF8CD1F7) to "–${label(m.safetyContour)}",
        Color(0xFFBFE6FC) to "–${label(max(m.deepContour, m.safetyContour))}",
        Color.White to "deeper",
    ) else listOf(
        drying to "drying",
        Color(0xFF73BFED) to "0–${label(m.safetyContour)}",
        Color.White to "deeper",
    )

    Row(
        Modifier
            .padding(horizontal = 20.dp, vertical = 6.dp)
            .fillMaxWidth()
            .height(36.dp)
            .clip(RoundedCornerShape(6.dp))
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(6.dp)),
    ) {
        for ((color, text) in bands) {
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .background(color),
                contentAlignment = Alignment.BottomCenter,
            ) {
                Text(
                    text = text,
                    fontSize = 9.sp,
                    maxLines = 1,
                    color = Color.Black.copy(alpha = 0.75f),
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(bottom = 2.dp),
                )
            }
        }
    }
}

/**
 * A contour depth. The ENGINE always takes metres (S-57 depths are metres; the
 * unit only changes labels), so feet mode edits through a conversion here, in
 * WHOLE feet — a depth read to fractions of a foot is noise, and sending "ft"
 * numbers straight through as metres was a real bug once.
 */
@Composable
private fun DepthRow(
    title: String,
    metres: Double,
    unit: String,
    feet: Boolean,
    onChange: (Double) -> Unit,
) {
    val shown = if (feet) (metres * FEET_PER_METRE).roundToInt().toDouble() else metres
    fun text(v: Double) = if (feet) "${v.roundToInt()}" else String.format(Locale.US, "%.1f", v)
    fun commit(v: Double) {
        val clamped = v.coerceIn(0.0, MAX_DEPTH)
        onChange(if (feet) clamped.roundToInt() / FEET_PER_METRE else clamped)
    }

    // The field is the way a contour is SET and the steppers are the way it is
    // nudged. Going from ten metres to thirty is one edit here and twenty taps
    // on the buttons, and a mariner changing a safety contour is usually
    // changing it by a lot: it follows the boat's draught, not the last value.
    //
    // The draft is re-seeded whenever the value moves under it, which is the
    // stepper, a unit switch, or a load from the engine. Nothing moves it while
    // the field has focus, because the commit is on Done and on losing focus
    // rather than per keystroke.
    var draft by remember(shown, feet) { mutableStateOf(text(shown)) }
    var focused by remember { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    fun commitDraft() {
        // Nonsense goes back to what is in force rather than to zero: a
        // half-typed contour must not shade the chart as if the water were
        // safe everywhere.
        val typed = draft.trim().replace(',', '.').toDoubleOrNull()
        if (typed == null) draft = text(shown) else commit(typed)
    }

    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.weight(1f))
        OutlinedTextField(
            value = draft,
            onValueChange = { typed ->
                // Digits and one separator. A minus sign is not a depth, and
                // letters would only be refused on commit.
                val kept = typed.filter { it.isDigit() || it == '.' || it == ',' }
                if (kept.count { it == '.' || it == ',' } <= 1) draft = kept
            },
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyMedium.copy(textAlign = TextAlign.End),
            keyboardOptions = KeyboardOptions(
                keyboardType = if (feet) KeyboardType.Number else KeyboardType.Decimal,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = {
                commitDraft()
                focus.clearFocus()
            }),
            modifier = Modifier
                .width(DEPTH_FIELD_WIDTH)
                .testTag("depth-$title")
                .onFocusChanged { state ->
                    // Leaving the field is a commit: a mariner who types a
                    // depth and taps the chart meant the depth.
                    if (focused && !state.isFocused) commitDraft()
                    focused = state.isFocused
                },
        )
        Text(
            " $unit",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        IconButton(onClick = { commit(shown - 1) }, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.Remove, contentDescription = "Decrease $title")
        }
        IconButton(onClick = { commit(shown + 1) }, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.Add, contentDescription = "Increase $title")
        }
    }
}

/** Wide enough for "660.0" and no wider: the row still has to hold its label
 *  and both steppers on a phone. */
private val DEPTH_FIELD_WIDTH = 96.dp

/** No charted contour is deeper than this, in either unit. */
private const val MAX_DEPTH = 660.0

// ---- Text & Symbols ---------------------------------------------------------
