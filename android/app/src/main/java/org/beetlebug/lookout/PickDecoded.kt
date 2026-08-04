package org.beetlebug.lookout

import org.json.JSONArray
import org.json.JSONObject

/**
 * What one pick result shows.
 *
 * The ENGINE composes the report. The core emits {"report":…,"s57":…} per
 * feature, which is the decoded page beside the raw payload, and this parses
 * it. Nothing here decides what a mariner reads. tile57_s57_report does that
 * once, for every shell.
 */
class PickDecoded(feature: PickFeature) {

    /** One row of the engine's report. */
    data class ReportRow(
        val label: String,
        val value: String,
        val depth: Int,
        val file: Boolean,
        val picture: Boolean,
    )

    /** Why the body has nothing to read, when it does not. */
    enum class EmptyKind { NO_ATTRIBUTES, SOURCE_ONLY }

    val title: String
    val subtitle: String?
    val chip: String
    val notes: List<String>
    val reportRows: List<ReportRow>
    val footnote: String
    val empty: EmptyKind?

    /** The payload as the cell states it, for the fold and the clipboard. */
    val rawRows: List<S57.Row>

    init {
        val root = parseObject(feature.s57)
        val report = root?.optJSONObject("report")
        // A payload without the envelope is a raw object. That is the core's
        // fallback when a compose fails. The fold still shows everything.
        val raw: Any? = if (report != null) root.opt("s57") else root

        title = report?.optStringOrNull("title") ?: feature.cls
        subtitle = report?.optStringOrNull("subtitle")
        chip = report?.optStringOrNull("chip") ?: feature.cls
        notes = report?.optJSONArray("notes")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optString(it).ifEmpty { null } }
        } ?: emptyList()
        reportRows = report?.optJSONArray("rows")?.let { arr ->
            (0 until arr.length()).mapNotNull { i ->
                val r = arr.optJSONObject(i) ?: return@mapNotNull null
                ReportRow(
                    label = r.optString("label"),
                    value = r.optString("value"),
                    depth = r.optInt("depth", 0),
                    file = r.optBoolean("file", false),
                    picture = r.optBoolean("picture", false),
                )
            }
        } ?: emptyList()
        footnote = report?.optStringOrNull("footnote") ?: feature.chart
        empty = when (report?.optStringOrNull("empty")) {
            "none" -> EmptyKind.NO_ATTRIBUTES
            "source" -> EmptyKind.SOURCE_ONLY
            else -> null
        }
        rawRows = S57.rows(raw)
    }

    private companion object {
        fun parseObject(json: String): JSONObject? =
            if (json.isEmpty()) null else runCatching { JSONObject(json) }.getOrNull()

        /** optString returns "" for a missing key; a caller wants null. */
        fun JSONObject.optStringOrNull(key: String): String? =
            if (isNull(key)) null else optString(key).ifEmpty { null }
    }
}

/** The raw S-57 payload, flattened for the fold and the clipboard. */
object S57 {

    data class Row(val name: String, val value: String, val depth: Int)

    /** Rows from an already-parsed payload, which is the envelope's raw half. */
    fun rows(any: Any?): List<Row> {
        if (any == null || any === JSONObject.NULL) return emptyList()
        val out = mutableListOf<Row>()
        append(any, null, 0, out)
        return out
    }

    private fun append(node: Any?, name: String?, depth: Int, out: MutableList<Row>) {
        when (node) {
            is JSONObject -> {
                if (name != null) out.add(Row(name, "", depth))
                for (key in node.keys().asSequence().sorted()) {
                    append(node.opt(key), key, if (name == null) depth else depth + 1, out)
                }
            }
            is JSONArray -> {
                if (name != null) out.add(Row(name, "", depth))
                for (i in 0 until node.length()) append(node.opt(i), null, depth + 1, out)
            }
            else -> out.add(Row(name ?: "", text(node), depth))
        }
    }

    private fun text(node: Any?): String = when (node) {
        null, JSONObject.NULL -> ""
        is String -> node
        is Double -> if (node == node.toLong().toDouble()) node.toLong().toString() else node.toString()
        else -> node.toString()
    }

    /**
     * The report as plain text for the clipboard. It uses the raw payload, out
     * of the envelope when there is one, so a chart problem is reported in the
     * cell's own words.
     */
    fun plainText(feature: PickFeature): String {
        val root = runCatching { JSONObject(feature.s57) }.getOrNull()
        val raw: Any? = if (root?.opt("report") != null) root.opt("s57") else root
        val sb = StringBuilder("${feature.cls}  ${feature.chart}\n")
        for (row in rows(raw)) {
            val indent = "  ".repeat(row.depth)
            if (row.value.isEmpty()) sb.append("$indent${row.name}:\n")
            else sb.append("$indent${row.name}: ${row.value}\n")
        }
        return sb.toString()
    }
}
