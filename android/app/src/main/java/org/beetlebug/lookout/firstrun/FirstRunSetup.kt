package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.chart.ChartController
import org.beetlebug.lookout.charts.ChartsModel
import org.beetlebug.lookout.charts.NoaaController

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.padding

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

    FirstRunFlow(
        flow = flow,
        canContinue = canContinue(flow, noaa, links.activeChartLink),
        chartName = links.chartLinks.firstOrNull { it.url == links.activeChartLink }?.name,
        footnote = footnote(flow, noaa),
        onPrimary = {
            when (flow.advance()) {
                FirstRunModel.Source.FILES -> onOpenCharts()
                FirstRunModel.Source.NOAA -> Unit
                FirstRunModel.Source.ONLINE -> Unit
                null -> Unit
            }
        },
        onLater = { flow.finish() },
    ) {
        when (flow.step) {
            FirstRunModel.Step.WELCOME -> WelcomeStep()
            FirstRunModel.Step.SOURCE -> SourceStep(flow)
            else -> Text("", Modifier.padding(20.dp))
        }
    }
}

/** Whether the step on screen has been answered. */
private fun canContinue(
    flow: FirstRunModel,
    noaa: NoaaController,
    activeLink: String?,
): Boolean = when (flow.step) {
    FirstRunModel.Step.WELCOME, FirstRunModel.Step.SOURCE -> true
    FirstRunModel.Step.COVERAGE -> noaa.haveCatalog && noaa.picked.isNotEmpty()
    FirstRunModel.Step.ONLINE_CHART -> true
    FirstRunModel.Step.IMPORTING -> false
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
 * What the pick costs, and what of it is already here. Water wholly installed
 * prices as that rather than reading as an empty pick.
 */
private fun costLine(noaa: NoaaController): String {
    val charts = if (noaa.cells == 1) "1 chart" else "${noaa.cells} charts"
    return when {
        noaa.cells == 0 -> "${noaa.held} charts, all installed"
        noaa.held > 0 -> "$charts, ${NoaaController.sizeText(noaa.bytes)} · ${noaa.held} already installed"
        else -> "$charts, ${NoaaController.sizeText(noaa.bytes)}"
    }
}
