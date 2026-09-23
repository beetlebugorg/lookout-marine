package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.chart.ChartController
import org.beetlebug.lookout.charts.ChartsModel
import org.beetlebug.lookout.charts.NoaaController

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
        if (flow.step == FirstRunModel.Step.COVERAGE) noaa.reprice()
    }

    FirstRunFlow(
        flow = flow,
        // The online step keeps Skip: continuing with no chart picked
        // finishes setup over the basemap.
        canContinue = flow.step == FirstRunModel.Step.ONLINE_CHART || flow.primaryEnabled,
        chartName = links.chartLinks.firstOrNull { it.url == links.activeChartLink }?.name,
        footnote = footnote(flow, noaa),
        onPrimary = {
            when (flow.advance()) {
                FirstRunModel.Source.FILES -> onOpenCharts()
                FirstRunModel.Source.NOAA -> {
                    flow.orderRegions = noaa.regions.filter { noaa.picked.contains(it.id) }
                        .joinToString(", ") { it.name }
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
