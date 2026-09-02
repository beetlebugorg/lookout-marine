package org.beetlebug.lookout.chart

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
import org.beetlebug.lookout.Lookout

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
 * A scale as a zoom delta. The engine's own zoom does the work, so it keeps its
 * limits and its easing.
 */
fun zoomDeltaForScale(currentDenominator: Double, wanted: Double): Double =
    Lookout.zoomDeltaForScale(currentDenominator, wanted)

/** Accepts "25000", "25,000", "1:25000", "25k" and "1:2.5M". */
object ScaleParser {
    fun parse(raw: String): Double? = Lookout.parseScale(raw).takeIf { it > 0 }
}

/**
 * A coordinate, as degrees with a hemisphere or as a decimal pair. The engine
 * parses it, so a position copied from any shell pastes into this one.
 */
object CoordinateParser {
    fun parse(raw: String): Pair<Double, Double>? =
        Lookout.parsePosition(raw)?.let { it[0] to it[1] }
}
