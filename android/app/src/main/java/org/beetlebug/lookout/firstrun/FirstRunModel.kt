package org.beetlebug.lookout.firstrun

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.beetlebug.lookout.Lookout

/**
 * Setup as the views read it. The core holds the steps and whether setup runs
 * (lookout_setup_*). This holds the words and forwards the mariner's actions.
 *
 * It runs over an app that has settled on having no chart to draw, on every
 * launch that finds one. Not once per device: a mariner with an empty library
 * has the same questions to answer whether this is their first launch or their
 * fiftieth, and the way back to the library they lost is the page that built
 * it.
 */
class FirstRunModel {

    /** Where the charts come from, in LOOKOUT_SETUP_FROM_* order. */
    enum class Source { NOAA, ONLINE, FILES }

    /** In LOOKOUT_SETUP_STEP_* order. */
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

    /** The source card picked on the source step. */
    var source by mutableStateOf(Source.NOAA)
    /** The regions of the NOAA order, named for the import step. */
    var orderRegions by mutableStateOf("")

    data class Order(val regions: String, val charts: Int, val bytes: Long)

    /** What the app observes, as the slots of [Lookout.setupNote]. */
    data class Facts(
        val catalogReady: Boolean = false,
        val picked: Boolean = false,
        val onLink: Boolean = false,
        val nothingToDraw: Boolean = false,
        val hasCharts: Boolean = false,
        val workRunning: Boolean = false,
        val downloading: Boolean = false,
        val chartOpen: Boolean = false,
        val noaaOutcome: Int = 0,
        val noaaRun: Long = 0,
        val pickCharts: Int = 0,
        val pickBytes: Long = 0,
    ) {
        fun slots(): LongArray = longArrayOf(
            flag(catalogReady), flag(picked), flag(onLink), flag(nothingToDraw),
            flag(hasCharts), flag(workRunning), flag(downloading), flag(chartOpen),
            noaaOutcome.toLong(), noaaRun, pickCharts.toLong(), pickBytes,
        )

        private fun flag(b: Boolean) = if (b) 1L else 0L
    }

    /** The core's setup state machine (src/firstrun.zig). */
    private val handle = Lookout.setupNew()
    /** The slots of [Lookout.setupRead]. */
    private var state by mutableStateOf(LongArray(STATE_SLOTS))

    val step: Step get() = Step.entries.getOrElse(state[0].toInt()) { Step.WELCOME }
    /** True while setup is over the chart. */
    val showing: Boolean get() = state[1] != 0L
    /** True when setup is down and has a reason to come up. */
    val shouldBegin: Boolean get() = !showing && state[2] != 0L
    val canGoBack: Boolean get() = state[3] != 0L
    val primaryEnabled: Boolean get() = state[4] != 0L
    /** Raised when the mariner continues from the source step with NOAA
     *  picked. The regions come after they accept. */
    val showingEncTerms: Boolean get() = state[5] != 0L
    /** The NOAA order ended with no chart to continue to. */
    val importEnded: Boolean get() = state[8] != 0L
    /** Work ran on the import step. An import yet to start and one that has
     *  finished both have no work running. */
    val sawWork: Boolean get() = state[9] != 0L
    /** The NOAA order as it was placed, or null for a dropped folder. */
    val order: Order?
        get() = if (state[7] != 0L) Order(orderRegions, state[10].toInt(), state[11]) else null

    /** Hand the core what the app observes. */
    fun note(facts: Facts) {
        Lookout.setupNote(handle, facts.slots())
        read()
    }

    private fun read() {
        val out = LongArray(STATE_SLOTS)
        Lookout.setupRead(handle, out)
        state = out
    }

    private fun act(action: Int, arg: Int = 0): Int =
        Lookout.setupAct(handle, action, arg).also { read() }

    fun begin() {
        act(BEGIN, Step.WELCOME.ordinal)
    }

    /** Accepted. On to picking water. */
    fun agreeToEncTerms() {
        act(AGREE)
    }

    /** Dismissed without accepting. The source step stands, so another source
     *  is still open to them. */
    fun declineEncTerms() {
        act(DECLINE)
    }

    /**
     * The primary action for the step on screen. Returns the source to act on
     * once the flow has finished asking and the shell has work to do, such as
     * raising a file picker.
     */
    fun advance(): Source? = Source.entries.getOrNull(act(ADVANCE, source.ordinal))

    fun back() {
        act(BACK)
    }

    /**
     * Set Up Later, and the end of a run that finished. Both put setup away
     * for the rest of this launch until a library that held charts is emptied.
     */
    fun finish() {
        act(LATER)
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

    /** The primary button's words. The online step names the picked chart. */
    fun primaryTitle(chartName: String?): String = when (step) {
        Step.WELCOME, Step.SOURCE -> "Continue"
        Step.COVERAGE -> "Download"
        Step.ONLINE_CHART -> chartName?.let { "Use $it" } ?: "Continue"
        Step.IMPORTING -> "Continue"
        Step.DEPTHS -> "Start Sailing"
    }

    private companion object {
        const val STATE_SLOTS = 12
        // LOOKOUT_SETUP_* actions.
        const val BEGIN = 0
        const val ADVANCE = 2
        const val BACK = 3
        const val AGREE = 4
        const val DECLINE = 5
        const val LATER = 6
    }
}
