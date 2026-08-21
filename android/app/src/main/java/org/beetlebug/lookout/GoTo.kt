package org.beetlebug.lookout

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import java.util.Locale
import kotlin.math.ln

/** Go to a coordinate. The search bubble opens it. */
@Composable
fun GoToCoordinateDialog(onDismiss: () -> Unit, onGo: (lat: Double, lon: Double) -> Unit) {
    var text by remember { mutableStateOf("") }
    val coord = CoordinateParser.parse(text)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Go to coordinate") },
        text = {
            Column {
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    singleLine = true,
                    isError = text.isNotBlank() && coord == null,
                    label = { Text("Latitude and longitude") },
                    placeholder = { Text("38°58'34\"N 076°28'36\"W") },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = {
                        coord?.let { onGo(it.first, it.second); onDismiss() }
                    }),
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    text = "Degrees with a hemisphere, or a decimal pair.",
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = coord != null,
                onClick = { coord?.let { onGo(it.first, it.second) }; onDismiss() },
            ) { Text("Go") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Zoom to a scale. Tapping the 1:N readout opens it. */
@Composable
fun ScaleEntryDialog(
    current: Double,
    onDismiss: () -> Unit,
    onZoomToScale: (Double) -> Unit,
) {
    var text by remember {
        mutableStateOf(if (current > 0) Math.round(current).toString() else "")
    }
    val denominator = ScaleParser.parse(text)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Zoom to a scale") },
        text = {
            Column {
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    singleLine = true,
                    isError = text.isNotBlank() && denominator == null,
                    label = { Text("Scale") },
                    placeholder = { Text("25,000") },
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Text,
                        imeAction = ImeAction.Go,
                    ),
                    keyboardActions = KeyboardActions(onGo = {
                        denominator?.let { onZoomToScale(it); onDismiss() }
                    }),
                    modifier = Modifier.fillMaxWidth(),
                )
                // The bands, so a mariner picks a purpose instead of a number.
                Row(
                    Modifier
                        .padding(top = 10.dp)
                        .horizontalScroll(rememberScrollState()),
                ) {
                    for ((label, n) in BANDS) {
                        AssistChip(
                            onClick = { text = n.toString() },
                            label = { Text(label) },
                            modifier = Modifier.padding(end = 6.dp),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = denominator != null,
                onClick = { denominator?.let { onZoomToScale(it) }; onDismiss() },
            ) { Text("Zoom") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// The reference shell's presets, verbatim: one representative scale per band.
private val BANDS = listOf(
    "Berthing" to 2_000,
    "Harbor" to 12_000,
    "Approach" to 50_000,
    "Coastal" to 150_000,
    "General" to 700_000,
)

/**
 * A scale as a zoom delta. At one latitude the denominator is C·cos(lat)/2^zoom,
 * so the engine's own zoom does the work and keeps its limits and its easing.
 */
fun zoomDeltaForScale(currentDenominator: Double, wanted: Double): Double =
    ln(currentDenominator / wanted) / ln(2.0)

/** Accepts "25000", "25,000", "1:25000", "25k" and "1:2.5M". */
object ScaleParser {
    fun parse(raw: String): Double? {
        var s = raw.lowercase(Locale.US).trim()
        // In "1:25k" the text before the colon is the 1.
        s.lastIndexOf(':').let { if (it >= 0) s = s.substring(it + 1) }
        s = s.filter { !it.isWhitespace() && it != ',' }
        var multiplier = 1.0
        when {
            s.endsWith("k") -> { multiplier = 1_000.0; s = s.dropLast(1) }
            s.endsWith("m") -> { multiplier = 1_000_000.0; s = s.dropLast(1) }
        }
        val n = s.toDoubleOrNull() ?: return null
        val d = n * multiplier
        // The reference's sanity range: no chart is 1:5, none is 1:5 billion.
        return if (d.isFinite() && d >= 100 && d <= 100_000_000) d else null
    }
}

/**
 * A coordinate, as degrees with a hemisphere or as a decimal pair. It accepts
 * what CoordinateParser (macOS and iOS) accepts, so a position copied from one
 * shell pastes into another.
 */
object CoordinateParser {
    private val HEMI = Regex(
        """(\d+(?:\.\d+)?)\s*[°\s]\s*(?:(\d+(?:\.\d+)?)\s*['′\s]\s*)?""" +
            """(?:(\d+(?:\.\d+)?)\s*["″\s]\s*)?([NSEWnsew])""",
    )

    fun parse(raw: String): Pair<Double, Double>? {
        val s = raw.trim()
        if (s.isEmpty()) return null
        if (s.any { it.uppercaseChar() in "NSEW" }) return parseHemispheres(s)
        val parts = s.split(',', ' ').filter { it.isNotBlank() }
        if (parts.size < 2) return null
        val lat = parts[0].toDoubleOrNull() ?: return null
        val lon = parts[1].toDoubleOrNull() ?: return null
        return if (lat in -90.0..90.0 && lon in -180.0..180.0) lat to lon else null
    }

    private fun parseHemispheres(s: String): Pair<Double, Double>? {
        var lat: Double? = null
        var lon: Double? = null
        for (m in HEMI.findAll(s)) {
            val deg = m.groupValues[1].toDoubleOrNull() ?: continue
            val min = m.groupValues[2].toDoubleOrNull() ?: 0.0
            val sec = m.groupValues[3].toDoubleOrNull() ?: 0.0
            var value = deg + min / 60 + sec / 3600
            val hemi = m.groupValues[4].uppercase(Locale.US)
            if (hemi == "S" || hemi == "W") value = -value
            if (hemi == "N" || hemi == "S") lat = value else lon = value
        }
        val la = lat ?: return null
        val lo = lon ?: return null
        return if (la in -90.0..90.0 && lo in -180.0..180.0) la to lo else null
    }
}
