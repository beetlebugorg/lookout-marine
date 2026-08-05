package org.beetlebug.lookout

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Brightness4
import androidx.compose.material.icons.filled.CropFree
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Search
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
    var showSearch by remember { mutableStateOf(false) }
    var showScaleEntry by remember { mutableStateOf(false) }
    // The chart's size, tracked so the zoom buttons can zoom about its centre
    // (the camera takes an anchor point, in logical points).
    var centreX by remember { mutableFloatStateOf(0f) }
    var centreY by remember { mutableFloatStateOf(0f) }
    // The chart view's size in dp, which the pick report's placement needs.
    var viewW by remember { mutableStateOf(0.dp) }
    var viewH by remember { mutableStateOf(0.dp) }
    val density = LocalDensity.current.density
    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

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

        // ---- top left: search ------------------------------------------------
        ChromeBubble(
            icon = Icons.Default.Search,
            description = "Go to coordinate",
            modifier = Modifier
                .align(Alignment.TopStart)
                .statusBarsPadding()
                .padding(Chrome.margin),
        ) { showSearch = true }

        // ---- top right: north ------------------------------------------------
        NorthBubble(
            rotationDeg = controller.readouts.rotationDeg,
            onReset = { controller.resetRotation() },
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(Chrome.margin),
        )

        // ---- bottom right: zoom above settings --------------------------------
        Column(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                // The same inset the capsule takes. Without it the capsule
                // rises by the navigation bar's height and this column does
                // not, so HUD_BAND stops being the gap between them and the
                // two meet.
                .navigationBarsPadding()
                .padding(end = Chrome.margin, bottom = HUD_BAND),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(Chrome.gap),
        ) {
            ChromeBubble(Icons.Default.CropFree, "Fit chart") { controller.fitChart() }
            ChromeBubble(Icons.Default.Add, "Zoom in") { controller.zoomBy(1.0, centreX, centreY) }
            ChromeBubble(Icons.Default.Remove, "Zoom out") { controller.zoomBy(-1.0, centreX, centreY) }
            ChromeBubble(Icons.Default.Settings, "Mariner settings") { showSettings = true }
        }

        // ---- bottom left: the scale bar ---------------------------------------
        ScaleBar(
            scaleDenominator = controller.readouts.scaleDenominator,
            modifier = Modifier
                .align(Alignment.BottomStart)
                .navigationBarsPadding()
                .padding(start = Chrome.margin, bottom = HUD_BAND),
        )

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
                topInset = topInset,
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

        // The loader while the library opens, then the pill for a rebuild.
        if (!controller.rendering) {
            StartupLoader(
                cells = charts.chartPaths.size,
                modifier = Modifier.align(Alignment.Center),
            )
        } else if (controller.readouts.building) {
            BuildingPill(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .padding(Chrome.margin),
            )
        }

        ReadoutsCapsule(
            readouts = controller.readouts,
            compact = viewW < Chrome.compactWidth,
            onScaleTap = { showScaleEntry = true },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = Chrome.margin),
            raster = controller.raster,
            onRasterSelect = { controller.selectRasterSet(it) },
            onToggleChart = { controller.toggleChart() },
            // The Charts tab is where charts are added; the pill's item goes
            // there rather than growing a second file browser.
            onAddRasterCharts = { showSettings = true },
        )
    }

    if (showSearch) {
        GoToCoordinateDialog(
            onDismiss = { showSearch = false },
            onGo = { lat, lon -> controller.goTo(lat, lon) },
        )
    }

    if (showScaleEntry) {
        ScaleEntryDialog(
            current = controller.readouts.scaleDenominator,
            onDismiss = { showScaleEntry = false },
            onZoomToScale = { wanted ->
                controller.zoomBy(
                    zoomDeltaForScale(controller.readouts.scaleDenominator, wanted),
                    centreX,
                    centreY,
                )
            },
        )
    }

    if (showSettings) {
        SettingsSheet(
            m = controller.mariner,
            charts = charts,
            controller = controller,
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

/** The bottom band the readouts capsule owns. The report stops above it. */
private val HUD_BAND = Chrome.capsule + Chrome.margin * 2
