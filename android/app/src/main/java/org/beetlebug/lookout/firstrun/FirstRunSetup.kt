package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.chart.ChartController
import org.beetlebug.lookout.charts.ChartsModel
import org.beetlebug.lookout.charts.NoaaController

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import org.beetlebug.lookout.charts.ChartSets
import org.beetlebug.lookout.charts.costLine

/**
 * Setup, bound to the app it is setting up.
 *
 * FirstRunFlow draws the frame and knows nothing about charts. This is the
 * half that does: which step is ready to move on from, what its action does,
 * and the line beside it.
 */
@Composable
fun FirstRunSetup(
    flow: FirstRunModel,
    charts: ChartsModel,
    controller: ChartController,
    /** Take the mariner to their own files, which is where the Files source
     *  ends: the Charts pane browses them. */
    onOpenCharts: () -> Unit,
) {
    val noaa = controller.noaaController
    val links = controller.chartLinkController

    // The catalog, once the coverage step is the one on screen. It is a
    // network read, so nothing asks for it until something needs it.
    LaunchedEffect(flow.step) {
        if (flow.step == FirstRunModel.Step.COVERAGE && !noaa.haveCatalog) noaa.refresh()
    }

    // The cells this device holds, so a pick prices what is missing from the
    // water rather than all of it.
    LaunchedEffect(flow.step, charts.sets) {
        if (flow.step == FirstRunModel.Step.COVERAGE) noaa.noteInstalled(installedCells(charts))
    }

    FirstRunFlow(
        flow = flow,
        canContinue = canContinue(flow, noaa, charts, links.activeChartLink),
        chartName = links.chartLinks.firstOrNull { it.url == links.activeChartLink }?.name,
        footnote = footnote(flow, noaa),
        onPrimary = {
            // The order is kept from the moment it is made: the service's own
            // counters are for the transfer, and the page outlives it.
            val ordered = if (flow.step == FirstRunModel.Step.COVERAGE) {
                FirstRunModel.Order(
                    regions = noaa.regions.filter { noaa.picked.contains(it.id) }
                        .joinToString(", ") { it.name },
                    charts = if (noaa.cells > 0) noaa.cells else noaa.held,
                    bytes = if (noaa.cells > 0) noaa.bytes else noaa.heldBytes,
                )
            } else null
            when (flow.advance()) {
                FirstRunModel.Source.FILES -> onOpenCharts()
                FirstRunModel.Source.NOAA -> {
                    flow.order = ordered
                    charts.noaaDir.mkdirs()
                    noaa.download(charts.noaaDir.absolutePath, noaa.allInstalled)
                }
                FirstRunModel.Source.ONLINE -> Unit
                null -> Unit
            }
        },
        onLater = { flow.finish() },
    ) {
        when (flow.step) {
            FirstRunModel.Step.WELCOME -> WelcomeStep()
            FirstRunModel.Step.SOURCE -> SourceStep(flow)
            FirstRunModel.Step.COVERAGE -> CoverageStep(noaa)
            FirstRunModel.Step.IMPORTING -> ImportingStep(
                flow = flow,
                noaa = noaa,
                work = charts.importer.state,
                onStop = {
                    noaa.cancel()
                    charts.importer.cancel()
                },
            )
            FirstRunModel.Step.ONLINE_CHART -> OnlineChartStep(links)
            FirstRunModel.Step.DEPTHS -> DepthStep(controller.mariner)
        }
    }
}

/** Whether the step on screen has been answered. */
private fun canContinue(
    flow: FirstRunModel,
    noaa: NoaaController,
    charts: ChartsModel,
    activeLink: String?,
): Boolean = when (flow.step) {
    FirstRunModel.Step.WELCOME, FirstRunModel.Step.SOURCE -> true
    FirstRunModel.Step.COVERAGE -> noaa.haveCatalog && noaa.picked.isNotEmpty()
    FirstRunModel.Step.ONLINE_CHART -> true
    // The bake opens the library when it finishes, so there is nothing to
    // continue to until a chart is drawing.
    FirstRunModel.Step.IMPORTING -> flow.sawBake && charts.importer.state?.running == false
    FirstRunModel.Step.DEPTHS -> true
}

/** The line beside the action: what the pick costs, or what to do next. */
private fun footnote(flow: FirstRunModel, noaa: NoaaController): String? = when (flow.step) {
    FirstRunModel.Step.COVERAGE -> {
        if (!noaa.haveCatalog) null
        else if (noaa.cells == 0 && noaa.held == 0) "Pick at least one region."
        else costLine(noaa)
    }
    FirstRunModel.Step.DEPTHS -> "Change any of this later in Mariner settings, in Depths."
    else -> null
}

/**
 * The NOAA cells already installed, as dataset names without an extension.
 *
 * By name, which is all the core wants: a pick then prices what is missing
 * from the water rather than all of it.
 */
private fun installedCells(charts: ChartsModel): List<String> =
    charts.sets.flatMap { set -> ChartSets.files(set.path).map { it.name } }
        .map { it.substringBefore('.') }
        .filter { it.startsWith("US") }
        .distinct()
