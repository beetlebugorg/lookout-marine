package org.beetlebug.lookout.settings

import org.beetlebug.lookout.ui.ChoiceRow
import org.beetlebug.lookout.ui.Footer
import org.beetlebug.lookout.ui.SectionHeader

// The Display section: the colour scheme, the display category and the
// soundings, with the scheme drawn as pieces of chart rather than colour chips.

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable
internal fun DisplaySection(m: MarinerState) {
    SectionHeader("Colour scheme", first = true)
    SchemeSwatches(m)
    Footer("The palettes switch instantly. Night keeps your eyes dark-adapted.")

    SectionHeader("Display category")
    for (c in DisplayCategory.entries) {
        ChoiceRow(c.label, c.desc, m.displayCategory == c) { m.displayCategory = c }
    }
    Footer("Each category contains the one before it.")

    SectionHeader("Soundings")
    for (s in SoundingsMode.entries) {
        ChoiceRow(s.label, s.desc, m.soundings == s) { m.soundings = s }
    }
}

/**
 * The three schemes as pieces of chart rather than colour chips: four depth
 * shades out to deep water with land behind a curved coastline, which is what
 * the mariner will actually be looking at.
 *
 * The colours are the presentation library's own sRGB values (S-101 profile,
 * tokens DEPDW/DEPMD/DEPMS/DEPVS/LANDA/CSTLN), copied so a swatch can be drawn
 * without opening a chart, and shared verbatim with the other shells. They are
 * a legend of the palette, not the palette: the engine draws from the chart's
 * own tables.
 */
@Composable
private fun SchemeSwatches(m: MarinerState) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        for (s in Scheme.entries) {
            val chosen = s == m.scheme
            Column(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { m.scheme = s },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val p = schemePalette(s)
                Canvas(
                    Modifier
                        .fillMaxWidth()
                        .height(78.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .border(
                            width = if (chosen) 3.dp else 1.dp,
                            color = if (chosen) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.outlineVariant,
                            shape = RoundedCornerShape(8.dp),
                        ),
                ) {
                    val w = size.width
                    val h = size.height
                    // Deepest at the top, shoaling down to the shore.
                    drawRect(p[0], size = androidx.compose.ui.geometry.Size(w, h * 0.36f))
                    drawRect(
                        p[1],
                        topLeft = Offset(0f, h * 0.36f),
                        size = androidx.compose.ui.geometry.Size(w, h * 0.18f),
                    )
                    drawRect(
                        p[2],
                        topLeft = Offset(0f, h * 0.54f),
                        size = androidx.compose.ui.geometry.Size(w, h * 0.16f),
                    )
                    drawRect(
                        p[3],
                        topLeft = Offset(0f, h * 0.70f),
                        size = androidx.compose.ui.geometry.Size(w, h * 0.30f),
                    )
                    // The shore: a bay open to the top-left, land in the corner.
                    val shore = Path().apply {
                        moveTo(0f, h)
                        lineTo(0f, h * 0.80f)
                        cubicTo(w * 0.35f, h * 0.74f, w * 0.60f, h * 0.44f, w, h * 0.52f)
                        lineTo(w, h)
                        close()
                    }
                    drawPath(shore, p[4])
                    drawPath(shore, p[5], style = Stroke(width = 1.5.dp.toPx()))
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    s.label,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = if (chosen) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (chosen) MaterialTheme.colorScheme.onSurface
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(4.dp))
            }
        }
    }
}

/** deep, medium, shallow, very shallow, land, coastline. */
private fun schemePalette(s: Scheme): List<Color> = when (s) {
    Scheme.DAY -> listOf(
        Color(0xFFC9EDFF), Color(0xFFA7D9FB), Color(0xFF82CAFF),
        Color(0xFF61B7FF), Color(0xFFBFBE8F), Color(0xFF4C5B63),
    )
    Scheme.DUSK -> listOf(
        Color(0xFF000000), Color(0xFF0F1B21), Color(0xFF1D3246),
        Color(0xFF1E4165), Color(0xFF40402E), Color(0xFF6B7F89),
    )
    Scheme.NIGHT -> listOf(
        Color(0xFF000000), Color(0xFF03070A), Color(0xFF050E16),
        Color(0xFF071727), Color(0xFF17160E), Color(0xFF252D31),
    )
}
