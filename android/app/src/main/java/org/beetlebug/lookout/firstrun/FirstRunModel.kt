package org.beetlebug.lookout.firstrun

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Setup: what it is asking, and whether it runs at all.
 *
 * It runs over an app that has settled on having no chart to draw, on every
 * launch that finds one. Not once per device: a mariner with an empty library
 * has the same questions to answer whether this is their first launch or their
 * fiftieth, and the way back to the library they lost is the page that built
 * it.
 */
class FirstRunModel {

    /** Where the charts come from. The source step asks this once. */
    enum class Source { NOAA, ONLINE, FILES }

    enum class Step {
        WELCOME,
        SOURCE,
        /** Which waters, for NOAA. */
        COVERAGE,
        /** A published style, drawn as the chart. */
        ONLINE_CHART,
        /** Charts arriving and converting. Setup stays open through it. */
        IMPORTING,
        /** The safety contour, asked once there is a chart to draw it on. */
        DEPTHS,
    }

    var step by mutableStateOf(Step.WELCOME)
        private set
    var source by mutableStateOf(Source.NOAA)
    /** True while setup is over the chart. */
    var showing by mutableStateOf(false)
        private set

    /**
     * True once a bake has been seen running. Without it an import that has yet
     * to start reads the same as one that has finished, because both report no
     * work.
     */
    var sawBake by mutableStateOf(false)

    /** What the mariner asked NOAA for, kept from the moment they asked. The
     *  service's counters are for the transfer; the page outlives it. */
    var order by mutableStateOf<Order?>(null)

    data class Order(val regions: String, val charts: Int, val bytes: Long)

    /**
     * True once the mariner has put setup away for this run. Set Up Later is
     * "not now", not an answer, so it holds only until the app is next started
     * with nothing to draw.
     */
    private var putAway = false

    /**
     * Whether setup should come up. `nothingToDraw` is the app having settled
     * on an empty library, and `linked` is a published style drawing in its
     * place: somebody sailing on one has no empty library to fill.
     */
    fun shouldRun(nothingToDraw: Boolean, linked: Boolean): Boolean =
        !putAway && !linked && nothingToDraw

    fun begin() {
        step = Step.WELCOME
        showing = true
    }

    /** Whether Back applies. The first step offers Set Up Later instead, and
     *  past the import the charts are already arriving. */
    val canGoBack: Boolean get() = when (step) {
        Step.SOURCE, Step.COVERAGE, Step.ONLINE_CHART -> true
        else -> false
    }

    fun back() {
        step = when (step) {
            Step.SOURCE -> Step.WELCOME
            Step.COVERAGE, Step.ONLINE_CHART -> Step.SOURCE
            else -> step
        }
    }

    /**
     * The primary action for the step on screen. Returns the source to act on
     * once the flow has finished asking and the shell has work to do, such as
     * raising a file picker.
     */
    fun advance(): Source? = when (step) {
        Step.WELCOME -> { step = Step.SOURCE; null }
        Step.SOURCE -> when (source) {
            Source.NOAA -> { step = Step.COVERAGE; null }
            Source.ONLINE -> { step = Step.ONLINE_CHART; null }
            Source.FILES -> { finish(); Source.FILES }
        }
        Step.COVERAGE -> { step = Step.IMPORTING; Source.NOAA }
        Step.ONLINE_CHART -> { step = Step.DEPTHS; Source.ONLINE }
        Step.IMPORTING -> { step = Step.DEPTHS; null }
        Step.DEPTHS -> { finish(); null }
    }

    /**
     * Set Up Later, and the end of a run that finished. Both put setup away for
     * the rest of this launch. A run that finished leaves a chart behind it,
     * and a chart is what keeps setup down after that.
     */
    fun finish() {
        putAway = true
        showing = false
        step = Step.WELCOME
    }

    /** The page's own name, for the bar over it. */
    val title: String get() = when (step) {
        Step.WELCOME -> "Welcome"
        Step.SOURCE -> "Add charts"
        Step.COVERAGE -> "Coverage"
        Step.ONLINE_CHART -> "Online chart"
        Step.IMPORTING -> "Preparing"
        Step.DEPTHS -> "Depths"
    }

    /** The primary button's words. The last step names what it keeps. */
    fun primaryTitle(chartName: String?): String = when (step) {
        Step.WELCOME, Step.SOURCE -> "Continue"
        Step.COVERAGE -> "Download"
        Step.ONLINE_CHART -> if (chartName != null) "Continue" else "Skip"
        Step.IMPORTING -> "Continue"
        Step.DEPTHS -> "Start Sailing"
    }
}
