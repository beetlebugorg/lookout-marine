package org.beetlebug.lookout

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
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
import androidx.compose.runtime.key
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
    charts: ChartsModel,
    controller: ChartController,
    onRequestFileAccess: () -> Unit,
    onViewCreated: (LookoutView) -> Unit,
) {
    var showSettings by remember { mutableStateOf(false) }
    // The chart's size, tracked so the zoom buttons can zoom about its centre
    // (the camera takes an anchor point, in logical points).
    var centreX by remember { mutableFloatStateOf(0f) }
    var centreY by remember { mutableFloatStateOf(0f) }
    // The chart view's size in dp, which the pick report's placement needs.
    var viewW by remember { mutableStateOf(0.dp) }
    var viewH by remember { mutableStateOf(0.dp) }
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
                viewW = (it.width / density).dp
                viewH = (it.height / density).dp
            },
    ) {
        // Keyed on the library generation: picking a different chart folder
        // builds a NEW SurfaceView, so the old engine handle closes with its
        // surface (surfaceDestroyed) and the new one opens on the new cell set.
        // Re-tessellation is unavoidable either way — the scene is per-library.
        key(charts.generation) {
            AndroidView(
                factory = { ctx ->
                    LookoutView(ctx, charts.chartPaths, controller).also(onViewCreated)
                },
                modifier = Modifier.fillMaxSize(),
            )
        }

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

        // ---- the pick, marked on the chart and reported over it --------------
        val pick = controller.identifyPoint
        if (pick != null && controller.identify.isNotEmpty()) {
            // The mark on the object, drawn under the card.
            PickMarker(
                Modifier
                    .align(Alignment.TopStart)
                    .offset(
                        x = pick.x.dp - PICK_MARKER_SIZE / 2,
                        y = pick.y.dp - PICK_MARKER_SIZE / 2,
                    ),
            )

            val width = pickReportWidth(controller.identify.size, viewW)
            val place = calloutPlacement(
                pointX = pick.x.dp,
                pointY = pick.y.dp,
                width = width,
                viewWidth = viewW,
                viewHeight = viewH,
                hudBand = HUD_BAND,
            )
            // The card holds one edge against the mark and the layout places
            // the opposite edge, so the card's height is never measured here.
            val alignment = if (place.edge == CalloutEdge.ABOVE) {
                Alignment.BottomStart
            } else {
                Alignment.TopStart
            }
            PickReportCard(
                results = controller.identify,
                selected = controller.identifyIndex,
                onSelect = { controller.identifyIndex = it },
                onDismiss = { controller.dismissIdentify() },
                width = width,
                maxHeight = place.room,
                modifier = Modifier
                    .align(alignment)
                    .padding(
                        start = place.x,
                        top = if (place.edge == CalloutEdge.BELOW) place.y else 0.dp,
                        bottom = if (place.edge == CalloutEdge.ABOVE) viewH - place.y else 0.dp,
                    ),
            )
        }

        ReadoutsBar(
            readouts = controller.readouts,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }

    if (showSettings) {
        SettingsSheet(
            m = controller.mariner,
            charts = charts,
            onRequestAccess = onRequestFileAccess,
            onDismiss = { showSettings = false },
        )
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

/** The bottom band the readouts bar owns. The report stops above it. */
private val HUD_BAND = 72.dp
