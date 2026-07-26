package org.beetlebug.lookout

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Brightness4
import androidx.compose.material.icons.filled.CropFree
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.clickable
import kotlinx.coroutines.delay

/**
 * The chart plus its chrome. The chart is a real SurfaceView underneath (the
 * Zig core presents to it from its own render thread); everything Compose draws
 * sits over it and only captures hits on its own footprint, so the rest of the
 * chart stays fully interactive — the same contract as HUDOverlay.swift.
 */
@Composable
fun ChartScreen(
    chartPath: String,
    controller: ChartController,
    onViewCreated: (LookoutView) -> Unit,
) {
    var showSettings by remember { mutableStateOf(false) }
    // The chart's size, tracked so the zoom buttons can zoom about its centre
    // (the camera takes an anchor point, in logical points).
    var centreX by remember { mutableFloatStateOf(0f) }
    var centreY by remember { mutableFloatStateOf(0f) }
    val density = LocalDensity.current.density

    // Apply-and-save on a trailing debounce, mirroring the Swift binding: a
    // slider drag emits an edit per frame, and each one can mark a rebuild.
    LaunchedEffect(controller.mariner.edits) {
        if (controller.mariner.edits == 0) return@LaunchedEffect // initial state
        delay(APPLY_DEBOUNCE_MS)
        controller.applyMariner()
    }

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged {
                centreX = it.width * 0.5f / density
                centreY = it.height * 0.5f / density
            },
    ) {
        AndroidView(
            factory = { ctx -> LookoutView(ctx, chartPath, controller).also(onViewCreated) },
            modifier = Modifier.fillMaxSize(),
        )

        // ---- top-right controls: what used to be gesture-only ---------------
        Column(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(12.dp),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            RoundButton(Icons.Default.Settings, "Chart settings") { showSettings = true }
            RoundButton(Icons.Default.Brightness4, "Day / dusk / night") { controller.cycleScheme() }
            RoundButton(Icons.Default.CropFree, "Fit chart") { controller.fitChart() }
            CompassBadge(
                rotationDeg = controller.readouts.rotationDeg,
                onReset = { controller.resetRotation() },
            )
        }

        // ---- bottom-right: zoom ---------------------------------------------
        Column(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 12.dp, bottom = 72.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            RoundButton(Icons.Default.Add, "Zoom in") { controller.zoomBy(1.0, centreX, centreY) }
            RoundButton(Icons.Default.Remove, "Zoom out") { controller.zoomBy(-1.0, centreX, centreY) }
        }

        // ---- identify, above the readouts bar -------------------------------
        if (controller.identify.isNotEmpty()) {
            IdentifyPanel(
                results = controller.identify,
                onDismiss = { controller.dismissIdentify() },
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = 12.dp, bottom = 72.dp),
            )
        }

        ReadoutsBar(
            readouts = controller.readouts,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }

    if (showSettings) {
        SettingsSheet(m = controller.mariner, onDismiss = { showSettings = false })
    }
}

@Composable
private fun RoundButton(icon: ImageVector, description: String, onClick: () -> Unit) {
    Surface(
        modifier = Modifier
            .size(44.dp)
            .clickable(onClick = onClick),
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.86f),
        tonalElevation = 2.dp,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                icon,
                contentDescription = description,
                modifier = Modifier.size(21.dp),
                tint = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

/** Long enough to swallow a slider drag, short enough to feel immediate. */
private const val APPLY_DEBOUNCE_MS = 80L
