package org.beetlebug.lookout.firstrun

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * NOAA's terms, asked once, where NOAA's charts are chosen.
 *
 * This used to sit on the empty chart page, which setup replaced. It belongs
 * to the NOAA source rather than to the app: a mariner who draws a published
 * style, or opens their own folder, downloads no ENC and is asked to accept
 * nothing.
 */
@Composable
fun EncTermsDialog(flow: FirstRunModel) {
    val uris = LocalUriHandler.current
    AlertDialog(
        onDismissRequest = { flow.declineEncTerms() },
        title = { Text("Before you download", fontWeight = FontWeight.SemiBold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .background(AMBER.copy(alpha = 0.12f), RoundedCornerShape(9.dp))
                        .padding(horizontal = 12.dp, vertical = 11.dp),
                ) {
                    Icon(
                        Icons.Filled.Warning,
                        contentDescription = null,
                        tint = AMBER,
                        modifier = Modifier.size(15.dp).align(Alignment.Top),
                    )
                    Spacer(Modifier.width(9.dp))
                    Column {
                        Text(
                            "NOT FOR NAVIGATION",
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold,
                        )
                        Spacer(Modifier.height(3.dp))
                        Text(
                            "By importing charts you accept that Lookout is a prototype and not a certified navigation system, and that the charts it prepares are processed for display and are not the official ENC. They do not meet chart carriage regulations. You remain responsible for the safe navigation of your vessel and for keeping clear of every danger. Verify everything shown here against official, up-to-date charts and publications, and keep a paper backup.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                // NOAA's own terms, in their words. They apply to their charts
                // whoever prepared them.
                Text(
                    "NOAA ENC® charts come from the NOAA Office of Coast Survey and are updated weekly on a best-efforts basis; you are responsible for holding the current edition and the latest updates. NOAA makes no warranty and assumes no liability for their use.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "NOAA ENC User Agreement",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .semantics { contentDescription = "enc-agreement-link" }
                        .clickable { uris.openUri(AGREEMENT) }
                        .padding(top = 2.dp),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { flow.agreeToEncTerms() },
                modifier = Modifier.semantics { contentDescription = "enc-terms-agree" },
            ) { Text("Agree and Continue") }
        },
        dismissButton = {
            TextButton(
                onClick = { flow.declineEncTerms() },
                modifier = Modifier.semantics { contentDescription = "enc-terms-cancel" },
            ) { Text("Cancel") }
        },
        modifier = Modifier.semantics { contentDescription = "enc-terms" },
    )
}

/** NOAA's agreement itself. The paragraph above summarizes it. */
private const val AGREEMENT = "https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml"

/** The amber the warning panels use across setup. */
private val AMBER = Color(0xFFB26A00)
