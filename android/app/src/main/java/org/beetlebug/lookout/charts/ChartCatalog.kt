package org.beetlebug.lookout.charts

import org.beetlebug.lookout.R

/**
 * The online charts the app offers on a fresh install.
 *
 * A first run has no links, so the online chart step showed an empty shelf
 * until the mariner pasted a style url. These entries give the step charts to
 * pick from on the day the app is installed.
 *
 * Lookout does not run these services. A card names the publisher and shows
 * the url its tiles come from, so an entry offers a link to somebody else's
 * chart rather than a chart of Lookout's.
 *
 * Each entry ships a picture of its style, the same render the Apple shells
 * ship, so the step draws its cards before a single tile is fetched.
 */
object ChartCatalog {

    /** One chart the app knows about before the mariner adds anything. */
    data class Entry(val name: String, val url: String, val art: Int)

    /** Listed in the order the step draws them. */
    val entries: List<Entry> = listOf(
        Entry(
            "Open Waters Seascape",
            "https://tiles.openwaters.io/seascape/style.json",
            R.drawable.seascape_preview,
        ),
        Entry(
            "Open Waters Seamap",
            "https://tiles.openwaters.io/seamap/style.json",
            R.drawable.seamap_preview,
        ),
    )

    /** The picture shipped for this link, if the app has one. */
    fun art(url: String): Int? = entries.firstOrNull { it.url == url }?.art
}
