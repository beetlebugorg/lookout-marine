package org.beetlebug.lookout.pick

import androidx.compose.ui.geometry.Offset

// What a tap on the chart turns up, in the three shapes the shell draws.
//
// They live here rather than with the controller that produces them because
// the pick UI is what reads them: putting them beside the chart made `pick`
// and `chart` import each other, which said the two were one thing when they
// are not.

/** One feature under the cursor: S-57 object class, its acronym, source cell. */
data class PickFeature(val cls: String, val s57: String, val chart: String)

/**
 * What a plugin overlay symbol says about itself — an AIS target's name, MMSI,
 * speed and closest approach, say. Decoded from the JSON the core's overlay
 * pick returns: {"title":"…","rows":[["key","value"],…]}.
 *
 * The shell renders the rows it is given and knows nothing about what any of
 * them mean; the plugin that drew the symbol chose them.
 */
data class OverlayInfo(val title: String, val rows: List<Pair<String, String>>) {
    companion object {
        fun parse(json: String?): OverlayInfo? {
            if (json.isNullOrEmpty()) return null
            return try {
                val top = org.json.JSONObject(json)
                val title = top.optString("title")
                if (title.isEmpty()) return null
                val arr = top.optJSONArray("rows")
                val rows = buildList {
                    for (i in 0 until (arr?.length() ?: 0)) {
                        val r = arr!!.optJSONArray(i) ?: continue
                        if (r.length() >= 2) add(r.optString(0) to r.optString(1))
                    }
                }
                OverlayInfo(title, rows)
            } catch (e: Exception) {
                null
            }
        }
    }
}

/**
 * One overlay object the mariner pinned: which object it is, what it says now,
 * and where it draws now. Re-read from the core every frame rather than
 * remembered — the target moves, its values change, and it eventually goes.
 */
data class OverlayPin(val id: String, val info: OverlayInfo, val lon: Double, val lat: Double)

/** A file the chart carries (TXTDSC text, PICREP picture), fetched. */
class AuxFile(val name: String, val bytes: ByteArray, val mime: String)
