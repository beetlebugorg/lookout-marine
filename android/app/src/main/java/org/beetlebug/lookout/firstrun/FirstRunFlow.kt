package org.beetlebug.lookout.firstrun

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * Setup, over the running app.
 *
 * The chart keeps drawing behind it, and the page is the whole answer to an
 * empty library: a panel saying there are no charts would say what to do
 * without doing any of it.
 *
 * The frame is the same on every step: the step's name and the way back over
 * the top, the step itself in the middle, and the one action that moves it on
 * at the bottom. A step says what its action is called and whether it is
 * ready; nothing else about the frame changes.
 */
@Composable
fun FirstRunFlow(
    flow: FirstRunModel,
    /** Whether the step on screen is ready to be moved on from. */
    canContinue: Boolean,
    /** The chart the online step has picked, for the last button's words. */
    chartName: String?,
    /** The line beside the action: a credit, a price, or what to do next. */
    footnote: String?,
    onPrimary: () -> Unit,
    onLater: () -> Unit,
    step: @Composable () -> Unit,
) {
    BackHandler(enabled = flow.canGoBack) { flow.back() }

    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize()) {
            Spacer(Modifier.height(WindowInsets.statusBars.asPaddingValues().calculateTopPadding()))
            bar(flow, onLater)
            HorizontalDivider()
            // A tablet is wider than any of these steps wants to be, so the
            // step keeps a column and centres it rather than running a line of
            // body text the whole way across.
            Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())) {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                    Box(Modifier.widthIn(max = COLUMN)) { step() }
                }
            }
            HorizontalDivider()
            footer(flow, canContinue, chartName, footnote, onPrimary)
            Spacer(
                Modifier.height(
                    WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding(),
                ),
            )
        }
    }
}

/** The step's name, and the way back out of it. */
@Composable
private fun bar(flow: FirstRunModel, onLater: () -> Unit) {
    Box(Modifier.fillMaxWidth().height(52.dp)) {
        Text(
            flow.title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.align(Alignment.Center),
        )
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 6.dp).align(Alignment.Center),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (flow.canGoBack) {
                IconButton(
                    onClick = { flow.back() },
                    modifier = Modifier.semantics { contentDescription = "first-run-back" },
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            }
            Spacer(Modifier.weight(1f))
            if (flow.step == FirstRunModel.Step.SOURCE) {
                TextButton(
                    onClick = onLater,
                    modifier = Modifier.semantics { contentDescription = "first-run-cancel" },
                ) { Text("Cancel") }
            }
        }
    }
}

/** The one action, the line beside it, and the way out of the first step. */
@Composable
private fun footer(
    flow: FirstRunModel,
    canContinue: Boolean,
    chartName: String?,
    footnote: String?,
    onPrimary: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (footnote != null) StepFootnote(footnote)
        Button(
            onClick = onPrimary,
            enabled = canContinue,
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = COLUMN)
                .semantics { contentDescription = "first-run-continue" },
        ) { Text(flow.primaryTitle(chartName)) }
        if (flow.step == FirstRunModel.Step.WELCOME) {
            TextButton(
                onClick = { flow.finish() },
                modifier = Modifier.semantics { contentDescription = "first-run-later" },
            ) { Text("Set Up Later") }
        }
    }
}

/** The widest a step's column grows. A line of body text that runs the whole
 *  width of a tablet is hard to read back. */
private val COLUMN = 620.dp
